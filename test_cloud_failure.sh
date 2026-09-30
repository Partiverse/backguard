#!/usr/bin/env bash
# E2E：云端推送失败必须可见（S2「宣称 FULLY COMPLETE 但云端零副本」回归）。
# 两个 local 后端目标，其中一个目录只读 → rclone copy 必失败：
#   断言 backup.sh 退出非零 + 打出云端失败标记 + 不再打 FULLY COMPLETE；
#   本地仓库与另一个健康目标照常完成（备份本体不受影响，云端只增不减）；
#   配置 SEM_NTFY_URL 时经 curl 旁路推送告警（stub curl 记录调用）。
# 第二轮把只读目标改回可写：必须恢复 FULLY COMPLETE 且不再告警（证明不是常驻误报）。
# 用法: ./test_cloud_failure.sh [仓库根]
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ "$(id -u)" == 0 ]] && { echo "E2E-SKIP: root 下 chmod 只读不生效"; exit 0; }
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borg"; exit 0; }
command -v rclone >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 rclone"; exit 0; }

T="$(mktemp -d /tmp/bg-cloudfail.XXXXXX)"
trap 'chmod -R u+rwX "$T/dest" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log" 2>/dev/null || true; exit 1; }

mkdir -p "$T/src" "$T/conf/partiverse-backup" "$T/home" "$T/bin" "$T/dest"
echo hello > "$T/src/a.txt"
printf '[pftarget]\ntype = local\n' > "$T/rclone.conf"

# stub curl：记录 ntfy 推送调用（备份链路本身不用 curl）
: > "$T/curl.log"
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.log"
exit 0
CURL
chmod +x "$T/bin/curl"

cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Mac"
export SYSTEM_ID="E2E-Mac"
export BACKUP_BASE="$T/repos"
export RCLONE="$(command -v rclone)"
export BORG="$(command -v borg)"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=("pftarget:good-mac" "pftarget:ro-mac")
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src")
BORG_EXCLUDES_system=()
CONF
echo "BORG_PASSPHRASE='e2e-pass'" > "$T/conf/partiverse-backup/secrets.env"
chmod 600 "$T/conf/partiverse-backup/secrets.env"

# 只读目标：local 后端根 = cwd，先建好再封写权限
mkdir -p "$T/dest/ro-mac" && chmod 555 "$T/dest/ro-mac"

run_backup() {
    (
        cd "$T/dest"
        PATH="$T/bin:$PATH" FAKE_CURL=1 \
        SEM_NTFY_URL="http://127.0.0.1:1/e2e-topic" \
        SKIP_WEBDAV=0 XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" \
        HOME="$T/home" SEM_DRILL=0 \
            bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
    )
}

# ---------- 第 1 轮：ro-mac 必失败 ----------
# 失败时把现场打全：CI 上只报「无云端标记」无法区分「计数逻辑坏」与
# 「备份在推云之前就死了（rc≠0 是别的原因）」
dump_ctx() {
    echo "--- out.log 尾部 30 行 ---"
    tail -30 "$T/out.log" 2>/dev/null
    echo "--- rclone.log ---"
    find "$T" -maxdepth 4 -name 'rclone.log' 2>/dev/null | head -1 |
        { read -r rl && tail -15 "$rl"; } || echo "(无 rclone.log)"
    echo "--- 目标目录状态 ---"
    ls -ld "$T/dest/good-mac" "$T/dest/ro-mac" 2>/dev/null
}
rc=0; run_backup || rc=$?
[[ $rc -ne 0 ]] || fail "云端有目标失败却退出 0（旧行为：静默 FULLY COMPLETE）"
if ! grep -q "云端" "$T/out.log"; then
    dump_ctx
    fail "输出无云端失败标记（rc=${rc}；若上面显示备份更早失败，则是另一条路径的问题）"
fi
if grep -q "FULLY COMPLETE" "$T/out.log"; then fail "云端失败仍打 FULLY COMPLETE"; fi

# 备份本体与其他目标不受影响
[[ -d "$T/repos/borg-files" ]] || fail "本地仓库未建立"
[[ -d "$T/dest/good-mac/E2E-Mac/files" ]] || fail "健康目标未收到备份"
grep -q "同步完成" "$T/out.log" || fail "健康目标的成功日志缺失"

# 告警旁路：stub curl 应记录到含「云端」的推送
grep -q "云端" "$T/curl.log" || fail "云端失败未推送 ntfy 告警"

# ---------- 第 2 轮：解除只读 → 恢复正常，且不再告警 ----------
chmod -R u+rwX "$T/dest/ro-mac"
: > "$T/curl.log"
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 2 轮应成功，rc=$rc"
grep -q "FULLY COMPLETE" "$T/out.log" || fail "第 2 轮未打 FULLY COMPLETE"
if grep -q "云端" "$T/curl.log"; then fail "健康运行仍推送告警（常驻误报）"; fi
[[ -d "$T/dest/ro-mac/E2E-Mac/files" ]] || fail "补传后 ro-mac 仍无备份（云端只增不减应可重试）"

echo "E2E-OK: 云端失败可见（退出非零 + 明确标记 + ntfy 告警），恢复后无残留误报"
