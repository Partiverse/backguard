#!/usr/bin/env bash
# E2E：init.sh 全流程向导（隔离 HOME/CONF/rclone，local 后端不触网）。
# 验证：config.sh 生成的 includes/excludes 是多元素索引数组、首备跑通、
# timeline 语义层产物齐全、云端（local remote）收到备份。
# 用法: ./test_init_e2e.sh [v0 仓库根]（需 bash 5 与 borg/rclone，age 可选）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-init-e2e.XXXXXX)"

# 隔离环境：HOME 下造「存在」的用户目录；local remote 名与真实向导可选形态一致
mkdir -p "$T/home/.config" "$T/home/.ssh" "$T/home/Documents" "$T/home/Desktop"
mkdir -p "$T/conf/partiverse-backup" "$T/home/.local/share/partiverse-backup/system-meta"
mkdir -p "$T/dest"
printf '[Backguard]\ntype = local\n' > "$T/rclone.conf"

# 向导交互输入：密码 / 确认 / 选择已有 remote "Backguard" / 子路径回车
printf 'test-pass-123\ntest-pass-123\nBackguard\n\n' | (
    cd "$T/dest"
    HOME="$T/home" XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" \
    BACKUP_BASE="$T/repos" INIT_SKIP_SCHEDULER=1 \
        bash "$V0_DIR/init.sh"
) > "$T/out.log" 2>&1 || { echo "E2E-FAIL: init.sh 退出非零"; tail -25 "$T/out.log"; exit 1; }

fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log"; exit 1; }

# 断言 1：config.sh 的 includes 是多元素索引数组（旧版 bug 是整串单元素）
CFG="$T/conf/partiverse-backup/config.sh"
# shellcheck source=/dev/null
source "$CFG"
n_config=${#BORG_INCLUDES_config[@]}
[ "$n_config" -ge 2 ] || fail "BORG_INCLUDES_config 仅 $n_config 个元素（应为多元素数组）"
[ "${BORG_EXCLUDES_config[0]}" = "--exclude" ] || fail "BORG_EXCLUDES_config 不是逐模式数组"
[ "${BORG_EXCLUDES_config[1]}" = "**/node_modules/" ] || fail "excludes 第二元素异常"

# 断言 2：备份目标解析正确（remote:子路径，设备段由 backup.sh 追加）
[ "${BACKUP_TARGETS[0]}" = "Backguard:" ] || \
    fail "BACKUP_TARGETS 生成错误: ${BACKUP_TARGETS[0]}"

# 断言 3：本地仓库与语义层四件套
for cls in config files system; do
    [ -d "$T/repos/borg-$cls" ] || fail "本地仓库 borg-$cls 未创建"
done
[ -n "$(find "$T/repos/timeline" -name STORY.md 2>/dev/null)" ] || fail "timeline 无 STORY.md"
[ -n "$(find "$T/repos/timeline" -name MANIFEST.txt 2>/dev/null)" ] || fail "timeline 无 MANIFEST.txt"

# 断言 4：云端收到备份与 timeline。local 后端忽略 remote 名（"Backguard:x" 即 "x"），
# 真实 WebDAV/S3 remote 才有 remote 层——断言按 local 语义写在 cwd（=向导执行时 cwd）下
DEV_ID="$DEVICE_ID"
for cls in config files system; do
    [ -d "$T/dest/$DEV_ID/$cls" ] || fail "云端未收到 $cls"
done
[ -d "$T/dest/$DEV_ID/timeline" ] || fail "云端未收到 timeline"

echo "E2E-OK: init.sh 全流程（模板数组化 / 首备 / 语义层 / 云端同步）通过"
rm -rf "$T"
