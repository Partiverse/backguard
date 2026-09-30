#!/usr/bin/env bash
# prune_local_timeline 单测（隔离临时目录，不触网不碰真实配置）：
#   默认 14 / 显式 N / 设备级文件不动 / 空日期目录收掉 / <=0 与非数字行为
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

echo "PASS: timeline retention（14 全留 / 5 截断 / 设备级文件完好 / 0 与非数字不误删）"
