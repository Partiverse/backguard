# Partiverse Backup System — Windows 平台 (PowerShell)
# 使用 restic 作为备份引擎，rclone 同步 WebDAV
param([string]$Task = "Backup")

# ---------- 5.1 宿主口径：原生命令必须在 ErrorActionPreference=Continue 的作用域里跑 ----------
# 真机实测（run 37003329872 的 5.1 探针，`probe_windows_ps51.ps1` 事实 3，宿主
# PS 5.1.26100.33438）：Windows PowerShell 下 `$ErrorActionPreference = "Stop"` 的作用域里，
# 原生命令**只要往 stderr 写一行就抛终止性异常**，三种形态全抛：
#   tee2>&1=THREW RemoteException  redirect2null=THREW RemoteException  pipeOutNull=THREW RemoteException
# 而备份引擎的正常输出偏偏就写在 stderr（restic 的进度、rclone 的 `NOTICE: Config file ... not
# found`）。Task Scheduler 注册的是 `powershell.exe -File backup.ps1`，正是这一档；CI 的真实备份
# job 用 `pwsh.exe`（7 不抛，这是 5.1 与 7 的语义差别之一），所以这条在 CI 全绿的窗口里躺了
# 整个观察期——第一次 `restic backup` 就会把整轮带走，第二次起 `restic init`（幂等分支，靠的
# 就是「忽略报错」）也带得走。
# 因此：**每个含原生命令的函数首句把 EAP 压回 Continue**（赋值是函数作用域的，出函数自动回到
# 调用方的 Stop，cmdlet 那一份纪律一点没丢），主流程里的云端推送循环收进同样的函数。
# **成败判定一律不靠异常，靠 $LASTEXITCODE 与显式 throw**——`throw` 在 Continue 下同样是终止性的，
# 所以 try/catch 的结构一处没动。
# 守卫：`probe_windows_ps51.ps1` 事实 5 用解析器扫 backup.ps1 的每个原生命令调用点，要求它所在
# 作用域在调用之前有这条赋值；CI 另有一步「5.1 下真跑一轮备份」把这条钉成行为面（摘掉任一处
# 赋值那一轮就红，不是红在静态检查而是红在退出码）。

# ---------- 依赖安装 ----------
function Install-Deps-Windows {
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
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
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」：restic 的进度就写在 stderr

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

    # 清理：本地保留 7d/4w/6m。抽成 Invoke-ResticRetention 是为了让它**能被单独跑**——
    # CI 的 windows job 每轮新建空仓库，forget 在这里一份都裁不掉，所以「保留策略真的回收字节」
    # 这一整段在原位等于从未被测（§4.19 留的那发）。判定与 rc 口径一个字都没动。
    # （收进 [void]：这函数带返回值，漏进调用点的成功流就会在 stdout 里多出一坨哈希表）
    [void](Invoke-ResticRetention -Class $Class -RepoPath $RepoPath -LogPath $env:BACKUP_LOG)
}

