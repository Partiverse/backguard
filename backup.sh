#!/usr/bin/env bash
#================================================================
# Partiverse Backup System — 跨平台统一备份脚本
# Linux / macOS (borg)  |  Windows (restic via rclone)
# 自动检测平台，加载对应配置，执行三档案备份并同步 WebDAV
# 用法: ./backup.sh [--verbose] [--init]
#================================================================
set -euo pipefail

# ---------- 平台检测 ----------
detect_platform() {
    case "$(uname -s)" in
        Linux*)     PLATFORM=linux;;
        Darwin*)    PLATFORM=macos;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM=windows;;
        *)          echo "FATAL: unknown platform $(uname -s)"; exit 1;;
    esac
}

# ---------- 彩色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

# ---------- 依赖检查 ----------
check_deps() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    error "缺少依赖: ${missing[*]}"
    info "运行 ./init.sh 或安装后重试"
    exit 1
}

# ---------- 密码读取（跨平台） ----------
read_secret() {
    # 用 `read -s` 最通用：Linux/macOS/Git Bash/MSYS2 均支持
    local var="$1"; local prompt="${2:-输入密码: }"
    printf "%s" "$prompt" >&2
    read -rs "$var" && echo "" >&2
    [[ -n "${!var}" ]]
}

# ---------- 凭证加载 ----------
load_secrets() {
    if [[ -f "$CONF_DIR/secrets.env" ]]; then
        set -a; source "$CONF_DIR/secrets.env"; set +a
    fi
    # Windows 用 %APPDATA%\PartiverseBackup\secrets.env
    if [[ "$PLATFORM" == windows && -f "$USERPROFILE/AppData/Roaming/PartiverseBackup/secrets.env" ]]; then
        local win_sec="$USERPROFILE/AppData/Roaming/PartiverseBackup/secrets.env"
        set -a; source "$win_sec" 2>/dev/null || true; set +a
    fi
}

# ---------- Borg 操作 (Linux / macOS) ----------
backup_borg_class() {
    local cls="$1"; local repo="$2"; local arc_name="$3"
    local -n inc_ref="BORG_INCLUDES_$cls"
    local -n exc_ref="BORG_EXCLUDES_$cls"

    info "[$cls] 归档: $arc_name"

    if [[ ! -d "$repo" ]]; then
        info "[$cls] 初始化仓库: $repo"
        BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" init --encryption=repokey "$repo" \
            2>&1 | tee -a "$LOG"
    fi

    set +e
    BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" create \
        --stats --compression lz4 \
        "${exc_ref[@]}" \
        "$repo::$arc_name" \
        "${inc_ref[@]}" \
        2>&1 | tee -a "$LOG"
    local create_rc=${PIPESTATUS[0]}
    set -e

    if [[ $create_rc -ne 0 && $create_rc -ne 1 ]]; then
        error "[$cls] borg create 失败 (exit $create_rc)"; return 1
    fi
    [[ $create_rc -eq 1 ]] && warn "[$cls] 部分路径不存在（已归档）"

    info "[$cls] 清理旧归档 (7d/4w/6m)..."
    BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" prune \
        --stats --keep-daily=7 --keep-weekly=4 --keep-monthly=6 \
        "$repo" 2>&1 | tee -a "$LOG"

    return 0
}

# ---------- Restic 操作 (Windows) ----------
backup_restic_class() {
    local cls="$1"; local repo_path="$2"; local arc_name="$3"
    local incl="${RESTIC_INCLUDES_$cls:-}"; local excl="${RESTIC_EXCLUDES_$cls:-}"

    info "[$cls] 归档: $arc_name"

    # repo 用 restic init（仅首次需要，已初始化则跳过）
    RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$repo_path" init 2>&1 | \
        grep -v "repository already exists" || true

    set +e
    RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" backup \
        --host "$DEVICE_ID" \
        ${excl} \
        ${incl} \
        2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -ne 0 ]]; then
        error "[$cls] restic backup 失败 (exit $rc)"; return 1
    fi

    info "[$cls] 清理旧归档..."
    RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" forget \
        --keep-daily=7 --keep-weekly=4 --keep-monthly=6 \
        -r "$repo_path" 2>&1 | tee -a "$LOG"

    return 0
}

# ---------- WebDAV 同步 ----------
sync_webdav() {
    local local_path="$1"; local remote_path="$2"
    info "同步 -> $remote_path"
    "$RCLONE" mkdir "$remote_path" 2>>"$LOG" || true
    set +e
    "$RCLONE" sync "$local_path/" "$remote_path/" \
        --bwlimit 10M --transfers 2 --checkers 4 \
        --log-file "$RCLONE_LOG" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    [[ $rc -eq 0 ]] && success "[WebDAV] 同步完成 -> $remote_path" \
        || warn "[WebDAV] 同步失败 (rc=$rc)"
}

