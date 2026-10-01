#!/usr/bin/env bash
# E2E：引擎仓库的存储完整性月度校验（research/11 A2a）。
# 要补的空位是：在这之前，「备份还能取回」的证据只有恢复演练（取回路径），而**存储本身
# 腐化**只有把整仓读一遍才暴露——`borg create` 对已损坏的仓库照样退出 0（10-01 实测），
# 也就是说现有全部守卫都看不见这类问题。
# 断言面：
#   1) 首轮：INTEGRITY.txt 落在时间轴根、三类仓库**各自都被校验**（checks=3）、全 PASS、
#      退出 0；报告里不得出现仓库/源码树绝对路径或任何文件名（它随下轮时间轴上云，红线 §1.1）；
#   2) 窗口：紧接着的第二轮不重跑（产物 mtime 未变 + 明说跳过）——低频路径的节流本身要被测，
#      否则「月度」只是文档里的形容词；
#   3) INTEGRITY_VERIFY=0 整段关掉；
#   4) 拿不到锁（并发的手工演练）记 UNKNOWN 且**不改退出码**：flake 报成 FAIL 会烧掉告警通道；
#   5) 非锁类的 rc>=2（borg 把「仓库可能已毁」和用法错误放在同一档）按最坏情况判 FAIL；
#   6) 真损坏：翻掉一个 chunk 的字节 → 只有这一类判 FAIL（另两类仍 PASS）、退出非零、
#      告警可见、且**不再宣布 FULLY COMPLETE**。
# 用法: ./test_integrity.sh   （需要 borg；夹具全在 mktemp 里，不触真实配置）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borg，未测"; exit 0; }

T="$(mktemp -d /tmp/bg-integrity.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log" 2>/dev/null || true; exit 1; }

mkdir -p "$T/src/文档" "$T/conf/partiverse-backup" "$T/home" "$T/bin"
# 桩 curl：告警是否真的发出去了，只有拦下推送调用才算测到（info/warn 那行只证明 stdout）
: > "$T/curl.log"
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.log"
exit 0
CURL
chmod 755 "$T/bin/curl"
# 隐私靶子：报告是明文产物且随时间轴上云，红线 §1.1 的例外只有 rescue-test.txt
echo hello > "$T/src/文档/秘密-王峭楠-简历.txt"
head -c 30000 /dev/urandom > "$T/src/文档/账本.csv"

cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Mac"
export SYSTEM_ID="E2E-Mac"
export BACKUP_BASE="$T/repos"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=()
export BORG="$(command -v borg)"
# SKIP_WEBDAV=1 下 rclone 根本不会被调用，但 check_deps 要它在位——没有就指个 /usr/bin/true
export RCLONE="$(command -v rclone || echo /usr/bin/true)"
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src")
BORG_EXCLUDES_system=()
CONF
echo "BORG_PASSPHRASE='e2e-pass'" > "$T/conf/partiverse-backup/secrets.env"
chmod 600 "$T/conf/partiverse-backup/secrets.env"

REPORT="$T/repos/timeline/INTEGRITY.txt"
REPO_FILES="$T/repos/borg-files"

run_backup() { (
    cd "$T/home"
    # shellcheck disable=SC2086  # 分词是有意的：把 $1 当多个 KEY=VAL 传进 env
    env SKIP_WEBDAV=1 SEM_DRILL=0 XDG_CONFIG_HOME="$T/conf" HOME="$T/home" \
        PATH="$T/bin:$PATH" SEM_NTFY_URL="http://127.0.0.1:1/e2e-topic" \
        ${1:-} bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
); }

# 报告行形状 `STATUS 名称(补 14 列) 详情`，名称含冒号不含空格
status_of() { { grep -E "^[A-Z]+ +$1 " "$REPORT" 2>/dev/null || true; } | awk '{print $1; exit}'; }
summary_field() { grep -o "$1=[0-9]*" "$REPORT" | head -1 | cut -d= -f2; }
hash_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi
}

# ---------- 1：首轮全绿 + 三类仓库都登记到了 ----------
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "首轮存储完整性该通过，退出却非零（rc=${rc}）：$(tail -8 "$T/out.log")"
[[ -f "$REPORT" ]] || fail "INTEGRITY.txt 没落在时间轴根（${REPORT}）：$(grep -i integrity "$T/out.log" || true)"
[[ "$(summary_field checks)" == "3" ]] \
    || fail "三类仓库没有各自被校验（汇总 checks=$(summary_field checks)，应为 3）：$(grep -v '^#' "$REPORT")"
for cls in config files system; do
    [[ "$(status_of "borg:$cls")" == "PASS" ]] \
        || fail "健康仓库 borg:$cls 没记 PASS（实际：$(status_of "borg:$cls")）：$(grep "borg:$cls" "$REPORT")"
