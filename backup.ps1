# Partiverse Backup System — Windows 平台 (PowerShell)
# 使用 restic 作为备份引擎，rclone 同步 WebDAV
param([string]$Task = "Backup")

# ---------- 依赖安装 ----------
function Install-Deps-Windows {
    $bins = @("restic", "rclone")
    $binDir = "$env:USERPROFILE\PartiverseBackup\bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    foreach ($bin in $bins) {
        $exe = Get-Command $bin -ErrorAction SilentlyContinue
        if (-not $exe) {
            Write-Host "[Windows] 安装 $bin..."
            if ($bin -eq "restic") {
                # restic 0.19+ Windows 资产为 .zip（旧版为 .exe），先查 latest 再下载
                $out = "$binDir\restic.exe"
                try {
                    $rel = Invoke-RestMethod "https://api.github.com/repos/restic/restic/releases/latest"
                    $v = $rel.tag_name.TrimStart('v')
                    $base = "https://github.com/restic/restic/releases/download/v$v"
                    curl.exe -fsSL -o "$out" "$base/restic_${v}_windows_amd64.exe" 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        # 新版只有 zip
                        curl.exe -fsSL -o "$env:TEMP\restic.zip" "$base/restic_${v}_windows_amd64.zip" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Expand-Archive "$env:TEMP\restic.zip" -DestinationPath "$binDir" -Force
                            # zip 内文件名为 restic_<ver>_windows_amd64.exe，需改名
                            $exe = Get-ChildItem "$binDir" -Recurse -Filter "restic*.exe" | Select-Object -First 1
                            if ($exe -and $exe.FullName -ne $out) { Move-Item $exe.FullName $out -Force }
                        }
                    }
                } catch {
                    Write-Warning "下载失败，请手动安装 restic: https://restic.net"
                }
                if (-not (Test-Path $out)) { Write-Warning "restic.exe 未下载成功" }
            } elseif ($bin -eq "rclone") {
                # rclone Windows
                $url = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
                $out = "$env:TEMP\rclone.zip"
                curl.exe -fsSL -o "$out" "$url" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "下载失败，请手动安装 rclone: https://rclone.org"
                } else {
                    Expand-Archive $out -DestinationPath "$binDir" -Force
                    Move-Item "$binDir\rclone-*-windows-amd64\rclone.exe" "$binDir\rclone.exe" -Force
                }
            }
        }
    }
    $env:PATH = "$binDir;$env:PATH"
}

# ---------- 调度设置 (Task Scheduler) ----------
function Setup-Scheduler-Windows {
    param([string]$ScriptPath, [string]$Time = "02:34")

    $taskName = "PartiverseBackup"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`""

    $trigger = New-ScheduledTaskTrigger -Daily -At $Time
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable

    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger $trigger -Settings $settings -Force | Out-Null

    Write-Host "[Windows] Task Scheduler 任务 '$taskName' 已创建"
}

# ---------- 备份核心 (restic) ----------
function Backup-ResticClass {
    param([string]$Class, [string]$RepoPath, [string]$ArcName)

    Write-Host "[$Class] 归档: $ArcName"

    # 初始化 repo（幂等，已初始化则忽略报错）
    & restic -r $RepoPath init 2>&1 | Out-Null

    # includes/excludes：由 config.ps1 dot-source 进本函数作用域
    $incl = (Get-Variable "RESTIC_INCLUDES_$Class" -ValueOnly -ErrorAction SilentlyContinue) -split ';' |
        Where-Object { $_ }
    $excl = (Get-Variable "RESTIC_EXCLUDES_$Class" -ValueOnly -ErrorAction SilentlyContinue) -split ';' |
        Where-Object { $_ }

    $resticArgs = @("-r", $RepoPath, "backup", "--host", $env:DEVICE_ID)
    foreach ($e in $excl) { $resticArgs += @("--exclude", $e) }
    foreach ($i in $incl) { $resticArgs += $i }

    if ($incl.Count -eq 0) {
        Write-Warning "[$Class] 无备份路径，跳过"
        return
    }

    & restic @resticArgs 2>&1 | Tee-Object -FilePath $env:BACKUP_LOG -Append
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
        throw "[$Class] restic backup 失败 (exit $LASTEXITCODE)"
    }

    # 清理：本地保留 7d/4w/6m。**必须带 --prune**：restic 的 forget 只删快照对象，
    # 引擎帮助页原话「In order to remove the unreferenced data after "forget" was run
    # successfully, see the "prune" command」——实测 9 份日快照 forget 退出 0、快照少一份，
    # 仓库字节数一字节没少。少了这一步，第 174 行「本地已 prune，云端保留全部历史」那句
    # 前提就不成立，本地仓库与云端副本一起只增不减。
    # rc 口径与 backup.sh 的 backup_restic_class 逐条对齐：3 = 部分生效（有快照没删掉，
    # 下晚重试）只告警；其余非零判本类失败——保留策略没跑成的唯一后果是仓库无限增长，
    # 而观察期里没人会主动去查仓库尺寸
    & restic -r $RepoPath forget --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --prune 2>&1 |
        Tee-Object -FilePath $env:BACKUP_LOG -Append | Out-Null
    if ($LASTEXITCODE -eq 3) {
        Write-Warning "[$Class] forget/prune 部分生效 (rc=3)"
    } elseif ($LASTEXITCODE -ne 0) {
        throw "[$Class] restic forget/prune 失败 (exit $LASTEXITCODE)"
    }
}

# ---------- 运行史可审计（roadmap A4，与 backup.sh 同形）----------
# BEGIN-ROTATE —— test_log_rotation_logic.ps1 靠这两行标记把本函数**原样**切进容器里跑
# （备份轮在 Linux 容器里造不出来，而这里的形状与 backup.sh 的 rotate_log_if_oversized
#  一模一样，逻辑面值得单独证一次；生产改这个函数时标记必须还连着它）
function Rotate-LogFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$MaxBytes = 4194304,
        [int]$Keep = 7
    )
    # 只认普通文件。它的可测性说清楚，免得下一个人以为变异证过：摘掉 `-PathType Leaf` 后
    # 场景不会变红——目录的 .Length 是 $null，`$null -le MaxBytes` 为真，照样在下一行 return。
    # 这一道是给「日志路径被同名目录占了位」那种现场准备的第二层，真正由变异（m2）证过的
    # 目录闸门是下面 stale 清单里的那一道。
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -le $MaxBytes) { return 0 }
    $dir = Split-Path -Parent $Path
    $base = Split-Path -Leaf $Path
    $rotated = Join-Path $dir ("{0}.{1}" -f $base, (Get-Date -Format "yyyyMMdd-HHmmss"))
    Move-Item -LiteralPath $Path -Destination $rotated
    # 两道守卫各挡一种坏法，与 backup.sh 的注释同口径：
    #   形态白名单挡住用户手放的 backup.log.bak / backup.log.keepme（摘掉它这两样既被删、
    #     又占掉 KEEP 名额，把真副本挤成「超额的那几份」——变异 m1 报的就是 copies 8→9）；
    #   「必须是普通文件」挡住同名**目录**：让它进删除名单最坏的一档是连内容一起没（这条
    #     语句将来谁顺手加个 -Recurse 就是数据丢失）；实测 pwsh 7 落在另一档——它对非空目录
    #     直接抛（变异摘掉这道守卫时报的就是 Object reference…），于是整次轮转被接入点降成
    #     warning、现役日志再也切不动。两种坏法都不该靠「目录恰好不存在」赌运气。
    # 时间戳副本一律按 mtime 排（与 bash 侧 `ls -1dt` 同一依据），新切出的那份天然最新。
    $copies = @(Get-ChildItem -LiteralPath $dir -Force |
        Where-Object { $_.Name -match ("^{0}\.[0-9]{{8}}-[0-9]{{6}}$" -f [regex]::Escape($base)) } |
        Sort-Object LastWriteTime -Descending)
    $stale = @($copies | Where-Object { -not $_.PSIsContainer } | Select-Object -Skip $Keep)
    foreach ($f in $stale) { Remove-Item -LiteralPath $f.FullName -Force }
    # 证据行：四种坏法在产物上长得一模一样（没被调用 / 参数没读到 / 两道守卫之一摘掉 /
    # 函数内抛终止性异常被上层 catch 降成 warning），所以让它自己报现场。
    # 纯 ASCII 是故意的——守卫可能在子进程 stdout 里匹配它（见 AGENTS §2 那条）。
    Write-Host ("ROTATE {0} size={1} max={2} keep={3} copies={4} removed={5}" -f `
        $base, $size, $MaxBytes, $Keep, $copies.Count, $stale.Count)
    return $stale.Count
}
# END-ROTATE