# BEGIN-RETENTION —— test_retention_logic.ps1 靠这两行标记把本函数**原样**切出去，对着真
# restic 跑（预置 9 份带 `--time` 的日快照，要求快照数按口径减少**且仓库字节真的下降**）。
# 为什么必须带 `--prune`：restic 的 forget 只删快照对象，引擎帮助页原话「In order to remove
# the unreferenced data after "forget" was run successfully, see the "prune" command」——
# 实测 9 份日快照 forget 退出 0、快照少两份，仓库字节数一字节没少。少了这一步，
# 「本地已 prune，云端保留全部历史」那句前提就不成立，本地仓库与云端副本一起只增不减。
# rc 口径与 backup.sh 的 backup_restic_class 逐条对齐：3 = 部分生效（有快照没删掉，下晚重试）
# 只告警；其余非零判本类失败——保留策略没跑成的唯一后果是仓库无限增长，
# 而观察期里没人会主动去查仓库尺寸。
function Invoke-ResticRetention {
    param(
        [Parameter(Mandatory = $true)][string]$Class,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$LogPath = "",
        [string]$ResticBin = "restic"
    )
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
    $out = @(& $ResticBin "-r" $RepoPath "forget" "--keep-daily=7" "--keep-weekly=4" `
        "--keep-monthly=6" "--prune" 2>&1 | ForEach-Object { "$_" })
    $rc = $LASTEXITCODE
    if ($LogPath) {
        try {
            # 引擎原文只进本地日志：调用点原来用 Tee-Object 边流边写，这里改成收进数组再落笔，
            # 差别是崩溃时少半截——但换来的是这一层能被单独调用并拿到 rc
            $out | Add-Content -LiteralPath $LogPath -Encoding utf8
        } catch { }
    }
    if ($rc -eq 3) {
        Write-Warning "[$Class] forget/prune 部分生效 (rc=3)"
    } elseif ($rc -ne 0) {
        throw "[$Class] restic forget/prune 失败 (exit $rc)"
    }
    @{ rc = $rc; out = $out }
}
# END-RETENTION

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
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
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
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」：rclone 的 NOTICE 写在 stderr
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
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
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
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
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

# BEGIN-INTEGRITY —— 同一条哨兵约定：这一段被 test_integrity_logic.ps1 按标记原样切走单独跑
# A2a 引擎仓库的存储完整性月度校验（对位 backup.sh 的 run_integrity_check）。
# 为什么必须有：仓库里某个 pack 腐化**不会**让 backup 失败（10-01 在 borg 侧实测过同一件事），
# 也就是说没有这一步，现有全部守卫对「存着的字节坏了」这一类恒为绿——只有主动整仓读一遍
# 才看得见。--read-data 才是「把整仓读一遍」：不带它时 restic check 只查快照/树/blob 的**结构**
# （引擎帮助页原话 To also verify the integrity of the actual backed-up data, use the
# --read-data flag），与 borg 侧的 --verify-data 对位。
#
# 判定口径与 backup.sh 的 restic 分支逐字对齐，改任何一条前先读那边的注释：
#   ①三档判定。restic 的退出码**本来就分档**（引擎 EXIT STATUS：0 成功 / 1 有错 / 10 仓库不存在 /
#     11 已被锁 / 12 口令不对），所以这边不需要 borg 那套「读错误原文猜是不是锁」——Windows 侧
#     只有 restic 一个引擎，backup.ps1 从不碰 borg。
#   ②只有 11 记 UNKNOWN 且不改退出码：并发的手工操作不该把用户叫醒；10/12 是真问题（仓库没了、
#     凭据不对），和发现坏数据一样按最坏情况判 FAIL。
#   ③窗口节流用**产物自身的 mtime**当标记（与 rescue-test.txt 同一条机制，不另养状态文件）；
#     INTEGRITY_DAYS=0 是人工立刻跑的入口。低频路径的节流本身要被测，否则「月度」只是文档里的形容词。
#   ④引擎原文只进本地日志，一个字节都不抄进报告：报告随时间轴上云，而错误行里带仓库绝对路径
#     （红线 §1.1 同一条口径）。
#   ⑤没登记任何仓库时**不写报告**：一份 checks=0 的「完整性通过」比没有更坏。

function Get-IntegrityWindowDays {
    if ($env:INTEGRITY_DAYS -match '^\d+$') { return [int]$env:INTEGRITY_DAYS }
    30
}

function Reset-IntegrityState {
    $script:IntegrityLines = @()
    $script:IntegrityFailed = 0
    $script:IntegrityUnknown = 0
}

# FAIL 计数只由 Format-IntegrityNote 一处维护：调用点写错状态（把 FAIL 拼成 FATAL）就会让
# 整轮「一项失败都没记」却仍然 FULLY COMPLETE，所以状态字符串不许在别处手拼。
function Format-IntegrityNote {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $script:IntegrityLines += ("{0,-8} {1,-14} {2}" -f $Status, $Label, $Detail)
    switch ($Status) {
        "FAIL"    { $script:IntegrityFailed = $script:IntegrityFailed + 1 }
        "UNKNOWN" { $script:IntegrityUnknown = $script:IntegrityUnknown + 1 }
    }
}

# 到期判据。$true 才会真的跑引擎（几分钟量级），所以这一条本身是被测面：
# 写反了要么每晚整仓读一遍（观察期不该有的流量），要么一个月都不读（那这层证据等于没有）。
function Test-IntegrityDue {
    param([Parameter(Mandatory = $true)][string]$ReportPath)
    $sw = if ($env:INTEGRITY_VERIFY) { $env:INTEGRITY_VERIFY } else { "1" }
    if ($sw -ne "1") { return $false }
    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return $true }
    $days = Get-IntegrityWindowDays
    $last = $null
    try { $last = (Get-Item -LiteralPath $ReportPath).LastWriteTime } catch { }
    # 读不到 mtime 时按「到期」处理：宁可在同一窗口多读一遍，也不要因为一次 stat 失败把整月的
    # 校验机会跳过去（bash 侧 file_mtime helper 缺失时同样 return 0 = 到期）
    if (-not $last) { return $true }
    $ageSec = (New-TimeSpan -Start $last -End (Get-Date)).TotalSeconds
    return ($ageSec -ge ($days * 86400))
}

# 单个仓库的一次校验，返回 @{rc; durSec; out}。引擎路径走参数而不是写死 `restic`：守卫要在
# PATH 上放一个桩来喂「拿不到锁 / 非锁类 fatal / 往 stderr 写东西」这几档，真损坏那一档才用
# 真实二进制（与 bash 的 $RESTIC、test_integrity.sh 的borg-selflock/borg-fatal 分工同形）。
function Invoke-ResticCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [string]$ResticBin = "restic"
    )
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
    $t0 = Get-Date
    $invoked = $false
    $rc = 127
    $out = ""
    try {
        $out = @(& $ResticBin "-r" $Repo "check" "--read-data" 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $invoked = $true
        if ($null -ne $LASTEXITCODE) { $rc = $LASTEXITCODE }
    } catch {
        $out = $_.Exception.Message
    }
    # 没真的调起来（二进制不在 / 路径拼错）＝ 127，绝不能沿用上一条命令留下的 $LASTEXITCODE
    # 当本轮结论——那正是「命令没跑成却记 PASS」的形状
    if (-not $invoked) { $rc = 127 }
    @{
        rc     = $rc
        durSec = [int] (New-TimeSpan -Start $t0 -End (Get-Date)).TotalSeconds
        out    = $out
    }
}

function Write-IntegrityReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines,
        [int]$Failed = 0,
        [int]$Unknown = 0,
        [string]$Sha = "nogit"
    )
    # 字符串数组一次成形再写：逐行 Add-Content 在 5.1 上编码/换行口径读不准，而这里一旦漏行
    # 就是报告头部少一行、汇总计数变成字符串。
    $body = @(
        "# 存储完整性校验（A2a）——按月把每个引擎仓库整仓读一遍",
        ("# 生成时间: {0}   代码基: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Sha),
        "# 它证明的是「存着的字节没坏、还能解密解压缩」；「取回路径可用」由恢复演练",
        "#   （rescue-test.txt / CLOUD-VERIFY 之外的那份）负责，两者不互相替代。",
        "# 判据（restic check --read-data；引擎的 EXIT STATUS 本来就分档）: rc=0 通过；",
        "#   rc=11（已被锁）记 UNKNOWN 且不改本轮退出码——并发的手工操作不该把用户叫醒；",
        "#   rc=1 逐包读取发现坏数据或结构不一致；rc=10/12（仓库不存在/口令不对）与其余非零",
        "#   按最坏情况判 FAIL。",
        "# 引擎原文**不抄进本文件**：它是随时间轴上云的明文产物，而错误行里会带仓库绝对路径。",
        ("# 汇总: checks={0} FAIL={1} UNKNOWN={2}" -f @($Lines).Count, $Failed, $Unknown)
    ) + @($Lines)
    try {
        $body | Out-File -FilePath $Path -Encoding utf8
        return $true
    } catch {
        Write-Host ("INTEGRITY-REPORT-WRITE-FAILED {0}" -f $_.Exception.Message)
        return $false
    }
}

# $RepoPairs 元素 `类别:本地仓库路径`，由调用点登记。规矩与云端自证那条一样：忘了登记＝这一类
# 根本没跑，而整轮结论照样全绿（A6 第一版就是这么把缺陷藏过去的）。
# 返回 @{Failed; Unknown; Skipped; Report}——调用点只看这个值，不跨作用域读 $script: 状态。
function Invoke-IntegrityCheck {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RepoPairs,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [string]$LogPath = "",
        [string]$Sha = "nogit",
        [string]$ResticBin = "restic"
    )
    # 旁路：函数内把 EAP 收到 Continue。调用点顶部是 Stop，而 restic 的 check 全程往 stderr 打
    # 进度，在 Windows PowerShell 5.1 上那会变成终止性异常（与自证同一颗雷，见 Invoke-CloudVerify）
    $ErrorActionPreference = "Continue"
    Reset-IntegrityState
    if (-not (Test-IntegrityDue -ReportPath $ReportPath)) {
        Write-Host ("[integrity] 未到校验窗口（{0} 天内已跑过，或 INTEGRITY_VERIFY=0），跳过" -f (Get-IntegrityWindowDays))
        return @{ Failed = 0; Unknown = 0; Skipped = $true; Report = "" }
    }
    # 报告落在时间轴根。Windows 侧没有语义层替我们建这个目录的保证，没人建它就写不出来，
    # 而「报告没落盘」在这一步的语义等于「这月的证据没了」
    try {
        $parent = Split-Path -Parent $ReportPath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    } catch { }
    if (@($RepoPairs).Count -eq 0) {
        Write-Host "[integrity] 本轮没有登记任何引擎仓库，未做存储完整性校验"
        return @{ Failed = 0; Unknown = 0; Skipped = $false; Report = "" }
    }
    foreach ($pair in $RepoPairs) {
        $idx = $pair.IndexOf(":")
        if ($idx -lt 1) {
            Format-IntegrityNote UNKNOWN "restic:?" ("登记串不是 `类别:路径` 形状（{0}）" -f $pair)
            continue
        }
        $cls = $pair.Substring(0, $idx)
        $repo = $pair.Substring($idx + 1)
        if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
            Format-IntegrityNote UNKNOWN "restic:$cls" "本地仓库目录读不到，这一项没证成也没证败"
            continue
        }
        $r = Invoke-ResticCheck -Repo $repo -ResticBin $ResticBin
        if ($LogPath) {
            try {
                Add-Content -LiteralPath $LogPath -Value $r.out -Encoding utf8
                Add-Content -LiteralPath $LogPath `
                    -Value ("[integrity] restic check --read-data {0} -> rc={1} ({2}s)" -f $cls, $r.rc, $r.durSec) `
                    -Encoding utf8
            } catch { }
        }
        switch ($r.rc) {
            0 { Format-IntegrityNote PASS "restic:$cls" ("{0}s 逐包读取校验通过（存储没腐化）" -f $r.durSec) }
            11 { Format-IntegrityNote UNKNOWN "restic:$cls" ("{0}s 拿不到仓库锁（有别的 restic 在跑），这一项没证成也没证败" -f $r.durSec) }
            1 { Format-IntegrityNote FAIL "restic:$cls" ("{0}s 后 rc=1：逐包读取发现坏数据或结构不一致，详见本地 backup.log" -f $r.durSec) }
            default { Format-IntegrityNote FAIL "restic:$cls" ("{0}s 后 rc={1}：非锁类失败（10 仓库不存在 / 12 口令不对 / 引擎没跑成），详见本地 backup.log" -f $r.durSec, $r.rc) }
        }
    }
    $ok = Write-IntegrityReport -Path $ReportPath -Lines $script:IntegrityLines `
        -Failed $script:IntegrityFailed -Unknown $script:IntegrityUnknown -Sha $Sha
    @{
        Failed  = $script:IntegrityFailed
        Unknown = $script:IntegrityUnknown
        Skipped = $false
        Report  = $(if ($ok) { $ReportPath } else { "" })
    }
}
# END-INTEGRITY

# ---------- 云端推送 ----------
# 为什么单独成函数而不是留在主流程里：这一层有两个 rclone 调用，而调用方
# Start-PartiverseBackup 的 `$ErrorActionPreference = "Stop"` 在 5.1 宿主上会把 rclone 写在
# stderr 的 NOTICE 变成终止性异常（见文件头「5.1 宿主口径」）。函数作用域里压回 Continue，
# 出函数即还原——Stop 那份 cmdlet 纪律一点没丢，而「引擎调用的退出码」回到调用点用
# $LASTEXITCODE 判定（异常不参与判定）。
# $EnsureDir 只有类别仓库用：时间轴那份推送历来不建目录，加一遍等于改网盘上的目录形状。
function Push-TreeToCloud {
    param(
        [Parameter(Mandatory = $true)][string]$SrcRoot,
        [Parameter(Mandatory = $true)][string[]]$Targets,
        [Parameter(Mandatory = $true)][string]$Sub,
        [Parameter(Mandatory = $true)][string]$RcloneLog,
        [switch]$EnsureDir
    )
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
    $bad = 0
    foreach ($t in $Targets) {
        $dest = Format-CloudDest -Target $t -SystemId $env:SYSTEM_ID -Sub $Sub
        # 引擎输出走 host 而不是返回流：本函数的返回值必须是「失败的目标数」这一个整数。
        # 收进返回流的任何一行 stdout 都会让 `$cloudFailed += Push-TreeToCloud …` 变成数组，
        # 调用点那句「云端有没有可信副本」的判定随即失真（§1.4 那条红线就靠这个数）。
        # 落点与抽出前的内联循环一致（stdout 进日志、stderr 不吞），只是不再进函数输出。
        if ($EnsureDir) { & rclone mkdir $dest 2>$null | Out-Host }
        & rclone copy $SrcRoot $dest --transfers 2 --bwlimit 10M --log-file $RcloneLog | Out-Host
        # 明文时间轴与引擎仓库在这里是同一条红线（§1.4）：任一目标没上去就是「云端没有可信副本」，
        # 只报不判等于让 FULLY COMPLETE 骗过接入点
        if ($LASTEXITCODE -ne 0) {
            Write-Host "::error::[rclone] $dest 同步失败 (rc=$LASTEXITCODE)——云端没有 $Sub 这一份的可信副本"
            $bad++
        }
    }
    $bad
}

# ---------- 权限面（roadmap A2a 的邻居：与 backup.sh 的整树 chmod 同一件事）----------
# BEGIN-PERMS —— test_perms_logic.ps1 靠这两行标记把本函数**原样**切出去，对着 icacls 桩跑
# （容器里只有 `.sh` 那一支，真 icacls 只有 windows runner 走得到）。
#
# 为什么必须有这一发（与 §2 那条权限教训同形）：Windows 上任何新建目录都从父目录**继承** DACL，
# 而 %APPDATA%、%LOCALAPPDATA%、%USERPROFILE% 的默认继承里都带着 `BUILTIN\Users`——同一台机器上的
# 别的账号能遍历并读到 `secrets.env`（restic 口令）与 `age\` 私钥目录。真机实测那一课的原话是
# 「点名式清单注定还要漏」（bash 侧补了 `*.log` 就漏 `age/` 子目录），所以这里**不点名文件**，
# 只对根做两件事：`/inheritance:r` 断开继承、`/grant:r "*<当前用户 SID>:(OI)(CI)F"` 只留自己。
# 子项靠**动态继承**自动跟上：Windows 的继承 ACE 不是创建时烤死的，父档 DACL 一改，没主动断开
# 继承的子项（restic/rclone/PowerShell 建的那些都不曾断开）当场跟着变，所以整棵树一次调用就归一，
# 不必为几千个 chunk 文件逐个跑 icacls（bash 侧不递归进仓库目录是同一取舍）。
#
# 非致命（§1.3）：icacls 返回非零只告警并计入 `bad`，绝不终止这一轮——收紧失败等于「维持原状」，
# 而把一次旁路失败变成整轮失败会让告警通道失去信任。口令/私钥读得到与否由这条旁路负责，
# 由 CI 里「Assert private permission surface」那一步对着真 icacls 的结果判红。
function Set-PrivateAcl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tree,
        [string]$Sid = "",
        [string]$IcaclsBin = "icacls"
    )
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」：icacls 的报错写在 stderr
    if (-not $Sid) {
        $Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $grant = "*${Sid}:(OI)(CI)F"
    $applied = @()
    $bad = @()
    foreach ($t in $Tree) {
        if (-not $t) { continue }
        if (-not (Test-Path -LiteralPath $t)) { continue }   # 还没建的树不判失败
        & $IcaclsBin $t "/inheritance:r" "/grant:r" $grant | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[perms] icacls 对 $t 返回 $LASTEXITCODE——这一棵树本轮没被收紧（旁路不终止备份）"
            $bad += $t
        } else {
            $applied += $t
        }
    }
    @{ sid = $Sid; applied = $applied; bad = $bad }
}
# END-PERMS

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

    # 权限面归一化（roadmap ⑧，与 backup.sh 的整树 chmod 同一件事）：排在建目录之后、
    # 读 secrets.env 之前——凭据被同机账号读到的那一段时间越短越好，而它完全不依赖配置读得成不成。
    # 四棵树：配置（secrets.env + age\）、日志、仓库根（timeline 明文层在里面）、
    # 以及默认仓库根的**父**目录——`Install-Deps-Windows` 把 restic/rclone 落在
    # `%USERPROFILE%\PartiverseBackup\bin`，它不在 $BACKUP_BASE（= 同级的 repo 子目录）之下，
    # 点名清单少写这一条就等于漏掉整个工具目录（§2「点名式清单注定还要漏」的又一形）。
    try {
        [void](Set-PrivateAcl -Tree @($CONF_DIR, $LOG_DIR, $BACKUP_BASE,
            "$env:USERPROFILE\PartiverseBackup"))
    } catch {
        Write-Warning "[perms] 权限面归一化异常退出（不阻断备份）: $($_.Exception.Message)"
    }

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
                $cloudFailed += Push-TreeToCloud -SrcRoot "$repo/" -Targets $targets `
                    -Sub $cls -RcloneLog $RCLONE_LOG -EnsureDir
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
                # 明文时间轴是「裸文件管理器可读」这件事的唯一副本，它没上去同样是云端没有
                # 可信副本（§1.4），不能只把引擎仓库的对平当数
                $cloudFailed += Push-TreeToCloud -SrcRoot "$BACKUP_BASE\timeline/" `
                    -Targets $targets -Sub "timeline" -RcloneLog $RCLONE_LOG
            }
        } catch {
            Write-Warning "[semantic] 生成失败（不影响备份）: $($_.Exception.Message)"
        }
    }

    if ($failed -eq 0 -and $cloudFailed -eq 0) {
        # 这一轮备份成功的那些仓库，两条旁路共用同一份登记表：自证要知道「该有哪些仓库」，
        # 完整性校验要知道「该读哪些仓库」。两处各建一遍＝其中一处漏登记，而漏的那一类永远
        # 没人读（A6 第一版漏 repo_pairs、A2b 记哈希的抽样与 drill 抽样分家，同一课）。
        $repoPairs = @($semDone | ForEach-Object { "{0}:{1}" -f $_.cls, $_.repo })
        # A6 L1：上面那两条只回答「rclone 没报错」，这一步才回答「云端到底有没有」。只在一切
        # 自称成功之后跑——本地失败或推送失败时结论已经定了，再花几分钟列云端没意义。
        # 开关与 backup.sh 同一条：只有显式 SEM_CLOUD_VERIFY=0 之外……照抄 bash 的「== 1 才跑」，
        # 写成「-ne 0」会让 SEM_CLOUD_VERIFY=no 在两份实现上一个跑一个不跑。
        $vsw = if ($env:SEM_CLOUD_VERIFY) { $env:SEM_CLOUD_VERIFY } else { "1" }
        $verifyFailed = 0
        if ($env:SKIP_WEBDAV -ne "1" -and $vsw -eq "1" -and $targets.Count -gt 0) {
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
            # A2a：本地字节层的完整性。「云端有一致的副本」和「副本本身没腐化」是两个问题，
            # 后者只有把整仓读一遍才暴露，所以按月主动跑（窗口见 Test-IntegrityDue）。
            # 它不碰网盘，所以 SKIP_WEBDAV=1 的 CI job 照样跑到——这是这条生产面的被测来源
            # （backup.sh 同一句口径）。排在自证之后：自证已经判红就先把那一条报出来，
            # 两种坏法各有自己的结论行，不合并（合并＝读的人分不清坏在哪一步）。
            $integrity = $null
            try {
                $integrity = Invoke-IntegrityCheck -RepoPairs $repoPairs `
                    -ReportPath (Join-Path $BACKUP_BASE "timeline\INTEGRITY.txt") `
                    -LogPath $BACKUP_LOG -Sha (Get-RunGitSha)
            } catch {
                # 旁路没资格终止本体（§1.3）：校验自己炸了只是少一份证据，不改备份结论
                Write-Warning "[integrity] 存储完整性校验流程异常退出（少一份证据，不改备份结论）: $($_.Exception.Message)"
            }
            if ($integrity -and $integrity.Failed -gt 0) {
                $script:RunRc = 1
                Write-Host ("::error::=== 存储完整性校验 {0} 项失败——本地仓库里有解密/校验不过的数据（详见 timeline\INTEGRITY.txt 与本地 backup.log） ===" -f $integrity.Failed)
            } else {
                Write-Host "=== Backup FULLY COMPLETE ==="
                $script:RunRc = 0
            }
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
    $ErrorActionPreference = "Continue"   # 见文件头「5.1 宿主口径」
    Write-Host ""
    Write-Host "  ╔═══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   Partiverse Backup System — Windows 初始化  ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    $CONF_DIR = "$env:APPDATA\PartiverseBackup"
    $LOG_DIR = "$env:LOCALAPPDATA\PartiverseBackup\logs"
    $BACKUP_BASE = "$env:USERPROFILE\PartiverseBackup\repo"
    New-Item -ItemType Directory -Force -Path $CONF_DIR, $LOG_DIR, $BACKUP_BASE | Out-Null
    # 初始化向导里也要收一次：口令与 age 私钥是在**这一步**第一次落盘的，等 nightly 才收紧等于
    # 把敞口留给首备之前的那段时间（backup.sh 侧同理——chmod 在 init 与 nightly 两处都在）。
    try {
        [void](Set-PrivateAcl -Tree @($CONF_DIR, $LOG_DIR, $BACKUP_BASE,
            "$env:USERPROFILE\PartiverseBackup"))
    } catch {
        Write-Warning "[perms] 权限面归一化异常退出（不阻断初始化）: $($_.Exception.Message)"
    }

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
