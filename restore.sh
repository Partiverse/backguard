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

ARCHIVE="" TARGET="" SNAPSHOT="" WANT_LATEST=0 MODE="show"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)  ARCHIVE="$2"; shift 2;;
        --target)   TARGET="$2"; shift 2;;
        --id)       SNAPSHOT="$2"; shift 2;;
        --latest)   WANT_LATEST=1; shift;;
        --list)     MODE=list; shift;;
        *)          error "未知参数: $1";;
    esac
done

BACKUP_BASE="${BACKUP_BASE:-/backup-nvme1n1}"
[[ -n "${BORG_PASSPHRASE:-}" ]] || error "BORG_PASSPHRASE 未设置"

# 归档名后缀是本地时间戳 YYYYMMDD-HHMMSS，字典序即时间序
list_class() {  # $1=仓库路径 $2=档案类别
    [[ -d "$1" ]] || return 0
    # 设备名来自 hostname，允许 [ ] _ + 等字符——拼进 grep 模式会被当正则读，
    # 归档选取静默变空。awk index 做字面量前缀匹配。
    BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" list --short "$1" 2>/dev/null \
        | awk -v p="$DEVICE_ID-$2-" 'index($0, p) == 1' | sort
}

case "$MODE" in
    list)
        if [[ -n "$ARCHIVE" ]]; then
            REPO="$BACKUP_BASE/borg-$ARCHIVE"
            [[ -d "$REPO" ]] || error "仓库不存在: $REPO"
            info "[$ARCHIVE] 可用快照（新 → 旧）:"
            list_class "$REPO" "$ARCHIVE" | sort -r
        else
            for cls in config files system; do
                REPO="$BACKUP_BASE/borg-$cls"
                [[ -d "$REPO" ]] || continue
                info "[$cls] 可用快照（新 → 旧）:"
                list_class "$REPO" "$cls" | sort -r
            done
        fi
        ;;
    show)
        [[ -n "$ARCHIVE" ]] || error "用法: $0 --archive <class> [--latest|--id <归档名>] --target <目录>"
        [[ -z "$SNAPSHOT" || "$WANT_LATEST" -eq 0 ]] || error "--latest 与 --id 二选一"
        REPO="$BACKUP_BASE/borg-$ARCHIVE"
        [[ -d "$REPO" ]] || error "仓库不存在: $REPO"
        if [[ -n "$SNAPSHOT" ]]; then
            list_class "$REPO" "$ARCHIVE" | grep -qxF -- "$SNAPSHOT" \
                || error "归档不存在: $SNAPSHOT（$0 --archive $ARCHIVE --list 查看）"
        elif [[ "$WANT_LATEST" -eq 1 ]]; then
            SNAPSHOT="$(list_class "$REPO" "$ARCHIVE" | tail -1)"
            [[ -n "$SNAPSHOT" ]] || error "[$ARCHIVE] 无归档可恢复"
        else
            error "请指定 --latest 或 --id <归档名>（$0 --archive $ARCHIVE --list 查看）"
        fi
        [[ -n "$TARGET" ]] || error "--target <目录> 必须指定"
        mkdir -p "$TARGET"
        info "[$ARCHIVE] 恢复 $SNAPSHOT → $TARGET"
        # borg 1.4 无 --destination（restore.md 亦不写）：提取路径相对当前目录，
        # 因此必须 cd 进目标目录解包，否则会解到调用者所在目录
        if ! (cd "$TARGET" && BORG_PASSPHRASE="$BORG_PASSPHRASE" \
                "$BORG" extract "$REPO::$SNAPSHOT"); then
            error "borg extract 失败（归档: $SNAPSHOT）"
        fi
        success "已恢复到: $TARGET"
        info "注意: 归档内是剥掉前导 / 的绝对路径，文件位于 $TARGET/Users/<用户>/… 或 $TARGET/etc/… 下"
        info "恢复后请手动重启相关服务"
        ;;
esac