# BEGIN-BOUNDARY —— 同上一条约定：这段也被 test_log_rotation_logic.ps1 切走
# run 边界行：一轮一行写明「哪个代码基、退出码、跑了多久」。夜间出问题时，「这条错误
# 属于哪一轮、那轮部署点是什么 SHA」不用再去翻提交时间猜。
function Write-RunBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Sha = "nogit",
        [int]$Rc = 0,
        [int]$DurationSec = 0
    )
    try {
        # 字段形状与 backup.sh 的 log_run_boundary 一致（sha= rc= dur=），标签用 ASCII：
        # 同一份日志由 Tee-Object 写入，而它的默认编码在 5.1 与 pwsh 7 上不同——中文标签
        # 混进去会糊（同一口径见 AGENTS §5 的「纯 ASCII 是故意的」那条）。守卫要的三字段
        # 一个不少，跨平台 grep 用 `run boundary` / `run 边界` 各取其一即可。
        "[{0}] run boundary: sha={1} rc={2} dur={3}s" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Sha, $Rc, $DurationSec |
            Add-Content -LiteralPath $Path
    } catch {
        # 边界行属于旁路：写不成就少一行诊断，绝不反过来打断备份（与 backup.sh 的 `|| true` 同义）
        Write-Host "BOUNDARY-WRITE-FAILED $($_.Exception.Message)"
    }
}

# 代码基标记：取不到就退化成 nogit（与 backup.sh 的 `${RUN_GIT_SHA:-nogit}` 同一条）。
# 三种取不到都得退化——没装 git、这个目录不是仓库、HEAD 还没有提交——否则边界行自己炸，
# 而它在脚本最末尾一行，炸掉的就是整轮的退出码。
function Get-RunGitSha {
    param([string]$Path = $PSScriptRoot)
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return "nogit" }
        $sha = (& git -C $Path rev-parse --short HEAD 2>$null) -join ''
        if ($LASTEXITCODE -eq 0 -and $sha.Trim() -match '^[0-9a-f]{7,40}$') { return $sha.Trim() }
    } catch { }
    return "nogit"
}
# END-BOUNDARY

