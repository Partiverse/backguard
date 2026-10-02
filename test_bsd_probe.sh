#!/usr/bin/env bash
# E2E：BSD/macOS 专属分支的**零备份轮**探针（CI 车道方案 A 的另一半）。
#
# 为什么要有这一份：免费 macOS runner 上一个整轮 `backup.sh` 要 6–13 分钟（同一份夹具本机 9 秒、
# linux 0.1–1 分钟）。docs/HANDOVER §11 的 10-02 午后块记着逐 step 墙钟：test_integrity 一个
# step 就有 6 个整轮，正好撞满 step 级 40 分钟超时（59e4c9d 那轮的 macos job 就是这么红的），
# 四套重夹具合计 ≈250 分钟 > job 预算 180。所以这四套退回 linux-only、macos 只留整轮型且
# 形状敏感的套件。
# 退掉的那四套里有一类问题是 linux 车道**永远看不见**的，而它们恰好都是纯函数：
# `sha256sum`/`shasum` 轮流域、`date -r` vs GNU `stat -c`、`rclone lsl` 行内含空格的路径切分、
# 明文产物的文件名脱敏、演练结论的 fail-closed 判定。这一份用 python3 把函数从生产文件里
# **切**出来 source，对着 python 自己算的真相断言——一轮备份都不跑，两条车道各几秒。
#
# 三条规矩：
# - 只切、不复制实现。抄一份进测试就变成「测我的副本」，生产改了测试还绿。切片靠
#   「顶层 `name() {` → 顶层 `}`」定位，切不到就当场 fail——**函数改名本身就是被测面**。
# - 期望值全部由 python3 现算（hashlib / os.stat / bytes 排序），不烤死常量。
# - 每条断言一个专属变异（tmp/bsd-mut.py）；`fail()` 走 **stderr**，因为切片那一段在
#   `{ … } > lib` 的重定向里，报错写进 stdout 就等于写进产物文件，屏幕上什么都看不到。
#
# 用法: ./test_bsd_probe.sh   （需 bash 4 + python3；不碰 borg/rclone/age/网络）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 python3，未测"; exit 0; }

T="$(mktemp -d /tmp/bg-bsdprobe.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1" >&2; exit 1; }

# ---------- 切片器 ----------
# $1=源文件 $2=顶层函数名；一行式 `name() { …; }` 也认
slice_fn() {
    python3 - "$1" "$2" <<'PY'
import re, sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path, encoding='utf-8').read().splitlines()
start_re = re.compile(r'^' + re.escape(name) + r'\(\)\s*\{')
first = None
i = None
for idx, ln in enumerate(lines):
    if start_re.match(ln):
        i = idx
        first = ln
        break
if first is None:
    sys.stderr.write(f"在 {path} 里找不到顶层函数 {name}()\n")
    sys.exit(3)
# 一行式定义（生产里 file_mtime / file_size 就是），行尾允许跟注释
if re.match(r'^\S+\(\)\s*\{.*\}\s*(#.*)?$', first):
    print(first)
    sys.exit(0)
out, depth = [], 0
for ln in lines[i:]:
    out.append(ln)
    depth += ln.count('{') - ln.count('}')
    if depth <= 0 and len(out) > 1:
        break
if out[-1].split('#')[0].strip() != '}':
    sys.stderr.write(f"{name}() 的切片没收在顶层 }} 上（深度={depth}）\n")
    sys.exit(3)
print("\n".join(out))
PY
}

# $1=源文件 $2=起始行正则 $3=结束行正则（顶层代码块，不是函数时用）
slice_block() {
    python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, s_re, e_re = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding='utf-8').read().splitlines()
body, started = [], False
for ln in lines:
    if not started and re.match(s_re, ln):
        started = True
    if started:
        body.append(ln)
        if re.match(e_re, ln) and len(body) > 1:
            break
if not started:
    sys.stderr.write(f"在 {path} 里找不到起始行 /{s_re}/\n")
    sys.exit(3)
print("\n".join(body))
PY
}

