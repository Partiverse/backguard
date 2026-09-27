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
                            $exe = Get-ChildItem "$binDir" -Recurse -Filter restic.exe | Select-Object -First 1
                            Move-Item $exe.FullName "$out" -Force
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

    # 清理：本地保留 7d/4w/6m
    & restic -r $RepoPath forget --keep-daily=7 --keep-weekly=4 --keep-monthly=6 2>&1 |
        Tee-Object -FilePath $env:BACKUP_LOG -Append | Out-Null
}

# ---------- 主函数 ----------
function Start-PartiverseBackup {
    $ErrorActionPreference = "Stop"

    $CONF_DIR = "$env:APPDATA\PartiverseBackup"
    $LOG_DIR = "$env:LOCALAPPDATA\PartiverseBackup\logs"
    $BACKUP_BASE = "$env:USERPROFILE\PartiverseBackup\repo"
    $RCLONE_LOG = "$LOG_DIR\rclone.log"
    $BACKUP_LOG = "$LOG_DIR\backup.log"
    # Backup-ResticClass 通过 $env:BACKUP_LOG 引用日志路径
    $env:BACKUP_LOG = $BACKUP_LOG

    New-Item -ItemType Directory -Force -Path $CONF_DIR, $LOG_DIR, $BACKUP_BASE | Out-Null

    # 加载配置
    if (Test-Path "$CONF_DIR\config.ps1") {
        . "$CONF_DIR\config.ps1"
    } else {
        Write-Error "配置文件不存在，请先运行 .\backup.ps1 -Task Init"
        exit 1
    }

    # 加载密码
    if (Test-Path "$CONF_DIR\secrets.env") {
        Get-Content "$CONF_DIR\secrets.env" | ForEach-Object {
            if ($_ -match "^(\w+)='(.+)'") {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2])
            }
        }
    }

    Write-Host "=== Partiverse Backup STARTED (Windows) ==="
    Write-Host "Device: $env:DEVICE_ID"

    $failed = 0
    $classes = @("config", "files", "system")
    foreach ($cls in $classes) {
        $repo = "$BACKUP_BASE\restic-$cls"
        $arcName = "$env:DEVICE_ID-$cls-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $remote = "${env:WEBDAV_REMOTE}:${env:WEBDAV_ROOT}${env:SYSTEM_ID}/$cls/"

        try {
            Backup-ResticClass -Class $cls -RepoPath $repo -ArcName $arcName

            # 云端用 copy 只增不删（本地已 prune，云端保留全部历史）
            if ($env:SKIP_WEBDAV -ne "1") {
                & rclone mkdir $remote 2>$null
                & rclone copy "$repo/" $remote --transfers 2 --bwlimit 10M --log-file $RCLONE_LOG
                if ($LASTEXITCODE -ne 0) { Write-Warning "[WebDAV] 同步失败" }
            }
        } catch {
            # ::error:: 注解 CI 匿名可读；附上 backup.log 尾部定位真实原因
            $logTail = try { (Get-Content $env:BACKUP_LOG -Tail 4 -ErrorAction SilentlyContinue) -join ' | ' } catch { '' }
            Write-Output ("::error::[$cls] " + $_.Exception.Message + " | log: " + $logTail)
            $failed++
        }
    }

    if ($failed -eq 0) {
        Write-Host "=== Backup FULLY COMPLETE ==="
    } else {
        Write-Error "=== Backup FINISHED WITH ERRORS ($failed failed) ==="
        exit 1
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

    $deviceId = "$env:COMPUTERNAME-Windows11"
    $systemId = $deviceId

    # 生成配置（三档案默认路径）
    @"
`$env:DEVICE_ID = "$deviceId"
`$env:SYSTEM_ID = "$systemId"
`$env:BACKUP_BASE = "$BACKUP_BASE"
`$env:WEBDAV_REMOTE = "Universal Backups"
`$env:WEBDAV_ROOT = ""

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

switch ($Task) {
    "Init"  { Initialize-PartiverseBackup }
    "Backup" {
        try {
            Start-PartiverseBackup
        } catch {
            # CI 可匿名读取 error 注解，本地打印完整堆栈
            Write-Host "::error::$($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)"
            Write-Host $_.ScriptStackTrace
            exit 1
        }
    }
}
