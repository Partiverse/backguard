#!/usr/bin/env bash
#================================================================
# Partiverse Backup System — 跨平台统一备份脚本 v6
# Linux / macOS (borg)  |  Windows (restic via rclone)
# 用法: ./backup.sh
#================================================================
set -euo pipefail
# 出错时打印行号与命令；::error:: 会成为 CI 检查注解（匿名可查）
trap 'error "line ${LINENO}: ${BASH_COMMAND}"; echo "::error::backup.sh line ${LINENO}: ${BASH_COMMAND}"; [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "**ERR** line ${LINENO}: \`${BASH_COMMAND}\`" >> "$GITHUB_STEP_SUMMARY"' ERR

# ---------- 彩色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

# ---------- 平台检测 ----------
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Linux*)     PLATFORM=linux;;
    Darwin*)    PLATFORM=macos;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows;;
    *)          error "FATAL: unknown platform $PLATFORM"; exit 1;;
esac

# ---------- 目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
LOG_DIR="$HOME/.local/share/partiverse-backup"
mkdir -p "$CONF_DIR" "$LOG_DIR"

# ---------- 加载配置 ----------
if [[ -f "$CONF_DIR/config.sh" ]]; then
    source "$CONF_DIR/config.sh"
else
    error "配置文件不存在: $CONF_DIR/config.sh"
    info "运行 ./init.sh 或参考 platform/ 目录手动配置"
    exit 1
fi

# ---------- 凭证加载 ----------
load_secrets() {
    if [[ -f "$CONF_DIR/secrets.env" ]]; then
        set -a; source "$CONF_DIR/secrets.env"; set +a
    fi
}

# ---------- 依赖检查 ----------
check_deps() {
    local rc=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            local extra_bin=""
            for dir in "$HOME/bin" "$HOME/.local/bin" "$SCRIPT_DIR/bin"; do
                [[ -x "$dir/$cmd" ]] && { extra_bin="$dir/$cmd"; break; }
            done
            if [[ -n "$extra_bin" ]]; then
                info "  $cmd 在 $extra_bin"
            else
                error "缺少依赖: $cmd"
                rc=1
            fi
        fi
    done
    return $rc
}

# ---------- Borg 备份单档案 ----------
backup_borg_class() {
    local cls="$1"; local repo="$2"; local arc_name="$3"
    # nameref 引用 config.sh 中的索引数组 BORG_INCLUDES_$cls / BORG_EXCLUDES_$cls
    local -n inc_ref="BORG_INCLUDES_$cls"
    # shellcheck disable=SC2154  # exc_ref 经 eval 动态绑定
    eval "local -n exc_ref=\"BORG_EXCLUDES_$cls\""

    info "[$cls] 归档: $arc_name"

    if [[ ! -d "$repo" ]]; then
        info "[$cls] 初始化仓库: $repo"
        BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" init --encryption=repokey "$repo" 2>&1 | tee -a "$LOG"
    fi

    set +e
    # shellcheck disable=SC2154  # exc_ref 由上方 eval 动态绑定
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
}

# ---------- Restic 备份单档案 (Windows) ----------
backup_restic_class() {
    local cls="$1"; local repo_path="$2"; local arc_name="$3"
    local -n inc_ref="RESTIC_INCLUDES_$cls"
    # shellcheck disable=SC2154  # exc_ref 经 eval 动态绑定
    eval "local -n exc_ref=\"RESTIC_EXCLUDES_$cls\""

    info "[$cls] 归档: $arc_name"

    RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" -r "$repo_path" init 2>&1 | \
        grep -v "repository already exists" || true

    set +e
    # shellcheck disable=SC2154  # exc_ref 由上方 eval 动态绑定
    RESTIC_PASSWORD="$RESTIC_PASSWORD" "$RESTIC" backup \
        --host "$DEVICE_ID" \
        "${exc_ref[@]}" \
        "${inc_ref[@]}" \
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
}

# ---------- WebDAV 同步 ----------
# 用 copy 而非 sync：本地 prune 后旧归档不应从云端删除，云端保留全部历史
sync_webdav() {
    local local_path="$1"; local remote="$2"
    info "WebDAV -> $remote"
    "$RCLONE" mkdir "$remote" 2>>"$LOG" || true
    set +e
    "$RCLONE" copy "$local_path/" "$remote/" \
        --bwlimit 10M --transfers 2 --checkers 4 \
        --log-file "$RCLONE_LOG" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    [[ $rc -eq 0 ]] && success "[WebDAV] 同步完成" || warn "[WebDAV] 同步失败 (rc=$rc)"
}