LIB="$T/probe_lib.sh"
{
    echo "# 由 test_bsd_probe.sh 从生产文件切出，勿手改"
    slice_block "$V0_DIR/backup.sh" '^SHA256_CMD=""$' '^fi$' \
        || fail "切片失败：backup.sh 里找不到 SHA256_CMD 探测块（改名/挪走了？）"
    for fn in sha256_stdin local_listing cloud_listing_from_lsl dir_sample; do
        slice_fn "$V0_DIR/backup.sh" "$fn" || fail "切片失败：backup.sh 里没有 ${fn}()"
    done
    for fn in file_mtime file_size file_sha256 drill_has_failure; do
        slice_fn "$V0_DIR/semantic/semantic.sh" "$fn" || fail "切片失败：semantic.sh 里没有 ${fn}()"
    done
} > "$LIB"
[[ -s "$LIB" ]] || fail "切片产物是空的（生产函数改名或搬家了？）"
n_fn="$(grep -cE '^(sha256_stdin|local_listing|cloud_listing_from_lsl|dir_sample|file_mtime|file_size|file_sha256|drill_has_failure)\(\)' "$LIB")"
[[ "$n_fn" == "8" ]] || fail "切进来的函数只有 $n_fn 个（应为 8 个：少一个就有一段被测面根本没进探针）"
# shellcheck source=/dev/null
source "$LIB"

# ---------- 夹具树：与生产同形（含空格名、中文目录、带文件名的演练结论）----------
R="$T/root"
mkdir -p "$R/Documents/私人 相册" "$R/Documents/work" "$R/AppData"
printf 'abc'                 > "$R/rootfile.txt"
printf 'note v1\n'           > "$R/Documents/note.txt"
head -c 4096 /dev/zero | tr '\0' 'x' > "$R/Documents/私人 相册/photo.jpg"
printf 'deep\n'              > "$R/Documents/work/deep1.txt"
printf 'cfg\n'               > "$R/AppData/settings.json"
printf '带完整文件名的演练结论\n' > "$R/rescue-test.txt"

py_sha() {   # $1=路径 → hashlib 现算
    python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
PY
}

# ---------- 1：内容哈希的轮流域（BSD 只有 shasum、GNU 只有 sha256sum）----------
# 为什么必须在**受限 PATH** 下再跑一遍：launchd 的 nightly 用的就是 `PATH=/usr/bin:/bin`
# （AGENTS §4 的实测口径），而开发机常常两个哈希命令都有（本机 `/sbin/sha256sum` 就在），
# 于是 `sha256sum → shasum` 这个轮流域的第二半在 ambient 环境下**永远走不到**——10-02 的
# 变异 b01 正是从这里溜过去的：把 shasum 那半摘掉，ambient 照样全绿。真机上如果哪天
# coreutils 不在了，A2a 的 config 内容对平与 A2b 的演练取证会一起哑掉。
h_want="$(python3 -c 'import hashlib;print(hashlib.sha256(b"abc").hexdigest())')"
RUNNER="$T/hash_runner.sh"
{
    printf '%s\n' '#!/usr/bin/env bash' "source '$LIB'" \
        'case "${1:-}" in' \
        '  stdin) printf abc | sha256_stdin ;;' \
        '  file)  file_sha256 "${2:-}" ;;' \
        '  path)  file_mtime "${2:-}" ;;' \
        'esac'
} > "$RUNNER"
chmod 755 "$RUNNER"
hash_at() {   # $1=PATH $2=模式 $3=参数
    env PATH="$1" /bin/bash "$RUNNER" "$2" "${3:-}" 2>/dev/null || true
}
LANE_PATHS=("/usr/bin:/bin" "$PATH")     # 受限（生产 nightly）+ 环境（开发机 / CI job）
for lp in "${LANE_PATHS[@]}"; do
    got="$(hash_at "$lp" stdin)"
    [[ "$got" == "$h_want" ]] || fail "PATH=${lp} 下 sha256_stdin 给的不是 hashlib 那份（实得「${got:-空}」）——这一侧的 sha256sum/shasum 轮流域断了"
done
[[ "$(printf 'abc' | sha256_stdin || true)" == "$h_want" ]] \
    || fail "ambient 下 sha256_stdin 连自己的环境都算不对：管道口径或 cut 字段切错了"

