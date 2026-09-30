#!/usr/bin/env bash
# Partiverse Backup System — 恢复演练独立入口 (Linux / macOS)
# research/08 T3.4：run_drill 原本只挂在备份流程末尾（30 天节流），
# 人工「现在就要验一次恢复链路」没有入口。本脚本复用同一个 run_drill，
# 不复制其逻辑——两处判定不一致比没有入口更糟。
#
# 用法:
#   ./drill.sh                          # 本设备最新快照，节流仍生效
#   ./drill.sh --force                  # 人工演练：绕过 30 天节流
#   ./drill.sh --snapshot <快照目录>     # 指定快照（…/timeline/<dev>/YYYY/MM/DD/HHMM-标签）

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
error()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()   { echo -e "${RED}[WARN]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
[[ -f "$CONF_DIR/config.sh" ]] || error "配置文件不存在，请先运行 init.sh"
source "$CONF_DIR/config.sh"
source "$CONF_DIR/secrets.env" 2>/dev/null || error "secrets.env 未找到"

# run_drill 里的 borg extract 把 stderr 并进 ${LOG}；set -u 下未定义会直接 unbound
LOG="${DRILL_LOG:-$HOME/.local/share/partiverse-backup/drill.log}"
mkdir -p "$(dirname "$LOG")"
# secrets.env 里是无 export 的一行（init.sh 模板如此），backup.sh 靠自己的 export 补上；
# 独立入口必须同样 export，否则 run_drill 的 borg extract 拿不到口令
export BORG_PASSPHRASE="${BORG_PASSPHRASE:-}"

SNAP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)    export SEM_DRILL_FORCE=1; shift;;
        --snapshot) SNAP="${2:-}"; [[ -n "$SNAP" ]] || error "--snapshot 需要一个路径"; shift 2;;
        *)          error "未知参数: $1";;
    esac
done
export SEM_DRILL=1

source "$SCRIPT_DIR/semantic/semantic.sh"

[[ -n "${BORG:-}" ]] || error "config.sh 未设置 BORG"
[[ -n "${DEVICE_ID:-}" ]] || error "config.sh 未设置 DEVICE_ID"

# 快照目录名是 YYYY/MM/DD/HHMM-标签，字典序即时间序
if [[ -z "$SNAP" ]]; then
    # (; true) 中和 pipefail：设备还没有任何快照时，find 的 rc≠0 会炸掉整个赋值，
    # 用户看到的就是静默退出而不是「先跑一次备份」这句人话
    SNAP="$( (find "$BACKUP_BASE/timeline/$DEVICE_ID" -mindepth 4 -maxdepth 4 -type d 2>/dev/null \
              | sort | tail -1; true) )"
    [[ -n "$SNAP" ]] || error "无时间轴快照（$BACKUP_BASE/timeline/${DEVICE_ID}），先跑一次备份"
fi
[[ -d "$SNAP" ]] || error "快照目录不存在: $SNAP"

REPO="$BACKUP_BASE/borg-files"
[[ -d "$REPO" ]] || error "files 仓库不存在: $REPO"
# 设备名可含 [ ] + 等元字符（Linux hostname 允许）——归档选择必须字面量前缀匹配
ARC="$( (BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" list --short "$REPO" 2>>"$LOG" \
         | awk -v p="$DEVICE_ID-files-" 'index($0, p) == 1' | sort | tail -1; true) )"
[[ -n "$ARC" ]] || error "[$DEVICE_ID-files-*] 无归档可演练"

info "演练快照: $SNAP"
info "演练归档: $REPO::$ARC"

# run_drill 把结果写到设备目录（快照目录上 4 层：<dev>/YYYY/MM/DD/HHMM-标签）
rt="$(cd "$SNAP/../../../.." && pwd)/rescue-test.txt"
# mtime 必须在演练之前取：事后取会把「本轮没跑」判成「跑过」
rt_before="$(file_mtime "$rt")"

out="$(run_drill "$SNAP" "$REPO" "$ARC")"
printf '%s\n' "$out"
if [[ "$out" == *"[drill] 上次演练不足 30 天"* ]]; then
    info "本轮被 30 天节流跳过（未执行演练），要立刻验一次加 --force"
    exit 0
fi

# 判定「本轮真的跑过」只看结果文件是否被重写：陈旧文件会被误报成通过
[[ "$(file_mtime "$rt")" != "$rt_before" ]] \
    || error "本轮没有产出新的 rescue-test.txt（缺 age/主身份/密封清单？详见 ${LOG}）"
if drill_has_failure "$rt"; then
    error "恢复演练有失败项，详见 $rt"
fi
success "恢复演练通过，结果见 $rt"