done
# 明文报告的隐私面：仓库绝对路径、源码树路径、任何被备份的文件名都不许出现
for forbidden in "$T/repos" "$T/src" "秘密-王峭楠-简历.txt" "账本.csv"; do
    if grep -qF "$forbidden" "$REPORT"; then
        fail "报告里出现了「${forbidden}」——它随下轮时间轴推上网盘，红线 §1.1：$(grep -F "$forbidden" "$REPORT")"
    fi
done
# 健康轮不该因为「这一步跑了」就发告警（月度低频路径一旦常驻误报，观察期就没人信告警了）
if grep -q '存储完整性' "$T/curl.log"; then
    fail "存储完整性全部 PASS 的一轮仍然推送了告警（常驻误报）：$(cat "$T/curl.log")"
fi

# ---------- 2：窗口没到就不重跑（「月度」得是被测出来的，不是文档里的形容词）----------
before="$(hash_of "$REPORT")"
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第二轮该照常通过：$(tail -8 "$T/out.log")"
grep -q '未到校验窗口' "$T/out.log" \
    || fail "第二轮没有明说「未到校验窗口」——跳过无声就等于哪天窗口失效也没人知道：$(grep -i integrity "$T/out.log")"
[[ "$(hash_of "$REPORT")" == "$before" ]] \
    || fail "窗口没到却重跑了（报告内容变了）：$(grep -v '^#' "$REPORT")"

# ---------- 3：整段关掉 ----------
rc=0; run_backup "INTEGRITY_VERIFY=0" || rc=$?
[[ $rc -eq 0 ]] || fail "INTEGRITY_VERIFY=0 时不该有任何失败：$(tail -8 "$T/out.log")"
[[ "$(status_of "borg:files")" == "PASS" ]] \
    || fail "INTEGRITY_VERIFY=0 把报告改写/清空了（原 PASS 行不在了）：$(grep -v '^#' "$REPORT")"

# ---------- 4：拿不到锁 = flake，记 UNKNOWN 且不改退出码 ----------
# 桩只在**被校验的那一刻**让另一个进程持锁：夹具没法从外面卡这个时间点，因为备份本体
# 也在跑 borg，早一步持锁会把本轮的 create 一起锁住（那就不再是「校验读不出」而是整轮失败）
mkdir -p "$T/bin"
cat > "$T/bin/borg-selflock" <<'STUB'
#!/usr/bin/env bash
# 只动 check；其余子命令原样转发（引擎本体还得真跑）
if [[ "${IT_SELFLOCK:-0}" == "1" && "${1:-}" == "check" ]]; then
    repo="${!#}"
    # 只锁其中一个仓库：三个都锁就测不出「逐仓库判定不是全局开关」
    if [[ -n "${IT_LOCK_ONLY:-}" && "$repo" != *"-$IT_LOCK_ONLY" ]]; then
        exec "$BORG_REAL" "$@"
    fi
    "$BORG_REAL" with-lock "$repo" bash -c 'sleep 8' >/dev/null 2>&1 &
    holder=$!
    sleep 1
    rc=0
    BORG_LOCK_WAIT=0 "$BORG_REAL" "$@" >"$T_STUB_OUT" 2>&1 || rc=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    cat "$T_STUB_OUT"
    exit "$rc"
fi
exec "$BORG_REAL" "$@"
STUB
chmod 755 "$T/bin/borg-selflock"
sed -e "s#^export BORG=.*#export BORG=\"$T/bin/borg-selflock\"#" \
    "$T/conf/partiverse-backup/config.sh" > "$T/conf/config.tmp" \
    && mv "$T/conf/config.tmp" "$T/conf/partiverse-backup/config.sh"

rc=0
run_backup "INTEGRITY_DAYS=0 IT_SELFLOCK=1 IT_LOCK_ONLY=config BORG_REAL=$(command -v borg) T_STUB_OUT=$T/stub.out" || rc=$?
# 先问「哪条检查抓到的」，再问退出码：顺序反了就只能看到「这一轮红了」，看不到它为什么红
[[ "$(status_of "borg:config")" == "UNKNOWN" ]] \
    || fail "拿不到锁该记 UNKNOWN（实际：$(status_of "borg:config")）：$(grep 'borg:config' "$REPORT")"
[[ "$(status_of "borg:files")" == "PASS" ]] \
    || fail "只有一个仓库被锁住，另一些读得出的却没能记 PASS（实际：$(status_of "borg:files")）——逐仓库判定不是全局开关：$(grep 'borg:files' "$REPORT")"
grep -q '锁' "$REPORT" \
    || fail "UNKNOWN 的理由没写明是拿不到锁——光一个状态码不足以让人判断该不该管：$(grep 'borg:config' "$REPORT")"
[[ "$(summary_field FAIL)" == "0" ]] \
    || fail "拿不到锁被判成了 FAIL（汇总 FAIL=$(summary_field FAIL)）：$(grep -v '^#' "$REPORT")"
[[ $rc -eq 0 ]] || fail "一项 UNKNOWN 却改了退出码（rc=${rc}）：把 flake 报成失败会烧掉告警通道：$(tail -8 "$T/out.log")"

