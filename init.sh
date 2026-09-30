#!/usr/bin/env bash
#================================================================
# Partiverse Backup System — 交互式初始化
# 支持 Linux / macOS / Windows (Git Bash / MSYS2)
#================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo "[$(date '+%H:%M:%S')] $*"; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Partiverse Backup System 初始化向导   ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo "  三平台统一备份: Linux (borg) · macOS (borg) · Windows (restic)"
echo "  GitHub: git@github.com:Partiverse/backguard.git"
echo ""

# ---------- 平台检测 ----------
case "$(uname -s)" in
    Linux*)     PLATFORM=linux; OS_NAME=$(. /etc/os-release && echo "$NAME"); OS_VER=$(. /etc/os-release && echo "$VERSION_ID");;
    Darwin*)    PLATFORM=macos; OS_NAME=$(sw_vers -productName); OS_VER=$(sw_vers -productVersion);;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows; OS_NAME="Windows"; OS_VER=$(cmd /c ver 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1);;
    *)          echo "FATAL: 未知平台"; exit 1;;
esac

# 设备名 = 稳定标识：短主机名去 .local 后缀（Bonjour 名），不含 OS 版本——
# 系统升级不应分裂备份历史（OS 版本记入 system-meta/manifest.txt）
DEVICE_NAME=$(hostname -s 2>/dev/null || hostname)
DEVICE_NAME="${DEVICE_NAME%.local}"
SYSTEM_NAME="${OS_NAME}${OS_VER}"

# 系统标识（用户定案：<设备名>-<系统>，如 particloud-macos / partiverse-kubuntu）：
# macOS→macOS、Windows→Windows、Linux→发行版 ID 首字母大写（发行版/桌面环境众多，需精准）
SYSTEM_TAG="$PLATFORM"
if [[ "$PLATFORM" == linux ]]; then
    SYSTEM_TAG=$(. /etc/os-release && echo "${ID}")
    SYSTEM_TAG="$(tr '[:lower:]' '[:upper:]' <<< "${SYSTEM_TAG:0:1}")${SYSTEM_TAG:1}"
elif [[ "$PLATFORM" == macos ]]; then
    SYSTEM_TAG="macOS"
elif [[ "$PLATFORM" == windows ]]; then
    SYSTEM_TAG="Windows"
fi

echo -e "${BLUE}[1/6]${NC} 检测平台: ${BOLD}$PLATFORM${NC} ($SYSTEM_NAME)"
echo -e "${BLUE}[2/6]${NC} 设备名:   ${BOLD}$DEVICE_NAME${NC}"

# ---------- 目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
LOG_DIR="$HOME/.local/share/partiverse-backup"
mkdir -p "$CONF_DIR" "$LOG_DIR"

echo -e "${BLUE}[3/6]${NC} 配置目录: $CONF_DIR"
echo -e "${BLUE}[4/6]${NC} 日志目录: $LOG_DIR"

# ---------- 凭证收集 ----------
echo ""
echo -e "${YELLOW}━━━ 凭证设置 ━━━${NC}"
echo "  备份加密密码用于加密本地仓库（不会上传明文）"
read -p "  输入备份加密密码 (Borg/restic): " -rs BORG_PASSPHRASE
echo ""
read -p "  确认密码: " -rs BORG_PASS2
echo ""
if [[ "$BORG_PASSPHRASE" != "$BORG_PASS2" ]]; then
    echo -e "${RED}密码不匹配，初始化退出${NC}"; exit 1