h2_want="$(py_sha "$R/Documents/私人 相册/photo.jpg")"
for lp in "${LANE_PATHS[@]}"; do
    got="$(hash_at "$lp" file "$R/Documents/私人 相册/photo.jpg")"
    [[ "$got" == "$h2_want" ]] \
        || fail "PATH=${lp} 下 file_sha256 对含空格路径算错（实得「${got:0:16}…」want=${h2_want:0:16}…）：引号或 \`< \"\$1\"\` 重定向被改坏"
done
# 算不出必须非零返回，不能退回空串：空串进了演练比对就是「两边都空＝一致」的假 PASS
rc=0; file_sha256 "$R/nope-missing" >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "文件不存在时 file_sha256 仍返回 0——空哈希会被下游当成「与清单一致」，把取回校验整段抹平"
rc=0; file_sha256 "$R/Documents" >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "目录操作数也被 file_sha256 接了（-f 守卫摘掉的样子）：同一条假 PASS 风险"

# ---------- 2：本地清单（红线 §1.1 的摘除 + 排序口径）----------
got_list="$(local_listing "$R")"
want_list="$(python3 - "$R" <<'PY'
import os, sys
root = sys.argv[1]
rows = []
for dirpath, _dirs, files in os.walk(root):
    for f in files:
        p = os.path.join(dirpath, f)
        rel = os.path.relpath(p, root).encode('utf-8', 'surrogateescape')
        if os.path.basename(rel) == b'rescue-test.txt':
            continue                      # 生产口径：它只留本地，不参与对平
        rows.append(rel + b"\t" + str(os.path.getsize(p)).encode())
rows.sort()                               # LC_ALL=C sort == 整行字节序
sys.stdout.buffer.write(b"".join(r + b"\n" for r in rows))
PY
)"
# 先问「红线有没有破」再问「整份清单等不等」：两者是同一种坏法的两种报法，顺序反了的话
# 摘掉 ! -name 这道守卫只会得到一句「不一致」，读的人看不出坏在脱敏还是坏在排序
if printf '%s\n' "$got_list" | grep -qF 'rescue-test.txt'; then
    fail "本地清单里出现了 rescue-test.txt——它天生带完整文件名，两端一比就把「云端少一份」报成假 FAIL（红线 §1.1 的对平侧）"
fi
[[ "$got_list" == "$want_list" ]] || fail "本地清单与 python3 现算的那份不一致：$(diff <(printf '%s\n' "$want_list") <(printf '%s\n' "$got_list") | head -6 | tr '\n' '|')（排序 / 尺寸，二者之一变了）"

# ---------- 3：`rclone lsl` 行解析（路径可含空格，前三个字段才是 size/日期/时间）----------
lsl_in='4096 2026-10-01 02:34:00.000000000 Documents/私人 相册/photo.jpg
5 2026-10-01 02:34:00.000000000 Documents/note.txt
7 2026-10-01 02:34:00.000000000 two words here.txt'
want_lsl='Documents/note.txt	5
Documents/私人 相册/photo.jpg	4096
two words here.txt	7'
got_lsl="$(printf '%s\n' "$lsl_in" | cloud_listing_from_lsl)"
[[ "$got_lsl" == "$want_lsl" ]] \
    || fail "云端清单解析把带空格的路径切断了（应保留整段路径 + size）：$(printf '%s\n' "$got_lsl" | head -3 | tr '\n' '|')"

# ---------- 4：差异样本只到目录（明文报告随时间轴上云，红线 §1.1）----------
sample="$(dir_sample "Documents/私人 相册/photo.jpg
Documents/work/deep1.txt
rootfile.txt
Zebra/not-in-the-first-three.txt")"
for leak in photo.jpg deep1.txt rootfile.txt settings.json not-in-the-first-three.txt; do
    if printf '%s\n' "$sample" | grep -qF "$leak"; then
        fail "dir_sample 泄了文件名 ${leak}（拿到目录就够了，这份报告要随时间轴上云）：${sample}"
    fi
done
printf '%s\n' "$sample" | grep -qF 'Documents/私人 相册' || fail "dir_sample 没给出缺失所在目录：${sample}"
printf '%s\n' "$sample" | grep -qF '（根级）' || fail "根级文件该归到「（根级）」而不是露出名字：${sample}"
if printf '%s\n' "$sample" | grep -qF 'Zebra'; then
    fail "dir_sample 没守住「只取前 3 条」：条数失控会把整份清单抄进上云报告（${sample}）"