# BEGIN-VERIFY —— 同上约定：这一段被 test_cloud_verify_logic.ps1 按哨兵原样切走单独跑
# A6 L1 云端副本自证（与 backup.sh 的 run_cloud_verify 同形）。为什么必须有：这条 remote 上
# rclone 的比较退化成「只比大小」，原地同长度重写永远推不上云而 `copy` 照样退出 0（10-01 实测：
# 换口令后 config 从 700 B 变 700 B，云端三份 config 全是轮换前那份）。上面推送环节的 rc 只
# 回答「rclone 没报错」，这一层才回答「云端到底有没有」。
#
# 判定口径与 bash 侧逐字对齐，改任何一条前先读那边的注释：
#   ①单向包含——本地每个对象云端都在且同尺寸；云端多出来的是本地已被保留策略裁掉的历史副本，
#     按红线 §1.4「只增不减」不计失败（写成双向相等就每晚假报）。
#   ②仓库 config 单独走内容哈希；不一致当场 forcing 补传再复核，修好了记 HEALED（云端曾躺着
#     陈旧那份，得留痕），修不好才是 FAIL。
#   ③差异样本只到**目录**——这份报告随时间轴上云，红线 §1.1 的例外只有 rescue-test.txt。
#   ④HEALED 只能由「重新读回的内容」换来，`rclone copy` 退出 0 在这条 remote 上什么都没证明。
#   ⑤先比对、后落笔：报告比的是上一轮那份，从不自指。

# 目标地址的**唯一**拼法：推送用它们，自证也用它们。两处各写一遍归一化看着无害，实际后果是
# 自证去读一个云端从没被写过的地址并判 FAIL——与 A2b「记哈希的抽样与 drill 的抽样必须共用
# 同一个函数」是同一条教训。":/" 会被解析成文件系统绝对路径，所以归一为 "remote:设备/子路径"。
function Format-CloudDest {
    param([string]$Target, [string]$SystemId, [string]$Sub)
    ("{0}/{1}/{2}" -f $Target, $SystemId, $Sub) -replace "://", ":"
}

function Reset-VerifyState {
    $script:VerifyLines = @()
    $script:VerifyFailed = 0
    $script:VerifyUnknown = 0
    $script:VerifyHealed = 0
}

function Format-VerifyNote {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $script:VerifyLines += ("{0,-8} {1,-30} {2}" -f $Status, $Label, $Detail)
    switch ($Status) {
        "FAIL"    { $script:VerifyFailed = $script:VerifyFailed + 1 }
        "UNKNOWN" { $script:VerifyUnknown = $script:VerifyUnknown + 1 }
        "HEALED"  { $script:VerifyHealed = $script:VerifyHealed + 1 }
    }
}

