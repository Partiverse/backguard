#!/bin/bash
# mutate_initkeys.sh —— 逐把刀跑 init-keys 守卫（容器内执行）
#
# 口径同其它夹具的变异驱动：
#   1) 先把整棵仓库拷进可写目录（cp -a，含 .git 之外的全部；探针要读 backup.ps1 等所以不能只拷 4 个文件）
#   2) 注刀：**没落上就记 NOT-APPLIED 并跳过**，绝不拿未变异的那份跑夹具（10-01 那次的假结论来源）
#   3) 跑夹具，逐字记下 FAIL 行与汇总行；汇总行缺失＝夹具自己崩了，记 UNDETERMINED 而不是「没咬住」
#   4) m13 额外跑一遍探针（那条主张的守卫是探针本身，不是夹具）
set -uo pipefail

SRC=${1:-/repo}
OUT=${2:-/mut}
IDS=${3:-"m01 m02 m03 m04 m05 m06 m07 m07b m08 m09 m10 m11 m12 m13 m14 m15 m16"}
APPLIER=${APPLIER:-/repo/tools/apply_mut_initkeys.ps1}

for id in $IDS; do
  d="$OUT/$id"
  rm -rf "$d"
  mkdir -p "$d"
  # 拷工作树（.git 不要：夹具与探针都不读它，而它能让变异树里混进旧测试）
  (cd "$SRC" && tar --exclude=.git -cf - .) | (cd "$d" && tar -xf -)

  echo "=== $id ==="
  pwsh -NoProfile -File "$APPLIER" -Id "$id" -Src "$SRC" -Dst "$d"
  arc=$?
  if [[ $arc -ne 0 ]]; then
    echo "$id: NOT-APPLIED rc=$arc"
    continue
  fi

  if [[ "$id" == "m13" ]]; then
    pout=$(cd /tmp && pwsh -NoProfile -File "$d/probe_windows_ps51.ps1" 2>&1)
    prc=$?
    echo "$id: probe rc=$prc $(echo "$pout" | grep -E '^probe51-eap:' | head -1)"
    echo "$pout" | grep -E 'violation|^probe51' | head -8
  fi

  (cd /tmp && pwsh -NoProfile -File "$d/test_init_keys_e2e.ps1" -Repo "$d") > "$d/suite.log" 2>&1
  src=$?
  nfail=$(grep -c '^FAIL' "$d/suite.log")
  summ=$(grep -E '^INITKEYS-E2E-(OK|FAIL)' "$d/suite.log" | tail -1)
  echo "$id: suite rc=$src failcount=$nfail summary='${summ:-<absent: UNDETERMINED>}'"
  grep '^FAIL' "$d/suite.log" | head -8
done
