#!/usr/bin/env bash
# prune_local_timeline / prune_run_jsons 单测（隔离临时目录，不触网不碰真实配置）：
#   默认 14 / 显式 N / 设备级文件不动 / 空日期壳**一路收到年**（2b）/ <=0 与非数字行为
#   run JSON 留档轮转：白名单守卫只放行 run-YYYYMMDD-HHMMSS.json，含空格/分号的名字不误删
set -euo pipefail
cd "$(dirname "$0")"

# semantic.sh 由 backup.sh source 而来，日志函数是外部依赖——stub 掉
log(){ :; }; info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }
source semantic/semantic.sh

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bg-retention.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/timeline"          # 10-01 起时间轴根下直接是 YYYY/MM/DD/HHMM-标签，没有设备层

snap_count() { find "$stage" -mindepth 4 -maxdepth 4 -type d | wc -l | tr -d ' '; }
fail() { echo "FAIL: $1"; exit 1; }

# 12 份快照（DD 补零，路径排序即时间序）+ 时间轴根级文件
mkdir -p "$stage"
for d in 01 02 03 04 05 06 07 08 09 10 11 12; do
    mkdir -p "$stage/2026/09/$d/1200-morning"
    echo x > "$stage/2026/09/$d/1200-morning/STORY.md"
done
echo p > "$stage/profile.json"
echo r > "$stage/rescue-test.txt"

# 1) 默认 14 > 现有 12 → 全留
SEM_TIMELINE_KEEP=14 prune_local_timeline "$stage"
[[ "$(snap_count)" == 12 ]] || fail "keep=14 应全留，剩 $(snap_count)"

# 2) 保留 5 → 最老 7 份删净，最新 5 份在
SEM_TIMELINE_KEEP=5 prune_local_timeline "$stage"
[[ "$(snap_count)" == 5 ]] || fail "keep=5 应剩 5 份，实际 $(snap_count)"
for d in 08 09 10 11 12; do
    [[ -f "$stage/2026/09/$d/1200-morning/STORY.md" ]] || fail "新快照 $d 不应被删"
done
for d in 01 02 03 04 05 06 07; do
    [[ ! -e "$stage/2026/09/$d" ]] || fail "旧快照 $d 应连空目录一起清理"
done
[[ -f "$stage/profile.json" && -f "$stage/rescue-test.txt" ]] || fail "时间轴根级文件被误删"

# 2b) 空壳级联必须**一路收到年**。上面 12 份种子全挤在同一个月（2026/09），月份壳永远不会空，
#     所以这条断言此前在两侧都不存在——PowerShell 移植版 10-02 正是因此漏过一发：它的级联是
#     「先筛空、再统一删」，一趟只收掉日期这一层，月份壳照旧留着，而它的守卫也没测到（在 Linux
#     容器里跑 pwsh 才抓出来）。bash 侧 find -empty -delete 隐含 -depth，天然自深向浅一趟收净，
#     但「天然正确」没有断言兜着，下一次移植照样会错——补在这里就是把这条口径钉成契约。
mkdir -p "$stage/2025/03/04/1200-night" "$stage/2026/01/02/1200-morning"
echo x > "$stage/2025/03/04/1200-night/STORY.md"
echo x > "$stage/2026/01/02/1200-morning/STORY.md"
SEM_TIMELINE_KEEP=5 prune_local_timeline "$stage"
[[ "$(snap_count)" == 5 ]] || fail "跨年补种后 keep=5 应剩 5 份，实际 $(snap_count)"
[[ ! -e "$stage/2025/03/04" ]] || fail "跨年旧快照的日期壳没收掉"
[[ ! -e "$stage/2025/03" ]] || fail "旧快照的月份壳没收掉"
[[ ! -e "$stage/2025" ]] || fail "旧快照的年壳没收掉——级联只走了一层"
[[ ! -e "$stage/2026/01" ]] || fail "2026/01 的月份壳没收掉"
[[ -d "$stage/2026/09" ]] || fail "还有现役快照的月份被误删"
[[ -f "$stage/2026/09/12/1200-morning/STORY.md" ]] || fail "最新快照被误删"

# 3) <=0 跳过清理；非数字回落默认 14（5 份不受影响）
SEM_TIMELINE_KEEP=0 prune_local_timeline "$stage"
SEM_TIMELINE_KEEP=abc prune_local_timeline "$stage"
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
# 2b) SEM_RUN_JSON_KEEP 旋钮：不传第二参时按 config 的环境变量收——这批 run json 是
#     渲染前的**全量文件名清单**（真机单个 22 MB），保留数就是本地长期存着多少份未密封
#     名单，收紧它不该要求改代码
SEM_RUN_JSON_KEEP=8 prune_run_jsons "$runs"
left="$(count_valid "$runs")"
[[ "$left" == 8 ]] || fail "SEM_RUN_JSON_KEEP=8 应剩 8 份，实际 $left"
# 显式第二参必须顶赢环境变量（现有调用点与测试都靠这个优先级）
SEM_RUN_JSON_KEEP=1 prune_run_jsons "$runs" 7
left="$(count_valid "$runs")"
[[ "$left" == 7 ]] || fail "显式 keep=7 应顶赢 SEM_RUN_JSON_KEEP=1，实际 $left"
# 非数字回落默认 60：架上只有 7 份，一条都不该被删
SEM_RUN_JSON_KEEP=abc prune_run_jsons "$runs"
[[ "$(count_valid "$runs")" == 7 ]] || fail "SEM_RUN_JSON_KEEP=abc 应回落 60 而不清理，实际 $(count_valid "$runs")"
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

echo "PASS: timeline retention（14 全留 / 5 截断 / 空壳一路收到年 / 时间轴根级文件完好 / 0 与非数字不误删）+ run JSON 轮转白名单守卫"
