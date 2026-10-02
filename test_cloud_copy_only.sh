#!/usr/bin/env bash
# 红线守卫（AGENTS.md §1.4「云端只增不减」）：云端一律 rclone copy，
# 任何**产品脚本**出现 `rclone sync` 都会让本地 prune 把云端历史一起删掉。
# 纯静态检查，不触网不建仓库——本机与 CI 都可跑。
# 用法: ./test_cloud_copy_only.sh [仓库根]
#
# 豁免只有两类，且必须逐条写明：
#   1) 本守卫自己（报错行里要能打出这个词）
#   2) test_* 夹具——它们写出这个词，正是为了断言产品脚本里没有它。
#      2f746ab 那轮 linux job 就是红在这里：test_rescue_e2e.ps1 里那条
#      「静态 rescue.ps1 里没有 rclone sync」的断言文本被守卫当成违规命中，
#      红线守卫咬住了同事的守卫，而它扫描的那棵树里根本没有 sync。
#      只豁免「判定用的字面量」，不豁免任何产品脚本，红线本身一格没松。
#
# 但只有豁免还不够：豁免规则写宽一个字符（`test_*` 手滑成 `*`）就会把产品脚本
# 一起豁免掉，而「一个文件都没扫」和「扫过且干净」在这份输出里长得一模一样——
# 都是 E2E-OK。所以扫描面自己也是被测面：产品入口逐个点名，少一个就判红，
# 结论行还把 scanned= 打出来（汇总计数单独成句，别只看「有没有命中」）。
#
# 变异台账（10-03 实测，每把刀摘的是不同的实现，跑法见文件末尾；5 发刀 + 1 发对照全部符合期望）：
#   k1 backup.sh 注真 `rclone sync`         -> FAIL，命中行是 backup.sh
#   k2 豁免 case 写成 '*'（连产品一起豁免）  -> FAIL 在 tripwire，而不是判绿
#   k3 find 表达式摘掉 -name '*.ps1'        -> FAIL 在 tripwire（.ps1 名单缺席）
#   k4 扫描根换成空目录（守卫照样在场）       -> FAIL 在 tripwire（这就是 scanned=0 的假绿）
#   k5 backup.ps1 注真 `rclone sync`        -> FAIL，命中行是 backup.ps1
#   对照（不是刀）：同样那句注进 test_x.sh    -> 仍然 E2E-OK，证明豁免是活的不是死的
# 报错要能指到人：命中行打 `相对路径:行号:原文`，不是只打个文件名。
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$V0_DIR}"
SELF="$(basename "$0")"

fail() { echo "E2E-FAIL: $1"; exit 1; }

# 产品入口点名清单（相对扫描根）。它**不定义**扫描面——判定走整树 find，
# 忘了登记的新脚本照样被内容检查抓到；这份清单只证明「该扫的还在扫」。
# 单引号里的「续行反斜杠」不是续行（bash 3.2/5.x 都把 `\` 当字面量，于是清单里多出
# 一个叫 `\` 的条目，tripwire 当场假红）——拼接放在双引号里做。
PRODUCTS='backup.sh restore.sh drill.sh init.sh rescue.sh verify-nightly.sh'
PRODUCTS="$PRODUCTS semantic/semantic.sh backup.ps1 rescue.ps1 init-keys.ps1"
PRODUCTS="$PRODUCTS probe_windows_ps51.ps1 semantic/semantic.ps1"

nl=$'\n'
scanned=0
rel_list="${nl}"
hits=''

cd "$ROOT" 2>/dev/null || fail "进不去扫描根: ${ROOT}"
while IFS= read -r f; do
    base="${f##*/}"
    case "$base" in
        "$SELF"|test_*) continue ;;
    esac
    rel="${f#./}"
    scanned=$((scanned + 1))
    rel_list="${rel_list}${rel}${nl}"
    hl="$(grep -nE 'rclone[[:space:]]+sync' "$f" || true)"
    if [[ -n "$hl" ]]; then
        while IFS= read -r h; do
            hits="${hits}${rel}:${h}${nl}"
        done <<<"$hl"
    fi
done < <(find . \( -path './.git' -prune \) -o \( -name '*.sh' -o -name '*.ps1' \) -print)

# 先证扫描面，再下「干净」的结论：扫描面塌了的时候，命中数为 0 毫无意义。
for p in $PRODUCTS; do
    case "$rel_list" in
        *"${nl}${p}${nl}"*) ;;
        *) fail "扫描面里没有产品脚本 ${p}（豁免或 include 规则塌了，这不等于「没有 rclone sync」；实扫 ${scanned} 个）" ;;
    esac
done

if [[ -n "$hits" ]]; then
    printf '%s' "$hits"
    fail "发现 rclone sync（云端只增不减红线：一律用 rclone copy）"
fi

echo "E2E-OK: 扫描面 ${scanned} 个产品脚本（豁免 本守卫 + test_* 夹具），无 rclone sync（云端只增不减）"

# 变异复现口径（都在临时副本里跑，不动工作树）：
#   T=$(mktemp -d); rsync -a --exclude .git --exclude tmp --exclude .github "$PWD"/ "$T"/
#   k1: 往 $T/backup.sh 末尾追加一行 `rclone sync "$LOCAL_DIR" "$REMOTE_DIR"`
#   k2: 把 case 的 "$SELF"|test_*) 改成 *) continue ;;
#   k3: 把 find 的 \( -name '*.sh' -o -name '*.ps1' \) 改成 \( -name '*.sh' \)
#   k4: E=$(mktemp -d); cp test_cloud_copy_only.sh "$E"/; bash "$E/test_cloud_copy_only.sh" "$E"
#   k5: 往 $T/backup.ps1 末尾追加一行 rclone sync（证明 *.ps1 那条 include 是活的）
#   对照: 同样那句写进 $T/test_dummy.sh —— 必须仍然 E2E-OK
#   跑法: bash "$T/test_cloud_copy_only.sh" "$T"；注刀后用 grep 验落上，没落别下结论