# ---------- 5：非锁类的 rc>=2 按最坏情况判 FAIL ----------
# borg 自己把「仓库可能已毁」和用法错误塞在同一个 rc=2 档，所以这一档只能靠错误文本分流；
# 错误文本里没有锁就该红——宁可误报也不能把毁掉的仓库报成「没证成也没证败」
cat > "$T/bin/borg-fatal" <<'STUB'
#!/usr/bin/env bash
if [[ "${IT_FATAL_CHECK:-0}" == "1" && "${1:-}" == "check" ]]; then
    echo "borg check: error: repository index not found" >&2
    exit 2
fi
exec "$BORG_REAL" "$@"
STUB
chmod 755 "$T/bin/borg-fatal"
sed -e "s#^export BORG=.*#export BORG=\"$T/bin/borg-fatal\"#" \
    "$T/conf/partiverse-backup/config.sh" > "$T/conf/config.tmp" \
    && mv "$T/conf/config.tmp" "$T/conf/partiverse-backup/config.sh"

rc=0
run_backup "INTEGRITY_DAYS=0 IT_FATAL_CHECK=1 BORG_REAL=$(command -v borg)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "引擎报 fatal（非锁类）却仍算通过：$(tail -8 "$T/out.log")"
for cls in config files system; do
    [[ "$(status_of "borg:$cls")" == "FAIL" ]] \
        || fail "非锁类的 rc=2 没把 borg:$cls 判成 FAIL（实际：$(status_of "borg:$cls")）：$(grep "borg:$cls" "$REPORT")"
done
[[ "$(summary_field FAIL)" == "3" ]] \
    || fail "三类仓库该各记一条 FAIL（汇总 FAIL=$(summary_field FAIL)）：$(grep -v '^#' "$REPORT")"

# ---------- 6：真损坏——只有那一类判 FAIL，且不再宣布 FULLY COMPLETE ----------
sed -e "s#^export BORG=.*#export BORG=\"$(command -v borg)\"#" \
    "$T/conf/partiverse-backup/config.sh" > "$T/conf/config.tmp" \
    && mv "$T/conf/config.tmp" "$T/conf/partiverse-backup/config.sh"
# 损坏面选 files 仓库的一个数据段：10-01 实测这种损坏**不会**让本轮 borg create 失败，
# 所以「备份全绿 + 存着的数据已坏」是能同时成立的——这正是这一步要抓的状态
victim="$(find "$REPO_FILES/data" -type f | LC_ALL=C sort | head -1)"
[[ -n "$victim" ]] || fail "夹具：borg-files 仓库里没有数据段可以损坏"
python3 - "$victim" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
b[len(b) // 2] ^= 0xFF
open(p, 'wb').write(bytes(b))
print("flipped 1 byte in", p)
PY
rc=0
run_backup "INTEGRITY_DAYS=0" || rc=$?
[[ "$(status_of "borg:files")" == "FAIL" ]] \
    || fail "损坏的 borg-files 没判 FAIL（实际：$(status_of "borg:files")）：$(grep 'borg:files' "$REPORT")"
[[ "$(status_of "borg:config")" == "PASS" ]] \
    || fail "损坏只发生在 files，config 却被牵连判红（实际：$(status_of "borg:config")）——逐仓库判定不是全局开关：$(grep 'borg:config' "$REPORT")"
[[ "$rc" -ne 0 ]] || fail "存储完整性校验失败，退出码却仍是 0：$(tail -8 "$T/out.log")"
[[ "$(summary_field FAIL)" == "1" ]] \
    || fail "该只有 1 项 FAIL（汇总 FAIL=$(summary_field FAIL)）：$(grep -v '^#' "$REPORT")"
grep -qE 'FULLY COMPLETE' "$T/out.log" \
    && fail "坏数据被发现后仍宣布 FULLY COMPLETE：$(grep 'FULLY' "$T/out.log")"
# 断言「告警真的运作过」要取 out.log：info/warn 只写 stdout，backup.log 里没有它们（AGENTS §2）
grep -q '存储完整性校验' "$T/out.log" \
    || fail "失败没在 stdout 留下「存储完整性校验」这行——launchd/CI 只看得到退出码：$(tail -8 "$T/out.log")"
# 第二证人：真发过一次 ntfy 告警（桩按参数记账，只测 stdout 那行等于没测旁路）
grep -q '存储完整性' "$T/curl.log" \
    || fail "存储完整性失败没有推出 ntfy 告警——设备在夜里坏掉时没人知道：$(cat "$T/curl.log")"
if grep -qF '秘密-王峭楠-简历.txt' "$T/curl.log"; then
    fail "完整性失败的告警把被备份的文件名带进了推送（红线 §1.1）"
fi

echo "E2E-OK: 存储完整性校验（首轮点名三类 / 窗口节流 / 可关闭 / 锁 flake 记 UNKNOWN 不改退出码 / 非锁 fatal 判 FAIL / 真损坏逐仓库判红并拒绝 FULLY COMPLETE）"
