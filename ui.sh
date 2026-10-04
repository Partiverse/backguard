#!/usr/bin/env bash
# A2 本地只读状态页启动器：读 config 拿 BACKUP_BASE，把路径交给 webui.py（stdlib，零依赖）。
# 用法: ./ui.sh [--port 8334]     停止: Ctrl-C / kill；只是个旁路读进程，杀掉不影响备份。
# 安全口径：页面渲染备份状态叙述，webui.py 拒绝非 127.0.0.1 绑定——不要想办法绕过它。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup}"
# config 是部署时的既知面（backup.sh 同一条读取路径）；webui 只取 BACKUP_BASE 一个值
# shellcheck source=/dev/null
[[ -f "$CONF_DIR/config.sh" ]] && source "$CONF_DIR/config.sh"
BACKUP_BASE="${BACKUP_BASE:-$HOME/PartiverseBackup}"
exec python3 "$SCRIPT_DIR/webui.py" --base "$BACKUP_BASE" "$@"
