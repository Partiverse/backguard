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
                    # ":/" 会被解析成文件系统绝对路径——归一为 "remote:设备/类"
                    $dest = ("$t/$($env:SYSTEM_ID)/$cls") -replace '://', ':'
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
                    $tdest = ($t + "/" + $env:SYSTEM_ID + "/timeline/") -replace '://', ':'
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
        Write-Host "=== Backup FULLY COMPLETE ==="
        $script:RunRc = 0
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