# ---------- 系统元数据收集 ----------
collect_meta() {
    local meta_dir="$HOME/.local/share/partiverse-backup/system-meta"
    mkdir -p "$meta_dir"
    {
        echo "# Partiverse Backup System Meta — $(date -Iseconds)"
        echo "PLATFORM=$PLATFORM"
        echo "OS=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
        echo "HOSTNAME=$(hostname)"
        echo "KERNEL=$(uname -r)"
        "$BORG" --version 2>/dev/null | head -1
        "$RCLONE" --version 2>/dev/null | head -1
        [[ -n "${DOTFILES_REPO:-}" ]] && echo "DOTFILES_REPO=$DOTFILES_REPO"
        command -v dpkg >/dev/null && dpkg --get-selections 2>/dev/null | awk '$2=="install" {print $1}' > "$meta_dir/packages.txt"
        command -v flatpak >/dev/null && flatpak list 2>/dev/null | awk -F'\t' '{print $2}' > "$meta_dir/flatpak.txt"
        lsblk -f -o NAME,FSTYPE,SIZE,UUID,MOUNTPOINT > "$meta_dir/block-devices.txt" 2>/dev/null || true
        findmnt -rn -o SOURCE,TARGET,FSTYPE 2>/dev/null | grep -vE '^(sysfs|proc|devpts|tmpfs|cgroup|securityfs|pstore|bpf|debugfs|tracefs|fusectl|configfs|mqueue|hugetlbfs|efivarfs|none)' > "$meta_dir/mounts.txt" 2>/dev/null || true
        cat /etc/fstab > "$meta_dir/fstab.txt" 2>/dev/null || true
        command -v efibootmgr >/dev/null && efibootmgr -v > "$meta_dir/efiboot.txt" 2>/dev/null || true
        crontab -l > "$meta_dir/crontab.txt" 2>/dev/null || true
    } > "$meta_dir/manifest.txt" 2>&1 || true
    info "元数据已采集: $meta_dir/manifest.txt"
}

# ---------- 主流程 ----------
main() {
    LOG="${LOG:-$LOG_DIR/backup.log}"
    RCLONE_LOG="${RCLONE_LOG:-$LOG_DIR/rclone.log}"

    load_secrets

    if [[ -z "${BORG_PASSPHRASE:-}" && -z "${RESTIC_PASSWORD:-}" ]]; then
        error "未设置备份密码 (BORG_PASSPHRASE / RESTIC_PASSWORD)"
        info "运行 ./init.sh 或在 $CONF_DIR/secrets.env 中设置"
        exit 1
    fi

    if [[ "$PLATFORM" == windows ]]; then
        check_deps "$RCLONE" "$RESTIC" || exit 1
    else
        check_deps "$BORG" "$RCLONE" || exit 1
        collect_meta
    fi

    if [[ -d "$BACKUP_BASE" ]]; then
        local avail_gb
        # df -Pk 为 POSIX 写法，Linux/macOS/BSD 通用（-BG 是 GNU 专有，macOS 上报错）
        avail_gb=$(df -Pk "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
        if [[ "${avail_gb:-0}" -lt 5 ]]; then
            error "磁盘空间不足 (${avail_gb}GB < 5GB)，备份中止"
            exit 1
        fi
        info "磁盘剩余: ${avail_gb}GB"
    fi

    log "=== Backup STARTED ($PLATFORM) ==="
    log "Device: $DEVICE_ID | System: $SYSTEM_ID"

    local failed=0

    for cls in config files system; do
        local archive_name
        archive_name="${DEVICE_ID}-${cls}-$(date +%Y%m%d-%H%M%S)"
        local remote="${WEBDAV_REMOTE}:${WEBDAV_ROOT}${SYSTEM_ID}/${cls}/"

        if [[ "$PLATFORM" == windows ]]; then
            local repo_path="$BACKUP_BASE/restic-$cls"
            backup_restic_class "$cls" "$repo_path" "$archive_name" || { ((failed++)); continue; }
            [[ "${SKIP_WEBDAV:-0}" == "1" ]] || sync_webdav "$repo_path" "$remote"
        else
            local repo="$BACKUP_BASE/borg-$cls"
            backup_borg_class "$cls" "$repo" "$archive_name" || { ((failed++)); continue; }
            [[ "${SKIP_WEBDAV:-0}" == "1" ]] || sync_webdav "$repo" "$remote"
        fi
    done

    if [[ $failed -eq 0 ]]; then
        success "=== Backup FULLY COMPLETE ($(date '+%Y-%m-%d %H:%M:%S')) ==="
    else
        error "=== Backup FINISHED WITH ERRORS ($failed 个档案失败) ==="
        exit 1
    fi
}

main "$@"
