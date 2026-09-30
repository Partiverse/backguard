#!/usr/bin/env bash
# E2E：init.sh 全流程向导（隔离 HOME/CONF/rclone，local 后端不触网）。
# 验证：config.sh 生成的 includes/excludes 是多元素索引数组、首备跑通、
# timeline 语义层产物齐全、云端（local remote）收到备份。
# 用法: ./test_init_e2e.sh [v0 仓库根]（需 bash 5 与 borg/rclone，age 可选）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-init-e2e.XXXXXX)"
trap 'rm -rf "$T"' EXIT   # 失败路径也要清：夹具可能含 age 私钥/解密出的明文账本，不能留在 /tmp

# 隔离环境：HOME 下造「存在」的用户目录；local remote 名与真实向导可选形态一致
mkdir -p "$T/home/.config" "$T/home/.ssh" "$T/home/Documents" "$T/home/Desktop"
mkdir -p "$T/conf/partiverse-backup" "$T/home/.local/share/partiverse-backup/system-meta"
mkdir -p "$T/dest"
printf '[Backguard]\ntype = local\n' > "$T/rclone.conf"

# 向导交互输入：密码 / 确认 / 选择已有 remote "Backguard" / 子路径回车
# INIT_SCHED_NO_REGISTER=1：调度模板照常渲染落盘，但不注册进真实 launchd/systemd/Task
# Scheduler——渲染出来的文件正是下面断言 5 的被测对象
printf 'test-pass-123\ntest-pass-123\nBackguard\n\n' | (
    cd "$T/dest"
    HOME="$T/home" XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" \
    BACKUP_BASE="$T/repos" INIT_SCHED_NO_REGISTER=1 \
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

# 断言 5：调度模板渲染产物——明文口令必须只活在 secrets.env(600) 里。
# launchd 的 plist 落在 ~/Library/LaunchAgents 且没有 600 保护，一旦把口令写进去
# 就等于把凭据放进了无保护目录（真机 2026-10-01 已按此把旧 plist 的
# EnvironmentVariables 删除，backup.sh 自己 `set -a; source secrets.env`）
case "$(uname -s)" in
    Darwin)
        PL="$T/home/Library/LaunchAgents/com.partiverse.backup.plist"
        [ -f "$PL" ] || fail "plist 未生成（调度模板没渲染）"
        plutil -lint "$PL" > /dev/null || fail "plist 不是合法 plist"
        # 不写 StandardOut/ErrorPath 时 launchd 把 stdout 丢进 os_log，
        # 02:34 那次跑挂了基本读不到，只剩 launchctl print 的一个退出码
        grep -q "StandardOutPath" "$PL" || fail "plist 缺 StandardOutPath：夜间失败没有现场"
        grep -q "StandardErrorPath" "$PL" || fail "plist 缺 StandardErrorPath"
        SCHED_DIR="$T/home/Library/LaunchAgents"
        ;;
    Linux)
        SU="$T/home/.config/systemd/user/partiverse-backup.service"
        [ -f "$SU" ] || fail "systemd unit 未生成（调度模板没渲染）"
        grep -q "^EnvironmentFile=" "$SU" || fail "systemd unit 缺 EnvironmentFile"
        SCHED_DIR="$T/home/.config/systemd/user"
        ;;
esac

# 全隔离 HOME 扫口令探针：除 secrets.env 外任何文件出现即视为泄漏
hits=$(grep -rl --exclude=secrets.env "test-pass-123" "$T/home" "$T/conf" "$T/repos" "$T/dest" 2>/dev/null || true)
[ -z "$hits" ] || fail "明文口令泄漏到调度/日志产物: $(echo "$hits" | tr '\n' ' ')"
# 注意写法：`[ -n "$(...)" ] && fail` 在未命中时返回 1，set -e 会让脚本静默中止
if [ -n "$(grep -rl "PASSPHRASE" "$SCHED_DIR" 2>/dev/null || true)" ]; then
    fail "调度文件里出现 PASSPHRASE 字样"
fi
if [ -n "$(find "$T/conf/partiverse-backup/secrets.env" ! -perm 600)" ]; then
    fail "secrets.env 不是 600"
fi

echo "E2E-OK: init.sh 全流程（模板数组化 / 首备 / 语义层 / 云端同步 / 调度模板无明文口令）通过"
