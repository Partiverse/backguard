# Partiverse Backup System — Windows 平台 (PowerShell)
# 使用 restic 作为备份引擎，rclone 同步 WebDAV

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
                # 下载 restic Windows amd64
                $url = "https://github.com/restic/restic/releases/latest/download/restic_windows_amd64.exe"
                $out = "$binDir\restic.exe"
                try {
                    Invoke-WebRequest $url -OutFile $out -TimeoutSec 30
                } catch {
                    Write-Warning "下载失败，请手动安装 restic: https://restic.net"
                }
            } elseif ($bin -eq "rclone") {
                # rclone Windows
                $url = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
                $out = "$env:TEMP\rclone.zip"
                try {
                    Invoke-WebRequest $url -OutFile $out -TimeoutSec 60
                    Expand-Archive $out -DestinationPath "$binDir" -Force
                    Move-Item "$binDir\rclone-*-windows-amd64\rclone.exe" "$binDir\rclone.exe" -Force
                } catch {
                    Write-Warning "下载失败，请手动安装 rclone: https://rclone.org"
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

    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Write-Host "[Windows] Task Scheduler 任务 '$taskName' 已创建"
}

# ---------- 备份核心 (restic) ----------
function Backup-ResticClass {
    param([string]$Class, [string]$RepoPath, [string]$ArcName)

    Write-Host "[$Class] 归档: $ArcName"

    # 初始化 repo（幂等）
    $env:RESTIC_PASSWORD = $env:RESTIC_PASSWORD
    & restic -r $RepoPath init 2>&1 | Out-Null

    # 备份
    $inclKey = "RESTIC_INCLUDES_$Class"
    $exclKey = "RESTIC_EXCLUDES_$Class"
    $incl = (Get-Variable $inclKey -ValueOnly -ErrorAction SilentlyContinue) -split ';'
    $excl = (Get-Variable $exclKey -ValueOnly -ErrorAction SilentlyContinue) -split ';'

    $resticArgs = @("-r", $RepoPath, "backup", "--host", $env:DEVICE_ID)
    foreach ($e in $excl) { if ($e) { $resticArgs += "--exclude"; $resticArgs += $e } }
    foreach ($i in $incl) { if ($i) { $resticArgs += $i } }

    & restic @resticArgs 2>&1 | Tee-Object -FilePath $env:BACKUP_LOG -Append

    # 清理
    & restic -r $RepoPath forget --keep-daily=7 --keep-weekly=4 --keep-monthly=6 2>&1 | Tee-Object -FilePath $env:BACKUP_LOG -Append
}

# ---------- 主函数 ----------
function Start-PartiverseBackup {
    $ErrorActionPreference = "Stop"

    $CONF_DIR = "$env:APPDATA\PartiverseBackup"
    $LOG_DIR = "$env:LOCALAPPDATA\PartiverseBackup\logs"
    $BACKUP_BASE = "$env:USERPROFILE\PartiverseBackup\repo"
    $RCLONE_LOG = "$LOG_DIR\rclone.log"
    $BACKUP_LOG = "$LOG_DIR\backup.log"

    New-Item -ItemType Directory -Force -Path $CONF_DIR, $LOG_DIR, $BACKUP_BASE | Out-Null

    # 加载配置
    if (Test-Path "$CONF_DIR\config.ps1") {
        . "$CONF_DIR\config.ps1"
    } else {
        Write-Error "配置文件不存在，请先运行 init.ps1"
        exit 1
    }

    # 加载密码
    if (Test-Path "$CONF_DIR\secrets.env") {
        Get-Content "$CONF_DIR\secrets.env" | ForEach-Object {
            if ($_ -match '^(\w+)=(.+)') {
                [Environment]::SetEnvironmentVariable($matches[1], $matches[2])
            }
        }
    }

    Write-Host "=== Partiverse Backup STARTED (Windows) ==="
    Write-Host "Device: $env:DEVICE_ID"

    $classes = @("config", "files", "system")
    foreach ($cls in $classes) {
        $repo = "$BACKUP_BASE\restic-$cls"
        $arcName = "$env:DEVICE_ID-$cls-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

        Backup-ResticClass -Class $cls -RepoPath $repo -ArcName $arcName

        # rclone sync to WebDAV
        $remote = "WebDAV:${env:WEBDAV_ROOT}${env:SYSTEM_ID}/$cls/"
        Write-Host "同步 -> $remote"
        & rclone mkdir $remote 2>$null
        & rclone sync "$repo/" $remote --transfers 2 --bwlimit 10M --log-file $RCLONE_LOG 2>&1 | Out-Null
    }

    Write-Host "=== Backup FULLY COMPLETE ==="
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
    $webdavUser = Read-Host "  WebDAV 用户名"
    $webdavPass = Read-Host "  WebDAV 密码" -AsSecureString
    $bstr3 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($webdavPass)
    $webdavPasstxt = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr3)

    # rclone remote
    Write-Host "  配置 rclone WebDAV remote..."
    & rclone config create "Universal Backups" webdav `
        url "$webdavUrl" vendor other user "$webdavUser" pass "$webdavPasstxt" 2>&1 | Out-Null

    $deviceId = "$env:COMPUTERNAME-Windows"
    $systemId = $deviceId

    # 生成配置
    @"
`$env:DEVICE_ID = "$deviceId"
`$env:SYSTEM_ID = "$systemId"
`$env:BACKUP_BASE = "$BACKUP_BASE"
`$env:WEBDAV_REMOTE = "Universal Backups"
`$env:WEBDAV_ROOT = ""
"@ | Out-File -FilePath "$CONF_DIR\config.ps1" -Encoding utf8

    # 密码
    "RESTIC_PASSWORD='$pass1txt'" | Out-File -FilePath "$CONF_DIR\secrets.env" -Encoding utf8

    Write-Host "  凭证已保存: $CONF_DIR\secrets.env"
    Write-Host "  配置已保存: $CONF_DIR\config.ps1"

    # 安装依赖
    Install-Deps-Windows

    # 调度
    Setup-Scheduler-Windows -ScriptPath "$PSScriptRoot\backup.ps1"

    Write-Host ""
    Write-Host "  首次备份..."
    & "$PSScriptRoot\backup.ps1"
    Write-Host ""
    Write-Host "  初始化完成！手动触发: & `"$PSCommandPath`" -Task Backup" -ForegroundColor Green
}

# 根据参数决定行为
param([string]$Task = "Backup")
switch ($Task) {
    "Init"  { Initialize-PartiverseBackup }
    "Backup" { Start-PartiverseBackup }
}