fi
[[ "$(printf '%s\n' "$sample" | grep -c 'Documents/私人 相册' || true)" == "1" ]] \
    || fail "同一目录被重复列出（去重掉了？）：${sample}"

# ---------- 5：文件属性走 POSIX 口径（date -r / wc -c，不是 GNU stat）----------
want_mtime="$(python3 - "$R/Documents/note.txt" <<'PY'
import os, sys
print(int(os.stat(sys.argv[1]).st_mtime))
PY
)"
# 两个 30 天窗口（integrity_due / run_drill）的节流标记就是 file_mtime 的返回值，而读它的
# 正是 launchd 那个受限 PATH——所以这一条也要在 /usr/bin:/bin 下过一遍
for lp in "${LANE_PATHS[@]}"; do
    got="$(hash_at "$lp" path "$R/Documents/note.txt")"
    [[ "$got" == "$want_mtime" ]] \
        || fail "PATH=${lp} 下 file_mtime 与 os.stat 的 st_mtime 不等（实得「${got:-空}」want=${want_mtime}）：窗口要么永不重开要么每晚重开"
done
[[ "$(file_mtime "$R/Documents/note.txt")" == "$want_mtime" ]] \
    || fail "ambient 下 file_mtime 就与 os.stat 不等（got=$(file_mtime "$R/Documents/note.txt") want=${want_mtime}）"
[[ "$(file_size "$R/Documents/私人 相册/photo.jpg")" == "4096" ]] \
    || fail "file_size 对含空格路径读错了（实得 $(file_size "$R/Documents/私人 相册/photo.jpg")）"
[[ "$(file_mtime "$R/does-not-exist")" == "0" ]] \
    || fail "不存在的文件 file_mtime 应回 0（回空串会让上层 (( now - last )) 变成算术错误或「永远到期」）"

# ---------- 6：演练结论判定 fail-closed ----------
D="$T/drill"; mkdir -p "$D"
cat > "$D/pass.txt" <<'RT'
# 恢复演练 rescue-test — 2026-10-02T02:34:00+08:00
# 方式: 主身份解封 + 仓库实取 + 内容比对（备份期记下的源 sha256；没记的退回比大小，逐条标注依据）
PASS [files] Users/x/Documents/note.txt (8 B, 内容哈希一致)
RESULT: 1 PASS / 0 FAIL（抽样 1；内容哈希 1，仅比大小 0）
RT
# FAIL 行与计数不一致＝报告被截断 / 手工改过 / 上一轮残留。两处判定冗余是有意的
# （AGENTS §3「冗余实现」那条）：以逐条 FAIL 行为准，计数只当第二道
cat > "$D/torn.txt" <<'RT'
PASS [files] Users/x/Documents/note.txt (8 B, 内容哈希一致)
FAIL [config] Users/x/AppData/settings.json（内容哈希不符：清单 … ≠ 取回 …；大小倒是一致（4 B））
RESULT: 1 PASS / 0 FAIL（抽样 2；内容哈希 1，仅比大小 1）
RT
cat > "$D/count-fail.txt" <<'RT'
RESULT: 3 PASS / 2 FAIL（抽样 5；内容哈希 2，仅比大小 3）
RT
printf 'RESULT: FAIL（manifest 解封失败）\n' > "$D/headline.txt"
: > "$D/empty.txt"

rc=0; drill_has_failure "$D/pass.txt" || rc=$?
[[ $rc -eq 1 ]] || fail "全通过的演练被判成失败（rc=${rc}）——汇总行写作「0 FAIL」，字面 FAIL 就是它；判定必须只认逐条 FAIL 行 + 计数（10-01 每次真跑都假告警的那个 bug）"
for f in torn count-fail headline empty; do
    rc=0; drill_has_failure "$D/$f.txt" || rc=$?
    [[ $rc -eq 0 ]] || fail "${f} 这份演练结论该判失败却放行了（rc=${rc}）：逐条 FAIL 行 / 计数 / 结论行缺失都算失败，宁可误报不可漏报"
done

echo "BSD-PROBE-OK: 哈希轮流域 / 本地清单摘除与排序 / lsl 含空格路径 / 目录级脱敏 / date -r 口径 / 演练 fail-closed —— 零备份轮 6 组断言全绿"
