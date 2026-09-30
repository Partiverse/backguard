#!/usr/bin/env bash
# 跨平台 mtime/尺寸探测单测（Linux 集成环境曾整条崩掉的教训）：
# GNU stat 的 -f 是「文件系统状态」而非格式串——coreutils 9.4 实测（ubuntu:24.04）：
# `stat -f '%m %N' f` 把格式串当文件系统名，报 cannot read file system information
# 并返回 rc=1，同时把真实文件的文件系统状态块打到 stdout。于是修复前的
# latest_prev_exclusions（裸 `stat -f` 流水线）在 Linux 上被 pipefail 直接带崩，
# 而 backup.sh 当时无兜底地调用 generate_semantic——非首备的 Linux 运行整条退出 1；
# 带 `|| …` 的调用点则把状态块并着 epoch 收进多行垃圾值。
# 本测试用「GNU 语义」的 stat shim 顶在 PATH 前面，强制暴露这类依赖；
# 语义层因此一律走 POSIX（date -r 取 epoch、wc -c 取字节数）。
# 用法: ./test_portable_stat.sh
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/bg-portstat.XXXXXX")"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---------- GNU 语义 stat shim ----------
# -c/--format：支持 %Y(epoch mtime) %s(size) %N(name)；-f：文件系统状态，rc=1 + 状态块
mkdir -p "$T/bin"
cat > "$T/bin/stat" <<'SHIM'
#!/usr/bin/env bash
fmt=""; mode="normal"; args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--format|-f)
            # GNU: -f 后跟的「格式串」其实是文件系统名参数，-c 才是文件字段
            mode="$1"; fmt="$2"; shift 2 ;;
        -*) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
[[ ${#args[@]} -gt 0 ]] || exit 2
f="${args[0]}"
[[ -e "$f" ]] || { echo "stat: cannot stat '$f': No such file or directory" >&2; exit 1; }
if [[ "$mode" == "-f" ]]; then
    # 复刻 coreutils：把 fmt 当文件系统名读不到 → stderr 报错 + rc=1，stdout 仍是文件系统块
    echo "stat: cannot read file system information for '$fmt': No such file or directory" >&2
    printf '  File: "%s"\n' "$f"
    printf '    ID: 4f4627a74c04bad5 Namelen: 255     Type: overlayfs\n'
    printf 'Block size: 4096       Fundamental block size: 4096\n'
    exit 1
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
# shim 自检：未按 GNU 语义失败 = 这个网兜不住回归
if "$T/bin/stat" -f '%m %N' "$T/sample.txt" >/dev/null 2>&1; then
    fail "shim 未按 GNU 语义报错（coreutils 的 stat -f 应 rc=1）"
fi

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

# ---------- 断言 4：变量展开不得紧贴非 ASCII 字符 ----------
# bash 在部分 locale 下把紧跟变量名的多字节首字节算进名字：`$LOG）` 查的是
# "LOG<byte>"，set -u 下直接 unbound 退出（macOS CI 曾在云端失败分支炸过）。
# LC_ALL=C 让字符类按字节判定，GNU/BSD grep 结果一致。
if hits="$(LC_ALL=C grep -rnE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' \
        "$V0_DIR"/*.sh "$V0_DIR"/semantic/*.sh 2>/dev/null |
        grep -v ':[0-9]*:[[:space:]]*#' || true)"; [[ -n "$hits" ]]; then
    echo "$hits"
    fail "变量后紧贴非 ASCII（需写成 \${VAR}），否则某些 locale 下变量名吃进字节"
fi

echo "PASS: 跨平台 mtime/尺寸（GNU shim 下 file_mtime/file_size/prev-exclusions 选取均正确）"
