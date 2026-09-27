#!/usr/bin/env bash
# Partiverse Backup System — 恢复脚本 (Linux / macOS)
# 用法:
#   ./restore.sh --list                        # 列出所有归档
#   ./restore.sh --archive <class> --list     # 列出某档案的所有快照
#   ./restore.sh --archive <class> --latest --target <dir>  # 恢复最新快照
#   ./restore.sh --archive <class> --id <snapshot-id> --target <dir>

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
error()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[ OK ]${NC} $*"; }

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
[[ -f "$CONF_DIR/config.sh" ]] || error "配置文件不存在，请先运行 init.sh"
source "$CONF_DIR/config.sh"
source "$CONF_DIR/secrets.env" 2>/dev/null || error "secrets.env 未找到"

ARCHIVE="" TARGET="" SNAPSHOT_ID="--last 1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)  ARCHIVE="$2"; shift 2;;
        --target)   TARGET="$2"; shift 2;;
        --id)       SNAPSHOT_ID="$2"; shift 2;;
        --latest)   SNAPSHOT_ID="--last 1"; shift;;
        --list)     MODE=list; shift;;
        *)          error "未知参数: $1";;
    esac
done

[[ -z "${ARCHIVE:-}" ]] && error "用法: $0 --archive <class> [--latest|--id <id>] [--target <dir>]"
BACKUP_BASE="${BACKUP_BASE:-/backup-nvme1n1}"
REPO="$BACKUP_BASE/borg-$ARCHIVE"

[[ -d "$REPO" ]] || error "仓库不存在: $REPO"
[[ -z "$BORG_PASSPHRASE" ]] && error "BORG_PASSPHRASE 未设置"

list_snapshots() {
    info "[$ARCHIVE] 可用快照:"
    BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" list "$REPO" --short | \
        grep "^${DEVICE_ID}-${ARCHIVE}-" | sort -r
}

case "${MODE:-show}" in
    list)
        list_snapshots;;
    show)
        [[ -z "$TARGET" ]] && error "--target <目录> 必须指定"
        mkdir -p "$TARGET"
        info "[$ARCHIVE] 恢复到: $TARGET (快照: ${SNAPSHOT_ID#-- })"
        BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" extract \
            "$REPO::$SNAPSHOT_ID" \
            --target "$TARGET" 2>&1 | tee /dev/stderr
        success "已恢复到: $TARGET"
        success "注意: 恢复后请手动重启相关服务"
        ;;
esac