fi
[[ ${#BORG_PASSPHRASE} -lt 8 ]] && echo -e "${YELLOW}警告: 密码建议 ≥8 字符${NC}"

# ---------- 存储目标（rclone 统一管理） ----------
echo ""
echo -e "${YELLOW}━━━ 存储目标 ━━━${NC}"
echo "  备份目标由 rclone 统一管理（WebDAV/B2/S3/SFTP/NAS… 可随时 rclone config 增删）"

RCLONE_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"
mkdir -p "$RCLONE_CONF_DIR"

# rclone 二进制解析（与 backup.sh 的 $RCLONE 同名；此前 RCLONE_BIN 未赋值导致 remote 创建静默失败）
RCLONE="${RCLONE:-$(command -v rclone 2>/dev/null || true)}"
if [[ -z "$RCLONE" ]]; then
    error "未找到 rclone。安装后重跑：brew install rclone（或 apt install rclone）"
    info "若 WebDAV 凭证在旧机器的 rclone 配置里，也可直接迁移配置文件："
    info "  mkdir -p '$RCLONE_CONF_DIR' && scp 旧机:~/.config/rclone/rclone.conf '$RCLONE_CONF/'"
    exit 1
fi

TARGET_REMOTE=""
TARGET_SUBPATH=""
mapfile -t EXISTING_REMOTES < <("$RCLONE" listremotes 2>/dev/null | sed 's/:$//')

if [[ ${#EXISTING_REMOTES[@]} -gt 0 ]]; then
    echo "  检测到已有 rclone remote: ${EXISTING_REMOTES[*]}"
    read -p "  选择备份目标 remote（回车=新建 Universal Backups）: " TARGET_REMOTE
    TARGET_REMOTE="${TARGET_REMOTE%:}"
fi

if [[ -n "$TARGET_REMOTE" ]]; then
    if ! printf '%s\n' "${EXISTING_REMOTES[@]}" | grep -qxF -- "$TARGET_REMOTE"; then
        warn "remote '$TARGET_REMOTE' 不在已有列表中，将按其名引用（请确认已 rclone config 配置）"
    fi
else
    echo "  创建 rclone WebDAV remote: Universal Backups"
    read -p "  输入 WebDAV URL [https://webdav.123pan.cn/webdav]: " WEBDAV_URL
    WEBDAV_URL="${WEBDAV_URL:-https://webdav.123pan.cn/webdav}"
    read -p "  输入 WebDAV 用户名: " WEBDAV_USER
    read -p "  输入 WebDAV 密码: " -rs WEBDAV_PASS
    echo ""
    "$RCLONE" config create Universal\ Backups webdav \
        url "$WEBDAV_URL" \
        vendor other \
        user "$WEBDAV_USER" \
        pass "$WEBDAV_PASS" 2>&1 | grep -v "NOTICE" || true
    grep -q "^\[Universal Backups\]" "$RCLONE_CONF" 2>/dev/null \
        || warn "remote 'Universal Backups' 未创建成功——可重跑本向导，或从旧机器迁移 rclone.conf"
    TARGET_REMOTE="Universal Backups"
fi
read -p "  云端子路径（回车=remote 根，设备目录自动追加）: " TARGET_SUBPATH
TARGET_SUBPATH="${TARGET_SUBPATH#/}"   # 去首斜杠

# ---------- 档案路径配置 ----------
echo ""
echo -e "${YELLOW}━━━ 备份路径配置 ━━━${NC}"
echo "  config 档案 (敏感配置): ~/.config ~/.ssh ~/.gnupg ~/.local/share/Bitwarden 等"
echo "  files  档案 (用户数据): ~/Documents ~/Desktop ~/Pictures 等"
echo "  system 档案 (系统元数据): /etc + 系统清单"
echo ""

if [[ "$PLATFORM" == windows ]]; then
    BACKUP_BASE="${USERPROFILE}/PartiverseBackup"
    WIN_DOCS=$(cmd /c echo %USERPROFILE% 2>/dev/null | tr -d '\r')
    RESTIC_INCLUDES_CONFIG="${WIN_DOCS}/.ssh;${WIN_DOCS}/.gnupg;${WIN_DOCS}/AppData/Roaming/Bitwarden"
    RESTIC_INCLUDES_FILES="${WIN_DOCS}/Documents;${WIN_DOCS}/Desktop;${WIN_DOCS}/Pictures"
else
    # Linux / macOS
    if [[ "$PLATFORM" == linux ]]; then
        BACKUP_BASE="${BACKUP_BASE:-/backup-nvme1n1}"
    else
        BACKUP_BASE="${BACKUP_BASE:-$HOME/PartiverseBackup}"
    fi
    mkdir -p "$BACKUP_BASE"
fi
mkdir -p "$BACKUP_BASE"

# ---------- 生成 config.sh ----------
echo ""
echo -e "${YELLOW}━━━ 生成配置 ━━━${NC}"

# 设备 ID = <短名>-<系统标识>，统一小写
# 小写是硬性要求：实测 123Pan WebDAV 大小写不敏感（同名不同大小写会合并），
# 大写路径在不同厂商间行为不一致（S3 敏感 / WebDAV 多不敏感）——小写唯一安全。
# 品牌原名（macOS/Windows/发行版）只作展示，落在 timeline 设备目录的 profile.json
DEVICE_ID="$(tr '[:upper:]' '[:lower:]' <<< "${DEVICE_NAME}-${SYSTEM_TAG}")"
SYSTEM_ID="$DEVICE_ID"

# Windows restic 段引用 $USERNAME；非 Windows 平台无此变量（set -u 会炸），兜底
USERNAME="${USERNAME:-$DEVICE_NAME}"

# ---------- 档案路径（按平台生成，过滤不存在的路径） ----------
# includes/excludes 必须是 bash 索引数组（每路径/模式一个元素）——
# 旧版模板曾生成「空格拼接单字符串」，borg 与 preflight 都会把整串当成一个路径
mkdir -p "$LOG_DIR/system-meta"
gen_arr() {
    local p out=""
    for p in "$@"; do
        p="${p/#\~/$HOME}"
        [[ -e "$p" ]] && out+="\"$p\" "
    done
    echo "${out% }"
}
case "$PLATFORM" in
    macos)
        CFG_INC=$(gen_arr ~/.config ~/Library/Preferences ~/Library/Keychains ~/.ssh ~/.gnupg)
        FILES_INC=$(gen_arr ~/Documents ~/Desktop ~/Pictures ~/Movies ~/Music ~/Downloads)
        SYS_INC=$(gen_arr "$LOG_DIR/system-meta")
        ;;
    linux)
        CFG_INC=$(gen_arr ~/.config ~/.ssh ~/.gnupg ~/.local/share/Bitwarden \
                          ~/.local/share/kwalletd ~/.local/share/klipper ~/.local/share/konsole)
        FILES_INC=$(gen_arr ~/Documents ~/Desktop ~/Pictures)
        SYS_INC=$(gen_arr /etc "$LOG_DIR/system-meta")
        ;;
esac

# 设备档案（明文，无敏感）：品牌原名供人读，路径名保持小写
mkdir -p "$BACKUP_BASE/timeline/$DEVICE_ID"
cat > "$BACKUP_BASE/timeline/$DEVICE_ID/profile.json" <<PROF
{
  "device_id": "$DEVICE_ID",
  "display_name": "${DEVICE_NAME}-${SYSTEM_TAG}",
  "platform": "$PLATFORM",
  "os_name": "$OS_NAME",
  "os_version": "$OS_VER",
  "hostname": "$DEVICE_NAME",
  "created": "$(date -Iseconds)"
}
PROF

cat > "$CONF_DIR/config.sh" <<CONF
#!/usr/bin/env bash
# Partiverse Backup — 运行时配置（自动生成，勿手动修改）
# 生成时间: $(date -Iseconds)

# 平台
export PLATFORM="$PLATFORM"
export SYSTEM_ID="$SYSTEM_ID"
export DEVICE_ID="$DEVICE_ID"

# 路径
export BACKUP_BASE="$BACKUP_BASE"
export RCLONE="${RCLONE:-$(command -v rclone 2>/dev/null || echo "$HOME/bin/rclone-v1.75.1-linux-amd64/rclone")}"
export BORG="${BORG:-$(command -v borg 2>/dev/null || echo "$HOME/bin/borg")}"
export RESTIC="${RESTIC:-$(command -v restic 2>/dev/null || echo "$HOME/bin/restic")}"

# 存储目标（rclone 统一管理；可追加多个，格式 "remote:子路径"，设备目录自动追加）
export BACKUP_TARGETS=("$TARGET_REMOTE:${TARGET_SUBPATH}")

# 档案定义 (Linux/macOS — borg)：索引数组，每路径/模式一个元素
BORG_INCLUDES_config=($CFG_INC)
BORG_INCLUDES_files=($FILES_INC)
BORG_INCLUDES_system=($SYS_INC)
BORG_EXCLUDES_config=(
    --exclude "**/node_modules/" --exclude "**/__pycache__/" --exclude "**/.cache/"
    --exclude "**/*.log" --exclude "**/chromium/Cache/" --exclude "**/Code/Cache/"
)
BORG_EXCLUDES_files=(
    --exclude "**/node_modules/" --exclude "**/__pycache__/" --exclude "**/.cache/"
    --exclude "**/*.log" --exclude "**/.gradle/" --exclude "**/.cargo/"
)
BORG_EXCLUDES_system=(
    --exclude "**/node_modules/" --exclude "**/__pycache__/" --exclude "**/*.log"
)

# Windows (restic)
declare -A RESTIC_INCLUDES_config=(
    [config]="C:/Users/$USERNAME/.ssh;C:/Users/$USERNAME/.gnupg;C:/Users/$USERNAME/AppData/Roaming/Bitwarden"
)
declare -A RESTIC_INCLUDES_files=(
    [files]="C:/Users/$USERNAME/Documents;C:/Users/$USERNAME/Desktop;C:/Users/$USERNAME/Pictures"
)
declare -A RESTIC_EXCLUDES_config=(
    [config]="--exclude **/node_modules --exclude **/Cache"
)
declare -A RESTIC_EXCLUDES_files=(
    [files]="--exclude **/node_modules --exclude **/Cache --exclude **/Cache2"
)
CONF

# ---------- 生成 secrets.env ----------
echo "BORG_PASSPHRASE='$BORG_PASSPHRASE'" > "$CONF_DIR/secrets.env"
chmod 600 "$CONF_DIR/secrets.env"
echo "  凭证已保存: $CONF_DIR/secrets.env (600权限)"

# ---------- 调度 ----------
echo ""
echo -e "${YELLOW}━━━ 调度设置 ━━━${NC}"

SCHED_H="${SCHED_H:-02}"; SCHED_M="${SCHED_M:-34}"

# INIT_SKIP_SCHEDULER=1（E2E 用）：跳过调度注册，避免向真实 launchd/systemd/Task
# Scheduler 注册指向隔离环境的任务；后续备份/验收流程照常
if [[ "${INIT_SKIP_SCHEDULER:-0}" == "1" ]]; then
    info "（INIT_SKIP_SCHEDULER=1：跳过调度注册）"
elif [[ "$PLATFORM" == linux ]]; then
    echo "  创建 systemd user timer (每天 ${SCHED_H}:${SCHED_M})"
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/partiverse-backup.timer" <<TIMER
[Unit]
Description=Partiverse Backup (config/files/system, every 6h)

[Timer]
OnCalendar=*-*-* 00/6:${SCHED_M}:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
TIMER

    cat > "$HOME/.config/systemd/user/partiverse-backup.service" <<SVC
[Unit]
Description=Partiverse Backup System
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/backup.sh
EnvironmentFile=$CONF_DIR/secrets.env
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$HOME/.local/share $CONF_DIR $BACKUP_BASE
SVC

    systemctl --user daemon-reload
    systemctl --user enable --now partiverse-backup.timer
    success "  systemd timer 已启用并立即触发首次备份"

elif [[ "$PLATFORM" == macos ]]; then
    echo "  创建 macOS launchd agent (每天 ${SCHED_H}:${SCHED_M})"
    PLIST_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$PLIST_DIR"
    # backup.sh 需要 bash 5（nameref）；launchd 的 PATH 里是系统 bash 3.2，必须写死路径
    if [[ -x /opt/homebrew/bin/bash ]]; then LAUNCH_BASH=/opt/homebrew/bin/bash
    elif [[ -x /usr/local/bin/bash ]]; then LAUNCH_BASH=/usr/local/bin/bash
    else
        warn "未找到 bash 5（backup.sh 需要）——请先 brew install bash 再重跑本向导"
        LAUNCH_BASH="/bin/bash"
    fi
    cat > "$PLIST_DIR/com.partiverse.backup.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.partiverse.backup</string>
    <key>ProgramArguments</key>
    <array><string>$LAUNCH_BASH</string><string>$SCRIPT_DIR/backup.sh</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BORG_PASSPHRASE</key><string>$BORG_PASSPHRASE</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$SCHED_H</integer>
        <key>Minute</key><integer>$SCHED_M</integer>
    </dict>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
    launchctl load "$PLIST_DIR/com.partiverse.backup.plist" 2>/dev/null || true
    success "  launchd agent 已加载"

elif [[ "$PLATFORM" == windows ]]; then
    echo "  创建 Windows Task Scheduler 任务 (每天 ${SCHED_H}:${SCHED_M})"
    TASK_NAME="PartiverseBackup"
    SCHED_TIME="${SCHED_H}:${SCHED_M}"
    powershell -Command "
        \$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument \"-ExecutionPolicy Bypass -File $SCRIPT_DIR\\backup.ps1\"
        \$trigger = New-ScheduledTaskTrigger -Daily -At '${SCHED_TIME}'
        \$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName '$TASK_NAME' -Action \$action -Trigger \$trigger -Settings \$settings -Force 2>&1 | Out-Null
        Start-ScheduledTask -TaskName '$TASK_NAME' 2>&1 | Out-Null
    " 2>/dev/null || true
    success "  Task Scheduler 任务已创建"
fi

# ---------- 首次备份 ----------
echo ""
echo -e "${YELLOW}━━━ 首次备份 ━━━${NC}"
echo "  首次备份会创建仓库并上传，请保持网络连接..."
if "$SCRIPT_DIR/backup.sh"; then
    success "首次备份完成！"
else
    error "首次备份失败，请检查上方输出与 $LOG_DIR/backup.log；修复后手动重跑: $SCRIPT_DIR/backup.sh"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  初始化完成！${NC}"
echo "  配置: $CONF_DIR/config.sh"
echo "  日志: $LOG_DIR/backup.log"
echo "  仓库: $BACKUP_BASE/{borg-,restic-}{config,files,system}/"
echo ""
echo "  更新备份脚本: cd $SCRIPT_DIR && git pull"
echo "  手动触发备份: $SCRIPT_DIR/backup.sh"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