# ---------- 系统元数据收集 (Linux/macOS) ----------
collect_system_meta() {
    mkdir -p "$META_DIR"
    {
        echo "# Partiverse Backup System Meta — $(date -Iseconds)"
        echo "=== os-release ==="; . /etc/os-release; echo "NAME=$NAME VERSION_ID=$VERSION_ID PRETTY_NAME=$PRETTY_NAME"
        echo "=== hostname ==="; hostname
        echo "=== kernel ==="; uname -r
        echo "=== dpkg packages ==="; command -v dpkg >/dev/null && dpkg --get-selections 2>/dev/null || echo "n/a"
        echo "=== flatpak ==="; command -v flatpak >/dev/null && flatpak list 2>/dev/null || echo "n/a"
        echo "=== snap ==="; command -v snap >/dev/null && snap list 2>/dev/null || echo "n/a"
        echo "=== mounts ==="; findmnt -rn -o SOURCE,TARGET,FSTYPE 2>/dev/null | grep -vE '^(sysfs|proc|devpts|tmpfs|cgroup|securityfs|pstore|bpf|debugfs|tracefs|fusectl|configfs|mqueue|hugetlbfs|efivarfs|none)' || echo "n/a"
        echo "=== block devices ==="; lsblk -f -o NAME,FSTYPE,SIZE,UUID,MOUNTPOINT 2>/dev/null || echo "n/a"
        echo "=== fstab ==="; cat /etc/fstab 2>/dev/null || echo "n/a"
        echo "=== crontab ==="; crontab -l 2>/dev/null || echo "(empty)"
    } > "$META_DIR/manifest.txt" 2>/dev/null || true
}

# ---------- 主流程 ----------
main() {
    detect_platform

    # 加载平台专属配置
    PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/platform"
    if [[ -f "$PLATFORM_DIR/$PLATFORM.sh" ]]; then
        source "$PLATFORM_DIR/$PLATFORM.sh"
    fi

    # 目录检测
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
    LOG_DIR="$HOME/.local/share/partiverse-backup"
    mkdir -p "$CONF_DIR" "$LOG_DIR"

    # 加载配置
    if [[ -f "$CONF_DIR/config.sh" ]]; then
        source "$CONF_DIR/config.sh"
    else
        error "配置文件不存在: $CONF_DIR/config.sh"
        info "运行 ./init.sh 进行初始化"
        exit 1
    fi

    LOG="$LOG_DIR/backup.log"
    RCLONE_LOG="$LOG_DIR/rclone.log"

    log "=== Backup STARTED ($PLATFORM) ==="
    log "Device: $DEVICE_ID | System: $SYSTEM_ID"

    # 凭证
    load_secrets
    if [[ -z "${BORG_PASSPHRASE:-}" && -z "${RESTIC_PASSWORD:-}" ]]; then
        error "未设置备份密码 (BORG_PASSPHRASE / RESTIC_PASSWORD)"
        info "运行 ./init.sh 或手动设置环境变量"
        exit 1
    fi

    # 依赖检查
    if [[ "$PLATFORM" == windows ]]; then
        check_deps "$RCLONE" "$RESTIC"
    else
        check_deps "$BORG" "$RCLONE"
        collect_system_meta
    fi

    # 磁盘空间检查
    avail_gb=$(df -BG "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "${avail_gb:-0}" -lt 5 ]]; then
        error "磁盘空间不足 (${avail_gb}GB < 5GB)，备份中止"
        exit 1
    fi

    local failed=0

    # ---------- 三档案备份 ----------
    for cls in config files system; do
        archive_name="${DEVICE_ID}-${cls}-$(date +%Y%m%d-%H%M%S)"

        if [[ "$PLATFORM" == windows ]]; then
            repo_path="$BACKUP_BASE/restic-$cls"
            backup_restic_class "$cls" "$repo_path" "$archive_name" || { ((failed++)); continue; }
            remote="WebDAV:${WEBDAV_ROOT}${SYSTEM_ID}/${cls}/"
            sync_webdav "$repo_path" "$remote"
        else
            repo="$BACKUP_BASE/borg-$cls"
            backup_borg_class "$cls" "$repo" "$archive_name" || { ((failed++)); continue; }
            remote="WebDAV:${WEBDAV_ROOT}${SYSTEM_ID}/${cls}/"
            sync_webdav "$repo" "$remote"
        fi
    done

    # ---------- 结果 ----------
    if [[ $failed -eq 0 ]]; then
        success "=== Backup FULLY COMPLETE ($(date '+%Y-%m-%d %H:%M:%S')) ==="
    else
        error "=== Backup FINISHED WITH ERRORS ($failed 个档案失败) ==="
        exit 1
    fi
}

main "$@"
