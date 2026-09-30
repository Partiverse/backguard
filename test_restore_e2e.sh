#!/usr/bin/env bash
# E2E：restore.sh 真实取回文件（隔离 HOME/CONF/仓库，不碰真实配置、不触网）。
# 验证 README「恢复」一节的四条路径：
#   --list / --archive <cls> --list / --archive <cls> --latest --target / --id <归档名> --target
# 用法: ./test_restore_e2e.sh   （需 bash 5 与 borg）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-restore-e2e.XXXXXX)"
fail() { echo "E2E-FAIL: $1"; exit 1; }
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borgbackup"; exit 0; }

DEV=particloud-macos
CONF="$T/conf/partiverse-backup"
BASE="$T/repos"
REPO="$BASE/borg-config"
mkdir -p "$CONF" "$BASE" "$T/home" "$T/src/Documents"
export BORG_BASE_DIR="$T/.borg" BORG_PASSPHRASE='restore-e2e-pass'

# 两个归档：名字序即时间序（0930 晚于 0929），内容有意不同
borg init --encryption=repokey "$REPO" >/dev/null 2>&1 || fail "borg init 失败"
echo v1 > "$T/src/Documents/note.txt"
(cd "$T" && borg create "$REPO::$DEV-config-20260929-023400" src >/dev/null 2>&1) || fail "borg create 1 失败"
echo v2 > "$T/src/Documents/note.txt"
echo new > "$T/src/Documents/added.txt"
(cd "$T" && borg create "$REPO::$DEV-config-20260930-023400" src >/dev/null 2>&1) || fail "borg create 2 失败"

cat > "$CONF/config.sh" <<CFG
export PLATFORM=macos
export DEVICE_ID="$DEV"
export SYSTEM_ID="$DEV"
export BACKUP_BASE="$BASE"
export BORG="$(command -v borg)"
export RCLONE="$(command -v rclone || true)"
CFG
printf "BORG_PASSPHRASE='%s'\n" "$BORG_PASSPHRASE" > "$CONF/secrets.env"
chmod 600 "$CONF/secrets.env"

run_restore() { HOME="$T/home" XDG_CONFIG_HOME="$T/conf" bash "$V0_DIR/restore.sh" "$@"; }

# 断言 1：裸 --list（README 首条示例，不带 --archive）
out="$(run_restore --list 2>&1)" || fail "--list 退出非零：$out"
printf '%s' "$out" | grep -q -e "-20260930-023400" || fail "--list 未列出归档：$out"

# 断言 2：--archive config --list 两个归档都在
out="$(run_restore --archive config --list 2>&1)" || fail "--archive --list 失败：$out"
n="$(printf '%s\n' "$out" | grep -c "^$DEV-config-")"
[ "$n" = 2 ] || fail "--archive --list 应列 2 个归档，实际 $n"

# 断言 3：--latest 取回的是最新快照内容
run_restore --archive config --latest --target "$T/out-latest" >"$T/l.log" 2>&1 \
    || fail "--latest 恢复失败：$(tail -5 "$T/l.log")"
[ "$(cat "$T/out-latest/src/Documents/note.txt" 2>/dev/null)" = v2 ] || fail "--latest 未取到最新内容"
[ -f "$T/out-latest/src/Documents/added.txt" ] || fail "--latest 缺 added.txt"

# 断言 4：--id 精确取回历史快照（note 回到 v1，added 不存在）
run_restore --archive config --id "$DEV-config-20260929-023400" --target "$T/out-id" >"$T/i.log" 2>&1 \
    || fail "--id 恢复失败：$(tail -5 "$T/i.log")"
[ "$(cat "$T/out-id/src/Documents/note.txt" 2>/dev/null)" = v1 ] || fail "--id 未取到指定快照"
[ ! -e "$T/out-id/src/Documents/added.txt" ] || fail "--id 快照不应含 added.txt"

echo "E2E-OK: restore.sh 四条路径（--list / --archive --list / --latest / --id）均真实取回"
rm -rf "$T"
