#!/usr/bin/env bash
# 跨平台 mtime/尺寸探测单测（Linux 集成环境曾静默失效的教训）：
# GNU stat 的 -f 是「文件系统状态」而非格式串，非法指令只产垃圾不报错——
# BSD 写法 `stat -f '%m %N'` 在 Linux 上会把上一代 exclusions.json 的选取悄悄变成乱序。
# 本测试用「GNU 语义」的 stat shim 顶在 PATH 前面，强制暴露这类依赖；
# 语义层因此一律走 POSIX（date -r 取 epoch、wc -c 取字节数）。
# 用法: ./test_portable_stat.sh
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/bg-portstat.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---------- GNU 语义 stat shim ----------
# -c/--format：支持 %Y(epoch mtime) %s(size) %N(name)；-f：文件系统状态，未知指令→"?"
mkdir -p "$T/bin"
cat > "$T/bin/stat" <<'SHIM'
#!/usr/bin/env bash
fmt=""; mode="normal"; args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--format|-f)
            # GNU: -f 后跟文件系统格式串（%m 非法），-c 才是文件字段
            mode="$1"; fmt="$2"; shift 2 ;;
        -*) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
[[ ${#args[@]} -gt 0 ]] || exit 2
f="${args[0]}"
[[ -e "$f" ]] || { echo "stat: cannot stat '$f': No such file or directory" >&2; exit 1; }
if [[ "$mode" == "-f" ]]; then
    # 模拟 coreutils：文件系统字段表里没有 %m/%N/%z/%s → 未知转换打印 "?"
    out="$(sed -e 's/%m/?/g' -e 's/%N/?/g' -e 's/%z/?/g' -e 's/%s/?/g' <<< "$fmt")"
    echo "$out"
    exit 0
fi
# -c 文件字段用 POSIX 手段求值（date -r / wc -c），本 shim 因此在 GNU/BSD 两侧都可跑
epoch="$(date -r "$f" +%s)"
size="$(wc -c < "$f" | tr -d '[:space:]')"
out="$fmt"
out="${out//%Y/$epoch}"
out="${out//%s/$size}"
out="${out//%N/$f}"
echo "$out"
SHIM
chmod +x "$T/bin/stat"
export PATH="$T/bin:$PATH"
echo -n "0123456789" > "$T/sample.txt"
[[ "$("$T/bin/stat" -f '%m %N' "$T/sample.txt")" == "? ?" ]] || fail "shim 未按 GNU 语义产垃圾输出"

# ---------- stub 日志函数（semantic.sh 由 backup.sh source，依赖外部日志）----------
log(){ :; }; info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }
source "$V0_DIR/semantic/semantic.sh"

# ---------- 断言 1：helper 存在且在 GNU shim 下给出真实数值 ----------
declare -F file_mtime >/dev/null || fail "file_mtime 未定义（BSD stat 依赖未抽出）"
declare -F file_size  >/dev/null || fail "file_size 未定义"
want_epoch="$(date -r "$T/sample.txt" +%s)"
[[ "$(file_mtime "$T/sample.txt")" == "$want_epoch" ]] || \
    fail "file_mtime 在 GNU 语义下取错值: got $(file_mtime "$T/sample.txt") want $want_epoch"
[[ "$(file_size "$T/sample.txt")" == "10" ]] || \
    fail "file_size 在 GNU 语义下取错值: got $(file_size "$T/sample.txt")"

# ---------- 断言 2：latest_prev_exclusions 按 mtime 取最近一份 ----------
declare -F latest_prev_exclusions >/dev/null || fail "latest_prev_exclusions 未定义"
stage="$T/timeline/dev"
for d in 2026/09/10/0234-night 2026/09/20/0234-night; do
    mkdir -p "$stage/$d"
    echo '{"exclusions":[]}' > "$stage/$d/exclusions.json"
done
# 旧快照刻意「后创建 + 目录名排序在后」：find 顺序与时间顺序相反，
# 只有真按 mtime 排序才可能选对（GNU shim 下 mtime 若取垃圾必选错）；touch 走 PATH——/usr/bin/touch 是 macOS 专属
touch -t 202609100234 "$stage/2026/09/10/0234-night/exclusions.json"
touch -t 202609200234 "$stage/2026/09/20/0234-night/exclusions.json"
got="$(latest_prev_exclusions "$stage")"
[[ "$got" == "$stage/2026/09/20/0234-night/exclusions.json" ]] || \
    fail "latest_prev_exclusions 未取到最近快照: $got"

# ---------- 断言 3：语义层不再残留平台专有 stat 旗标 ----------
if grep -nE '\bstat -[cf]' "$V0_DIR/semantic/semantic.sh" >/dev/null; then
    grep -nE '\bstat -[cf]' "$V0_DIR/semantic/semantic.sh"
    fail "semantic.sh 仍有裸 stat -c/-f 调用（跨平台必炸其一）"
fi

echo "PASS: 跨平台 mtime/尺寸（GNU shim 下 file_mtime/file_size/prev-exclusions 选取均正确）"