# 本地清单：相对路径 → 字节。相对路径的分隔符统一成 `/`——`rclone lsl` 打印的就是 `/`，而
# Windows 的 FullName 带 `\`，不归一等于每一条都算「云端缺失」（这条只有真机能测出来，
# 所以守卫里有一整套「路径含空格 / 含子目录 / 根带尾分隔符」的形状用例）。
# rescue-test.txt 天生不进清单：红线 §1.1 规定它只留本地，本地有、云端没有才是对的形状，
# 留着它对平只会每晚报「云端少一份」。
function Get-LocalObjectMap {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootLen = $Root.Length
    while ($rootLen -gt 0 -and ($Root[$rootLen - 1] -eq "\" -or $Root[$rootLen - 1] -eq "/")) { $rootLen-- }
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq "rescue-test.txt") { continue }
        $rel = $f.FullName.Substring($rootLen).Trim("\", "/").Replace("\", "/")
        $map[$rel] = [long]$f.Length
    }
    $map
}

# `rclone lsl` 每行是「size 日期 时间 路径」，路径可能含空格，所以摘掉前三个字段而不是按空格切。
# 不匹配的行（进度、警告、空行）跳过——它们不该算成「云端少一个对象」。
function ConvertFrom-RcloneLsl {
    param([AllowEmptyCollection()][AllowNull()][string[]]$Lines)
    $map = @{}
    foreach ($l in $Lines) {
        if ($l -match '^\s*(\d+)\s+\S+\s+\S+\s+(.+)$') { $map[$matches[2].Trim()] = [long]$matches[1] }
    }
    $map
}

# 三条计数：缺 / 尺寸不符 / 云端多出来（只记账、不计失败）。纯集合运算所以单独成函数、单独可测——
# 「双向相等就每晚假报」这一发只能在这里挡。
function Compare-VerifyMaps {
    param([hashtable]$Local, [hashtable]$Cloud)
    $missing = @()
    $mismatch = @()
    foreach ($k in $Local.Keys) {
        if (-not $Cloud.ContainsKey($k)) { $missing += $k }
        elseif ([long]$Cloud[$k] -ne [long]$Local[$k]) { $mismatch += $k }
    }
    $extra = @($Cloud.Keys | Where-Object { -not $Local.ContainsKey($_) })
    [pscustomobject]@{ Missing = $missing; Mismatch = $mismatch; Extra = $extra.Count }
}

# 差异样本只到目录（红线 §1.1，与 bash 的 dir_sample 同一口径：取前 3 条所在目录再去重）。
# 定位到目录已经够用——要补传的是那一棵子树，不是一个神秘文件名。今天被校验的两棵树（时间轴
# 产物 / 引擎 chunk）名字都是系统生成的，看着无害，但「反正调用点选的是我们自己的目录」不是一道
# 闸门：校验面哪天扩到 system-meta/（services/hardware 转储，全是用户路径）就顺着这里漏。
function Get-VerifyDirSample {
    param([AllowEmptyCollection()][AllowNull()][string[]]$Paths)
    $seen = @{}
    $out = @()
    foreach ($p in @(@($Paths | Select-Object -First 3))) {
        if (-not $p) { continue }
        $d = if ($p.Contains("/")) { $p.Substring(0, $p.LastIndexOf("/")) } else { "(root)" }
        if (-not $seen.ContainsKey($d)) { $seen[$d] = $true; $out += $d }
    }
    $out -join " "
}

# 云端那一份必须落成**字节**再哈希：把 `rclone cat` 的 stdout 收进 PowerShell 字符串会吃掉换行
# 与尾部空白，而「同长度不同内容」这一档正是靠这些字节区分的。所以走 copyto 落临时件。
# 用 return 而不是 exit：宿主实测（pwsh 7 与 5.1，见 AGENTS §5）函数内的 `exit` 在 7 上不跑外层
# finally，而临时件必须保证删掉；`return` 两种宿主都会跑 finally。
function Get-VerifyCloudHash {
    param([string]$Dest)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bg-verify-" + [guid]::NewGuid().ToString("N"))
    try {
        & rclone copyto $Dest $tmp 2>$null
        if ($LASTEXITCODE -ne 0) { return "" }
        if (-not (Test-Path -LiteralPath $tmp -PathType Leaf)) { return "" }
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
    } catch {
        return ""
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 单个前缀的清单对平。$Privacy 只对时间轴前缀开——引擎仓库是 restic 自己的对象存储，同名文件
# 不可能由我们推上去，逐类别查只会把报告灌满永远 PASS 的行（bash 同一条）。
# 推送环节的 --exclude 只挡**新**副本，历史副本得靠这条检查揪出来手工删。
function Test-VerifyPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Dest,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Target,
        [switch]$Privacy
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Format-VerifyNote SKIP $Label "本地没有这一棵树（该类别没备份或路径变了）"
        return
    }
    $lstd = Get-LocalObjectMap -Root $Root
    $raw = @(& rclone lsl $Dest 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Format-VerifyNote UNKNOWN $Label ("rclone lsl rc={0}（网盘抖动或该前缀读不出），这一项既没证成也没证败" -f $LASTEXITCODE)
        return
    }
    $cstd = ConvertFrom-RcloneLsl -Lines $raw
    # 红线 §1.1 的自证面：读的是**同一份**云端清单，不另开一次 rclone 调用——两次读之间网盘
    # 变了样，就会出现「对平说在、隐私检查说不存在」这种自相矛盾的报告（bash 同理）。
    if ($Privacy) {
        $leaked = @($cstd.Keys | Where-Object { $_ -match "(^|/)rescue-test\.txt$" })
        if ($leaked.Count -gt 0) {
            Format-VerifyNote FAIL "privacy @ $Target" "云端时间轴里有 rescue-test.txt（红线 §1.1：它带完整文件名，只准留本地；--exclude 挡不住历史副本，得手工删）"
        } else {
            Format-VerifyNote PASS "privacy @ $Target" "云端时间轴没有 rescue-test.txt"
        }
    }
    $cmp = Compare-VerifyMaps -Local $lstd -Cloud $cstd
    if ($cmp.Missing.Count -eq 0 -and $cmp.Mismatch.Count -eq 0) {
        Format-VerifyNote PASS $Label ("本地 {0} 个对象云端全在且尺寸一致（云端另有 {1} 份本地已裁的历史副本，按只增不减不计失败）" -f `
            $lstd.Count, $cmp.Extra)
        return
    }
    Format-VerifyNote FAIL $Label ("云端缺 {0} 个 / 尺寸不符 {1} 个；缺失所在目录：{2}；尺寸不符所在目录：{3}" -f `
        $cmp.Missing.Count, $cmp.Mismatch.Count,
        (Get-VerifyDirSample -Paths $cmp.Missing), (Get-VerifyDirSample -Paths $cmp.Mismatch))
}

# 仓库 config 的内容哈希：10-01 那次「同长度重写永远推不上云」的正面对策。发现不一致不能只
# 一报了事——在这条 remote 上它永远不会自己修好（尺寸相同 → rclone 直接跳过），所以显式 forcing
# 补传那一个文件再复核。
# restic 侧与 borg 有个实质差别：真正的密钥材料在 `keys/<id>.key`，且换口令是**新文件名**（对平
# 那条就看得见缺失），`config` 只是仓库头（version/id）。所以这一项在 restic 上覆盖面比 borg 窄，
# 但机制必须一样——「同长度不同内容」只有内容哈希抓得住。
function Test-VerifyConfigHash {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Dest,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $local = Join-Path $Repo "config"
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) {
        Format-VerifyNote SKIP $Label "本地仓库没有 config"
        return
    }
    $lhash = ""
    try { $lhash = (Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash.ToLowerInvariant() } catch { }
    if (-not $lhash) { Format-VerifyNote UNKNOWN $Label "本地 config 哈希失败"; return }
    $chash = Get-VerifyCloudHash -Dest "$Dest/config"
    if (-not $chash) { Format-VerifyNote UNKNOWN $Label "云端 config 读取失败"; return }
    $tail = 12
    if ($chash -eq $lhash) {
        Format-VerifyNote PASS $Label ("sha256 {0}… 两端一致（仓库头云端有新版）" -f $lhash.Substring(0, $tail))
        return
    }
    # 先把云端那份陈旧证据留下来（报告里要能看出它躺了多久），再补传
    $stale = $chash
    & rclone copy -I "$($Repo.TrimEnd('\', '/'))/" $Dest --include config 2>$null
    $healRc = $LASTEXITCODE
    $chash = Get-VerifyCloudHash -Dest "$Dest/config"
    if (-not $chash) {
        Format-VerifyNote UNKNOWN $Label ("强制补传 (rc={0}) 之后云端 config 反而读不到了" -f $healRc)
    } elseif ($chash -eq $lhash) {
        Format-VerifyNote HEALED $Label ("云端原是 {0}…（同长度重写正是被「只比大小」静默丢掉的那类），已强制补传成 {1}…" -f `
            $stale.Substring(0, $tail), $lhash.Substring(0, $tail))
    } else {
        Format-VerifyNote FAIL $Label ("强制补传 (rc={0}) 后仍 本地 {1}… ≠ 云端 {2}…——云端副本不可信" -f `
            $healRc, $lhash.Substring(0, $tail), $chash.Substring(0, $tail))
    }
}

# 报告：明文产物且随时间轴上云，所以内容受红线 §1.1 约束（只有目录，没有文件名）。
# 中文正文 + 显式 `-Encoding utf8`：semantic.ps1 写 manifest 已经是这个口径，5.1 上不写
# 编码会落成 ANSI，云端裸文件管理器读出来是糊的。
function Write-VerifyReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines,
        [int]$Failed = 0,
        [int]$Unknown = 0,
        [int]$Healed = 0,
        [string]$Sha = "nogit"
    )
    # 每个格式化元素都单独括起来：数组里 `"..." -f a, b` 的逗号与 `-f` 的结合力在 PowerShell
    # 里读不准（元素会被拆成两行），而这里一旦拆错就是报告头部少一行、汇总计数变成字符串。
    $body = @(
        "# 云端副本自证（A6 L1）——每轮备份后跑一次，零提取流量",
        ("# 生成时间: {0}   代码基: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Sha),
        "# 判定口径: 单向包含。本地每个对象都必须在云端且尺寸一致；云端多出来的是本地",
        "#   已被保留策略裁掉的历史副本（云端只增不减），不计失败。",
        "#   同长度不同内容这一档 L1 抓不住，所以仓库 config 单独走内容哈希（下面 config:",
        "#   那几条）：不一致就当场 forcing 补传那一个文件再复核——修好了记 HEALED（云端曾躺着",
        "#   陈旧那份，得留痕），修不好才是 FAIL。其余文件由 L2/L3 覆盖。",
        "# 本文件随**下一轮**时间轴推送上云：比对发生在落笔之前，所以它比的是上一轮那份。",
        ("# 汇总: checks={0} FAIL={1} UNKNOWN={2} HEALED={3}" -f @($Lines).Count, $Failed, $Unknown, $Healed)
    ) + @($Lines)
    try {
        $body | Out-File -FilePath $Path -Encoding utf8
        return $true
    } catch {
        Write-Host ("VERIFY-REPORT-WRITE-FAILED {0}" -f $_.Exception.Message)
        return $false
    }
}

# 全量自证：每个目标 × 时间轴 + 每个类别仓库，结论写进时间轴根级 CLOUD-VERIFY.txt。
# 返回 @{Failed=..;Unknown=..;Healed=..;Report=}——调用点只看这个值，不靠跨作用域的全局，
# 因为 Start-PartiverseBackup 里的 $script: 状态一旦被 catch 打断就是半旧的。
function Invoke-CloudVerify {
    param(
        [Parameter(Mandatory = $true)][string[]]$Targets,
        [Parameter(Mandatory = $true)][string]$BackupBase,
        [AllowEmptyCollection()][string[]]$RepoPairs = @(),
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [string]$SystemId = $env:SYSTEM_ID,
        [string]$Sha = "nogit"
    )
    # 这是旁路，函数内把 EAP 收到 Continue。Start-PartiverseBackup 顶部是 Stop，而 rclone 只要
    # 往 stderr 写一个字符，在 Windows PowerShell 5.1 上就会变成终止性异常（真机正是 5.1，CI 是 7）
    # ——那样每一轮都会走调用点的 catch、自证一次也没跑成，而表面上还是「非致命、不影响备份」，
    # 没人看得见。守卫里有一条专门喂「rclone 写 stderr」的场景。
    $ErrorActionPreference = "Continue"
    Reset-VerifyState
    foreach ($t in $Targets) {
        Test-VerifyPrefix -Root (Join-Path $BackupBase "timeline") `
            -Dest (Format-CloudDest -Target $t -SystemId $SystemId -Sub "timeline") `
            -Label "timeline @ $t" -Target $t -Privacy
        foreach ($pair in $RepoPairs) {
            $cls = $pair.Substring(0, $pair.IndexOf(":"))
            $repo = $pair.Substring($pair.IndexOf(":") + 1)
            $dest = Format-CloudDest -Target $t -SystemId $SystemId -Sub $cls
            Test-VerifyPrefix -Root $repo -Dest $dest -Label "repo:$cls @ $t" -Target $t
            Test-VerifyConfigHash -Repo $repo -Dest $dest -Label "config:$cls @ $t"
        }
    }
    $ok = Write-VerifyReport -Path $ReportPath -Lines $script:VerifyLines `
        -Failed $script:VerifyFailed -Unknown $script:VerifyUnknown -Healed $script:VerifyHealed -Sha $Sha
    @{
        Failed = $script:VerifyFailed
        Unknown = $script:VerifyUnknown
        Healed = $script:VerifyHealed
        Report = $(if ($ok) { $ReportPath } else { "" })
    }
}
# END-VERIFY

# ---------- 主函数 ----------
function Start-PartiverseBackup {
    $ErrorActionPreference = "Stop"

    $CONF_DIR = "$env:APPDATA\PartiverseBackup"
    $LOG_DIR = "$env:LOCALAPPDATA\PartiverseBackup\logs"
    # config.ps1 可通过 $env:BACKUP_BASE 覆盖仓库根目录
    $BACKUP_BASE = if ($env:BACKUP_BASE) { $env:BACKUP_BASE } else { "$env:USERPROFILE\PartiverseBackup\repo" }
    $RCLONE_LOG = "$LOG_DIR\rclone.log"
    $BACKUP_LOG = "$LOG_DIR\backup.log"
    # Backup-ResticClass 通过 $env:BACKUP_LOG 引用日志路径
    $env:BACKUP_LOG = $BACKUP_LOG
    # 脚本末尾的边界行从这里取路径，不在那里重算一遍字面量（见 switch 后的注释）
    $script:BackupLogPath = $BACKUP_LOG

    New-Item -ItemType Directory -Force -Path $CONF_DIR, $LOG_DIR, $BACKUP_BASE | Out-Null

    # 加载配置
    if (Test-Path "$CONF_DIR\config.ps1") {
        . "$CONF_DIR\config.ps1"
    } else {
        # 先落 rc 再告警：本函数顶部 EAP=Stop，Write-Error 是**终止性**异常，写在它之后的
        # 任何语句都执行不到——而脚本末尾的边界行只认 $script:RunRc（见 switch 后的注释）。
        $script:RunRc = 1
        Write-Error "配置文件不存在，请先运行 .\backup.ps1 -Task Init"
        return
    }

    # 日志轮转（roadmap A4，与 backup.sh 同形）：排在配置加载之后、引擎动手之前——
    # 阈值来自 $env:SEM_LOG_MAX_BYTES / SEM_LOG_KEEP，而这两个正是 config.ps1 能设的东西。
    # 清单是点名的两个：语义层在 Windows 侧不另开 sem.log（它的告警都进 backup.log），而
    # Task Scheduler 不像 launchd 那样持有独立 stdout 句柄，没有「mv 走之后继续往旧 inode
    # 写」那种必须排除的第三方句柄。
    # 旁路没资格终止本体（§1.3）：函数里一个 Move-Item 撞上「日志被别的进程占用」就会抛
    # 终止性异常，这里 catch 成 warning 继续备份，而不是让一次日志超限变成一整轮失败。
    try {
        $rotMax = if ($env:SEM_LOG_MAX_BYTES -match '^\d+$') { [long]$env:SEM_LOG_MAX_BYTES } else { 4194304 }
        $rotKeep = if ($env:SEM_LOG_KEEP -match '^\d+$') { [int]$env:SEM_LOG_KEEP } else { 7 }
        Rotate-LogFile -Path $BACKUP_LOG -MaxBytes $rotMax -Keep $rotKeep | Out-Null
        Rotate-LogFile -Path $RCLONE_LOG -MaxBytes $rotMax -Keep $rotKeep | Out-Null
    } catch {
        Write-Warning "[log] 轮转失败（不阻断备份）: $($_.Exception.Message)"
    }

    # 加载密码
    if (Test-Path "$CONF_DIR\secrets.env") {
        Get-Content "$CONF_DIR\secrets.env" | ForEach-Object {
            if ($_ -match "^(\w+)='(.+)'") {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2])
            }
        }
    }

    # 加载语义层（非致命：任何失败只告警，不影响备份结论）
    if (Test-Path "$PSScriptRoot\semantic\semantic.ps1") {
        . "$PSScriptRoot\semantic\semantic.ps1"
    }

    Write-Host "=== Partiverse Backup STARTED (Windows) ==="
    Write-Host "Device: $env:DEVICE_ID"

    # 备份目标（rclone 统一管理）：BACKUP_TARGETS 分号分隔多目标 "remote:子路径"，
    # 设备目录自动追加；兼容旧 WEBDAV_REMOTE(+WEBDAV_ROOT) 单目标
    $targets = @()
    if ($env:BACKUP_TARGETS) {
        $targets = @($env:BACKUP_TARGETS -split ';' | Where-Object { $_ })
    } elseif ($env:WEBDAV_REMOTE) {
        $targets = @("${env:WEBDAV_REMOTE}:${env:WEBDAV_ROOT}${env:SYSTEM_ID}")
    }
    if ($targets.Count -eq 0) { Write-Warning "未配置备份目标（BACKUP_TARGETS/WEBDAV_REMOTE 均空）——本次仅本地备份" }

    $failed = 0
    # 红线 §1.4：「本地成功」不等于「云端有可信副本」。云端推送失败必须计入退出码，
    # 不得宣布 FULLY COMPLETE——bash 侧同一件事由 test_cloud_failure.sh 锁住（a1ad332 那发），
    # PowerShell 移植时漏了，此前只 Write-Warning 就继续走 COMPLETE。
    # 这里用 Write-Host 而不是 Write-Error：本函数顶部 $ErrorActionPreference = "Stop"，
    # Write-Error 会变成终止性异常被下面的 catch 接走，把「云端没副本」混计成「引擎类别失败」。
    $cloudFailed = 0
    $semDone = @()
    $classes = @("config", "files", "system")
    foreach ($cls in $classes) {
        $repo = "$BACKUP_BASE\restic-$cls"
        $arcName = "$env:DEVICE_ID-$cls-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

        try {
            Backup-ResticClass -Class $cls -RepoPath $repo -ArcName $arcName
            $semDone += @{ cls = $cls; repo = $repo }

            # 云端用 copy 只增不删（本地已 prune，云端保留全部历史）
            if ($env:SKIP_WEBDAV -ne "1") {
                foreach ($t in $targets) {
                    $dest = Format-CloudDest -Target $t -SystemId $env:SYSTEM_ID -Sub $cls
                    & rclone mkdir $dest 2>$null
                    & rclone copy "$repo/" $dest --transfers 2 --bwlimit 10M --log-file $RCLONE_LOG
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "::error::[rclone] $dest 同步失败 (rc=$LASTEXITCODE)——云端没有这一类的可信副本"
                        $cloudFailed++
                    }
                }
            }
        } catch {
            # ::error:: 注解 CI 匿名可读；附上 backup.log 尾部定位真实原因
            $logTail = try { (Get-Content $env:BACKUP_LOG -Tail 4 -ErrorAction SilentlyContinue) -join ' | ' } catch { '' }
            Write-Error ("[$cls] " + $_.Exception.Message + " | log: " + $logTail)
            $failed++
        }
    }

    # 语义层（research/06）：MANIFEST.txt / STORY.md / restore.md → timeline/
    if ($semDone.Count -gt 0) {
        try {
            Invoke-SemanticLayer -Done $semDone -BackupBase $BACKUP_BASE `
                -DeviceId $env:DEVICE_ID -TimeIso (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            if ($env:SKIP_WEBDAV -ne "1") {
                foreach ($t in $targets) {
                    $tdest = Format-CloudDest -Target $t -SystemId $env:SYSTEM_ID -Sub "timeline"
                    & rclone copy "$BACKUP_BASE\timeline/" "$tdest" `
                        --transfers 2 --bwlimit 10M --log-file $RCLONE_LOG
                    # 明文时间轴是「裸文件管理器可读」这件事的唯一副本，它没上去同样是
                    # 云端没有可信副本（§1.4），不能只把引擎仓库的对平当数
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "::error::[rclone] $tdest 时间轴同步失败 (rc=$LASTEXITCODE)"
                        $cloudFailed++
                    }
                }
            }
        } catch {
            Write-Warning "[semantic] 生成失败（不影响备份）: $($_.Exception.Message)"
        }
    }

    if ($failed -eq 0 -and $cloudFailed -eq 0) {
        # A6 L1：上面那两条只回答「rclone 没报错」，这一步才回答「云端到底有没有」。只在一切
        # 自称成功之后跑——本地失败或推送失败时结论已经定了，再花几分钟列云端没意义。
        # 开关与 backup.sh 同一条：只有显式 SEM_CLOUD_VERIFY=0 之外……照抄 bash 的「== 1 才跑」，
        # 写成「-ne 0」会让 SEM_CLOUD_VERIFY=no 在两份实现上一个跑一个不跑。
        $vsw = if ($env:SEM_CLOUD_VERIFY) { $env:SEM_CLOUD_VERIFY } else { "1" }
        $verifyFailed = 0
        if ($env:SKIP_WEBDAV -ne "1" -and $vsw -eq "1" -and $targets.Count -gt 0) {
            $repoPairs = @($semDone | ForEach-Object { "{0}:{1}" -f $_.cls, $_.repo })
            try {
                # 自证的是**这一轮推出去的那份**，所以报告必须落在时间轴根级、在推送之后写：
                # 它自己随下一轮才上云（先比对、后落笔）。
                $v = Invoke-CloudVerify -Targets $targets -BackupBase $BACKUP_BASE -RepoPairs $repoPairs `
                    -ReportPath (Join-Path $BACKUP_BASE "timeline\CLOUD-VERIFY.txt") -Sha (Get-RunGitSha)
                if ($v.Healed -gt 0) {
                    Write-Warning "[verify] $($v.Healed) 个仓库 config 与云端不一致，已当场强制补传修好——这类不一致推送永远不会自己带走（详见 $($v.Report)）"
                }
                if ($v.Unknown -gt 0) {
                    Write-Warning "[verify] $($v.Unknown) 项 UNKNOWN：网盘读不出清单，这一轮没证成也没证败"
                }
                $verifyFailed = $v.Failed
            } catch {
                # 旁路没资格终止本体（§1.3）：自证自己炸了只是少一份证据，不改备份结论
                Write-Warning "[verify] 自证流程异常退出（少一份证据，不改备份结论）: $($_.Exception.Message)"
            }
        }
        if ($verifyFailed -gt 0) {
            # 同样先落 rc 再打印：EAP=Stop 下 Write-Error 是 throw，脚本末尾的边界行拿不到码。
            # 用 Write-Host 而不是 Write-Error 与上面 cloudFailed 一条同理——这一层要混进
            # 「engine=/cloud=」的计数里就把两种坏法说成了一种。
            $script:RunRc = 1
            Write-Host "::error::=== 推送都报成功，但云端副本自证 $verifyFailed 项不一致——云端副本不可信（详见 timeline\CLOUD-VERIFY.txt） ==="
        } else {
            Write-Host "=== Backup FULLY COMPLETE ==="
            $script:RunRc = 0
        }
    } else {
        # 两种坏法分开计数并都写进结论行：引擎类别失败 vs 云端没有可信副本，处置完全不同。
        # 同样先落 rc：EAP=Stop 下这行 Write-Error 就是 throw，`exit` 走不到，结论一律由
        # 接入点（脚本末尾）用 $script:RunRc 写进边界行并以该码退出。
        $script:RunRc = 1
        Write-Error "=== Backup FINISHED WITH ERRORS (engine=$failed cloud=$cloudFailed) ==="
    }
}

# ---------- 交互式初始化 ----------
function Initialize-PartiverseBackup {
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Partiverse Backup System — Windows 初始化  ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    $CONF_DIR = "$env:APPDATA\PartiverseBackup"
    $LOG_DIR = "$env:LOCALAPPDATA\PartiverseBackup\logs"
    $BACKUP_BASE = "$env:USERPROFILE\PartiverseBackup\repo"
    New-Item -ItemType Directory -Force -Path $CONF_DIR, $LOG_DIR, $BACKUP_BASE | Out-Null

    # 凭证
    $pass1 = Read-Host "  输入备份加密密码" -AsSecureString
    $pass2 = Read-Host "  确认密码" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass1)
    $pass1txt = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass2)
    $pass2txt = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
    if ($pass1txt -ne $pass2txt) { Write-Error "密码不匹配"; exit 1 }

    $webdavUrl = Read-Host "  WebDAV URL [https://webdav.123pan.cn/webdav]"
    if (-not $webdavUrl) { $webdavUrl = "https://webdav.123pan.cn/webdav" }
    $webdavUser = Read-Host "  WebDAV 用户名"
    $webdavPass = Read-Host "  WebDAV 密码" -AsSecureString
    $bstr3 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($webdavPass)
    $webdavPasstxt = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr3)

    # rclone remote
    Write-Host "  配置 rclone WebDAV remote..."
    & rclone config create "Universal Backups" webdav `
        url "$webdavUrl" vendor other user "$webdavUser" pass "$webdavPasstxt" 2>&1 | Out-Null

    # 设备标识 = <设备名>-<系统>，全小写、不含 OS 版本（AGENTS §2：大小写不敏感网盘的安全交集，
    # 且系统升级不应分裂备份历史；OS 版本进 system-meta）。原先写死 "-Windows11" 与 init.sh 的
    # 小写规则不一致——同一台机器两侧会生成两个设备目录，云端历史被劈开。
    $deviceId = ("$env:COMPUTERNAME-Windows").ToLower()
    $systemId = $deviceId

    # 生成配置（三档案默认路径）
    @"
`$env:DEVICE_ID = "$deviceId"
`$env:SYSTEM_ID = "$systemId"
`$env:BACKUP_BASE = "$BACKUP_BASE"
# 备份目标（rclone 统一管理）：分号分隔，格式 "remote:子路径"，设备目录自动追加；
# 可随时 rclone config 增删 remote（B2/S3/WebDAV/NAS…）
`$env:BACKUP_TARGETS = "Universal Backups:"

# config: 敏感凭证与应用配置
`$RESTIC_INCLUDES_config = "$env:USERPROFILE\.ssh;$env:APPDATA"
`$RESTIC_EXCLUDES_config = "node_modules;__pycache__;Cache;*.log"

# files: 用户数据（Known Folders）
`$RESTIC_INCLUDES_files = "$([Environment]::GetFolderPath('MyDocuments'));$([Environment]::GetFolderPath('Desktop'));$([Environment]::GetFolderPath('MyPictures'));$([Environment]::GetFolderPath('MyVideos'))"
`$RESTIC_EXCLUDES_files = "node_modules;__pycache__;*.log"

# system: 系统元数据（初始化时采集）
`$RESTIC_INCLUDES_system = "$CONF_DIR\system-meta"
`$RESTIC_EXCLUDES_system = ""
"@ | Out-File -FilePath "$CONF_DIR\config.ps1" -Encoding utf8

    # 密码
    "RESTIC_PASSWORD='$pass1txt'" | Out-File -FilePath "$CONF_DIR\secrets.env" -Encoding utf8

    Write-Host "  凭证已保存: $CONF_DIR\secrets.env"
    Write-Host "  配置已保存: $CONF_DIR\config.ps1"

    # 安装依赖
    Install-Deps-Windows

    # 采集系统元数据
    $metaDir = "$CONF_DIR\system-meta"
    New-Item -ItemType Directory -Force -Path $metaDir | Out-Null
    winget list > "$metaDir\installed-programs.txt" 2>$null
    Get-Service | Select-Object Name, Status, StartType | Format-Table | Out-String |
        Out-File "$metaDir\services.txt"
    Get-CimInstance Win32_VideoController, Win32_DiskDrive |
        Select-Object Name, Size, DriverVersion | Format-Table | Out-String |
        Out-File "$metaDir\hardware.txt"
    bcdedit /v > "$metaDir\bcd.txt" 2>$null

    # 调度
    Setup-Scheduler-Windows -ScriptPath "$PSScriptRoot\backup.ps1"

    Write-Host ""
    Write-Host "  首次备份..."
    & "$PSCommandPath" -Task Backup
    Write-Host ""
    Write-Host "  初始化完成！手动触发: & `"$PSCommandPath`" -Task Backup" -ForegroundColor Green
}

