#!/usr/bin/env bash
# prune_local_timeline / prune_run_jsons 单测（隔离临时目录，不触网不碰真实配置）：
#   默认 14 / 显式 N / 设备级文件不动 / 空日期目录收掉 / <=0 与非数字行为
#   run JSON 留档轮转：白名单守卫只放行 run-YYYYMMDD-HHMMSS.json，含空格/分号的名字不误删
set -euo pipefail
cd "$(dirname "$0")"

# semantic.sh 由 backup.sh source 而来，日志函数是外部依赖——stub 掉
log(){ :; }; info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }
source semantic/semantic.sh

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bg-retention.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
dev="$tmp/particloud-macos"

snap_count() { find "$dev" -mindepth 4 -maxdepth 4 -type d | wc -l | tr -d ' '; }
fail() { echo "FAIL: $1"; exit 1; }

# 12 份快照（DD 补零，路径排序即时间序）+ 设备级文件
mkdir -p "$dev"
for d in 01 02 03 04 05 06 07 08 09 10 11 12; do
    mkdir -p "$dev/2026/09/$d/1200-morning"
    echo x > "$dev/2026/09/$d/1200-morning/STORY.md"
done
echo p > "$dev/profile.json"
echo r > "$dev/rescue-test.txt"

# 1) 默认 14 > 现有 12 → 全留
SEM_TIMELINE_KEEP=14 prune_local_timeline "$dev"
[[ "$(snap_count)" == 12 ]] || fail "keep=14 应全留，剩 $(snap_count)"

# 2) 保留 5 → 最老 7 份删净，最新 5 份在
SEM_TIMELINE_KEEP=5 prune_local_timeline "$dev"
[[ "$(snap_count)" == 5 ]] || fail "keep=5 应剩 5 份，实际 $(snap_count)"
for d in 08 09 10 11 12; do
    [[ -f "$dev/2026/09/$d/1200-morning/STORY.md" ]] || fail "新快照 $d 不应被删"
done
for d in 01 02 03 04 05 06 07; do
    [[ ! -e "$dev/2026/09/$d" ]] || fail "旧快照 $d 应连空目录一起清理"
done
[[ -f "$dev/profile.json" && -f "$dev/rescue-test.txt" ]] || fail "设备级文件被误删"

# 3) <=0 跳过清理；非数字回落默认 14（5 份不受影响）
SEM_TIMELINE_KEEP=0 prune_local_timeline "$dev"
SEM_TIMELINE_KEEP=abc prune_local_timeline "$dev"
[[ "$(snap_count)" == 5 ]] || fail "keep=0/abc 不应清理，剩 $(snap_count)"

# ---------- run JSON 留档轮转（prune_run_jsons）----------
# 原实现 `ls -1t … | xargs rm -f` 把 ls 输出按空白拆词喂给 rm：目录里出现带空格
# 或分号的名字，删除目标就会被拆到别处。口径与 prune_local_timeline 一致——
# 只放行 run-YYYYMMDD-HHMMSS.json 形态，其余一律不动。
declare -F prune_run_jsons >/dev/null || fail "prune_run_jsons 未定义（轮转仍是裸 xargs rm）"
runs="$tmp/runs"
mkdir -p "$runs"
# 65 份合法留档，mtime 递增（10:00..11:04）
for i in $(seq 1 65); do
    hh=$((10 + (i - 1) / 60)); mm=$(( (i - 1) % 60 ))
    f="$runs/$(printf 'run-20260910-%02d%02d%02d.json' "$hh" "$mm" 0)"
    echo '{}' > "$f"
    touch -t "$(printf '20260910%02d%02d' "$hh" "$mm")" "$f"
    if [[ $i -eq 1 ]]; then oldest_f="$f"; fi
    if [[ $i -eq 65 ]]; then newest_f="$f"; fi
done
# 非留档形态：mtime 最老（必须落进轮转窗口才谈得上守卫），若无白名单守卫必被删
echo 'x' > "$runs/run-20260101-000000 .json"          # 名字含空格
echo 'x' > "$runs/run-20260101;000000.json"           # 名字含分号
echo 'x' > "$runs/run-20260101-000000.json.bak"       # 后缀不符
touch -t 202601010000 "$runs/run-20260101-000000 .json" \
    "$runs/run-20260101;000000.json" "$runs/run-20260101-000000.json.bak"
# 只数严格留档形态（上面两个含空格/分号的名字也会被 run-*.json 通配命中）
count_valid() {
    local n=0 f
    for f in "$1"/run-*.json; do
        [[ -f "$f" ]] || continue
        if [[ "${f##*/}" =~ ^run-[0-9]{8}-[0-9]{6}\.json$ ]]; then n=$((n + 1)); fi
    done
    echo "$n"
}
# 1) 65 > 60：最老 5 份删净，最新一份与全部非留档形态都在
prune_run_jsons "$runs"
left="$(count_valid "$runs")"
[[ "$left" == 60 ]] || fail "keep=60 应剩 60 份留档，实际 $left"
[[ ! -e "$oldest_f" ]] || fail "最老留档 $oldest_f 应被删"
[[ -f "$newest_f" ]] || fail "最新留档被误删"
for keep_name in 'run-20260101-000000 .json' 'run-20260101;000000.json' 'run-20260101-000000.json.bak'; do
    [[ -f "$runs/$keep_name" ]] || fail "非留档形态被误删: $keep_name"
done
# 2) 显式 keep=10 → 只留最新 10 份，非留档形态仍然不动
prune_run_jsons "$runs" 10
left="$(count_valid "$runs")"
[[ "$left" == 10 ]] || fail "keep=10 应剩 10 份，实际 $left"
[[ -f "$runs/run-20260101;000000.json" ]] || fail "keep=10 时非留档形态被误删"
# 3) 路径含空格（BACKUP_BASE 落在 “My Documents” 这类目录是真实配置）：
#    不带 -0 的 xargs 会把 ls 输出的路径按空白二次拆词，旧实现下一个也删不掉。
space_runs="$tmp/My Docs/runs"
mkdir -p "$space_runs"
for i in $(seq 1 65); do
    hh=$((10 + (i - 1) / 60)); mm=$(( (i - 1) % 60 ))
    f="$space_runs/$(printf 'run-20260910-%02d%02d%02d.json' "$hh" "$mm" 0)"
    echo '{}' > "$f"
    touch -t "$(printf '20260910%02d%02d' "$hh" "$mm")" "$f"
done
prune_run_jsons "$space_runs"
[[ "$(count_valid "$space_runs")" == 60 ]] || \
    fail "含空格路径下轮转失效，剩 $(count_valid "$space_runs") 份"
[[ ! -e "$space_runs/run-20260910-100000.json" ]] || fail "含空格路径下最老留档未删"
# 4) 语义层不再有可执行的 ls|xargs rm（注释里提到旧写法不算）
if grep -nE '^[[:space:]]*[^#]*xargs[[:space:]]+rm' semantic/semantic.sh >/dev/null; then
    grep -nE '^[[:space:]]*[^#]*xargs[[:space:]]+rm' semantic/semantic.sh
    fail "semantic.sh 仍有 ls | xargs rm（删除目标由词分割的 ls 输出决定）"
fi

echo "PASS: timeline retention（14 全留 / 5 截断 / 设备级文件完好 / 0 与非数字不误删）+ run JSON 轮转白名单守卫"
