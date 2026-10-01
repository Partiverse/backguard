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

# stub curl：记录推送调用，并**像真 ntfy 那样**把 JSON 回执打到 stdout 与 stderr——
# 回执里的 topic 就是要验的对象，生产代码一旦把回执落日志，下面的断言当场抓到
: > "$T/curl.log"
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.log"
printf '{"id":"e2eid","time":1,"expires":2,"event":"message","topic":"e2e-topic","title":"x"}\n'
printf 'curl: (22) e2e-topic rejected\n' >&2
# 注意转义：heredoc 没加引号，写成 ${CURL_STUB_RC:-0} 会在**生成桩的那一刻**展开成
# 常量 0，第 3 轮改环境变量就再也切不动退出码了（10-01 就这么假通过过一次）
exit \${CURL_STUB_RC:-0}
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
# 第 3 轮会覆写 out.log，健康那轮的「已推送」证据先存下来
cp "$T/out.log" "$T/out.round2.log"

# ---------- 第 3 轮：让推送本身失败（桩退出 22 = ntfy 返回 4xx） ----------
# 锁两件事：① curl -f 下 4xx 走「推送失败」分支而不是假装成功；
# ② 推送失败仍不得影响备份本体退出码（AGENTS §1.3 非致命分层），且失败也不许把
#    回执/错误串写进日志（桩在 stderr 里同样吐了 topic）
export CURL_STUB_RC=22
rc=0; run_backup || rc=$?
unset CURL_STUB_RC
[[ $rc -eq 0 ]] || fail "第 3 轮：ntfy 失败拖垮了备份退出码（rc=$rc，非致命分层破了）"
grep -q 'FULLY COMPLETE' "$T/out.log" || fail "第 3 轮：健康运行未打 FULLY COMPLETE"
grep -q '推送失败' "$T/out.log" || fail "第 3 轮：curl 退出 22 却没走推送失败分支（-f 口径没生效？）"

# ---------- 凭据纪律：ntfy 回执（含 topic）绝不落任何日志 ----------
# 真机 10-01 在 backup.log 里发现了整份回执 JSON，而 topic 就是订阅密码（AGENTS §1.2）。
# 桩把回执打进 stdout/stderr，生产代码若再 >>"$LOG" 就会把 e2e-topic 写进日志面。
# 三轮全扫（成功分支 + 失败分支都可能有回执），日志面 = 运行日志、配置目录、
# 明文时间轴、测试自己的 stdout 两份
# || true：find|head 在 head 提前收工时给 find 发 SIGPIPE，pipefail 下整条管道 rc=141，
# 赋值语句会被 set -e 直接炸掉（§2 的同一条陷阱）
BGLOG_DIR="$(find "$T/home" -type d -name partiverse-backup 2>/dev/null | head -1 || true)"
[ -n "$BGLOG_DIR" ] || fail "找不到日志目录，下面的断言会假绿"
hits="$(grep -rlF 'e2e-topic' "$BGLOG_DIR" "$T/conf" "$T/repos/timeline" \
        "$T/out.log" "$T/out.round2.log" 2>/dev/null || true)"
if [ -n "$hits" ]; then
    echo "命中文件: $hits"
    printf '%s\n' "$hits" | while IFS= read -r hf; do
        grep -nF 'e2e-topic' "$hf" | sed 's/^/  /' | head -3
    done
    fail "ntfy 回执里的 topic 落进了日志（凭据纪律 §1.2）"
fi
# 反向确认不是空转：桩确实被调用且确实吐出过 topic（curl.log 是测试自己的调用记录，不算日志面）
grep -qF 'e2e-topic' "$T/curl.log" || fail "桩没被调用，topic 断言等于没测"
# 推送的成功与失败分支各自真的走到（第 2 轮桩退出 0 → 「已推送」；第 3 轮 → 「推送失败」）
grep -q '已推送' "$T/out.round2.log" || fail "第 2 轮没走推送成功分支（curl 判定口径变了？）"

echo "E2E-OK: 云端失败可见（退出非零 + 明确标记 + ntfy 告警），恢复后无残留误报；ntfy 回执（含 topic）不落日志"