$script:RunStartTs = Get-Date
$script:RunRc = 0
switch ($Task) {
    "Init"  { Initialize-PartiverseBackup }
    "Backup" {
        try {
            Start-PartiverseBackup
        } catch {
            # ::error:: 注解 CI 匿名可读；本地打印完整堆栈
            Write-Error "$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"
            Write-Error "stack: $($_.ScriptStackTrace)"
            $script:RunRc = 1
        }
    }
}

# run 边界行落在脚本**最末尾这一处**，而不是 try/finally——实测宿主语义不同：pwsh 7 上
# 函数内裸 `exit` 不会触发外层 finally（Windows PowerShell 5.1 会）。真机上 Task Scheduler
# 跑的是 powershell.exe（5.1），但 CI 与开发调试跑 pwsh 7，而恰恰「这一轮判失败」是最需要
# 边界行的那一轮，靠 finally 等于在最需要的时候让它静默消失。所以结论当**值**传出来
# （$script:RunRc），四条出口（全绿 / 引擎类别失败 / 云端无可信副本 / 抛异常）都在同一个
# 落点写一行，再以该码退出。
if ($Task -eq "Backup") {
    # 与 backup.sh 的 `[[ -n "${LOG:-}" ]] || return 0` 同一条：早退的轮次可能连日志目录
    # 都没有（配置缺失就 return 了），边界行是旁路，不去为它新建目录、也不报错。
    $bpath = if ($script:BackupLogPath) { $script:BackupLogPath } else { "$env:LOCALAPPDATA\PartiverseBackup\logs\backup.log" }
    if (Test-Path -LiteralPath (Split-Path -Parent $bpath)) {
        $dur = [int] (New-TimeSpan -Start $script:RunStartTs -End (Get-Date)).TotalSeconds
        Write-RunBoundary -Path $bpath -Sha (Get-RunGitSha) -Rc $script:RunRc -DurationSec $dur
    }
    exit $script:RunRc
}
