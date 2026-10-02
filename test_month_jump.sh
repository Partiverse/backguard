#!/usr/bin/env bash
# E2E：把时间推过一个月——四条低频路径在**同一次运行**里一起触发（roadmap A2a/A2b/A4/A6 的组合面）。
#
# 为什么要有这一份：四条路径各自都有单项夹具（test_integrity / test_drill_e2e /
# test_log_rotation / test_timeline_retention / test_cloud_verify），但「一个月真的过去了」
# 那一夜从没整体跑过。单项夹具造不出来的东西恰好是这一份要测的：
#   1) 完整性窗口与演练窗口**同时**到期的一轮，备份本体还是不是 FULLY COMPLETE——
#      A2a/A2b 都是「引擎旁边的旁路」，旁路同夜一起动时最容易互相把谁带崩；
#   2) 云端自证的「单向包含」第一次由**真实保留策略**造成：prune_local_timeline 把老快照
#      从本地裁掉，而它们仍全量躺在云端。test_cloud_verify 第 2 段那一份是夹具手种的，
#      种的形状对不对没人负责；这里由生产代码自己裁出来。
#   3) 报告的「晚一轮上云」是设计（先比对后落笔），只有连着跑两轮才看得见：
#      第 1 轮云端不该有 INTEGRITY.txt，第 2 轮该有。
#   4) rescue-test.txt 只留本地这条红线，在「保留策略裁过 + 真推送」的这一夜仍然成立。
#
# 「时间旅行」的做法：**不碰 OS 时钟**。低频窗口的标记就是产物自身的 mtime
# （integrity_due 读 INTEGRITY.txt、run_drill 读 rescue-test.txt），所以把产物 touch -t 到
# 40 天前 ≡ 日历翻过一页，而归档名与时间轴路径仍由真实「现在」生成——这正是生产里窗口
# 到期那一夜的形状。改系统时钟会同时打乱 launchd 排程、borg 写入的时间戳（永久进归档历史）
# 和时间轴日期目录，属生产事故，不在测试里做。
# 时间轴保留是按**路径名**排序的（find + LC_ALL=C sort 取尾 keep 份），所以种子必须是
# 旧日期的目录名，touch mtime 对它无效。
#
# 断言面（每条一个专属变异，见 docs/HANDOVER §4.16）：
#   A) 首备：三类仓库各自校验（checks=3）、演练按内容哈希取证、自证 8 项（privacy + timeline
#      + 3×repo + 3×config）全 PASS、16 份旧快照推上云端、云端此刻还没有 INTEGRITY.txt；
#   B) 窗口重开：INTEGRITY.txt / rescue-test.txt 的生成时间行都换新（变异 m01/m02）；
#   C) 同一轮仍 FULLY COMPLETE 且自证 FAIL=0——单向包含在真实裁剪下成立（变异 m03）；
#   D) 裁掉的是**最老的那批**：拿「云端有 / 本地没有」的集合与本地最老的一份比字典序，
#      被裁的必须全部比留下的老（变异 m05；只数条数不够，排序方向反了照样是 14 份）；
#   E) 云端一份没少（18 份快照 + 2020-01-01 的 MANIFEST.txt 还躺着）；
#   F) 日志轮转在这一夜切出副本，现役日志里没有历史噪音，本轮边界行落进现役日志（变异 m06）；
#   G) rescue-test.txt 两轮都没上云（变异 m04）。
#   H) 完整性报告**晚一轮**上云（它排在时间轴推送之后）；挪到推送之前就成了自指报告（变异 m07）。
# 用法: ./test_month_jump.sh   （需 bash 4 + borg + rclone + age + python3；rclone 用 local 后端，不触网）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
for _need in borg rclone age age-keygen python3; do
    command -v "$_need" >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 ${_need}，未测"; exit 0; }
done

T="$(mktemp -d /tmp/bg-monthjump.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log" 2>/dev/null || true; exit 1; }

# 三类仓库各存自己的子树，路径互不重叠（AGENTS §5：只建 files 就测不到跨类别错配）
mkdir -p "$T/src/Documents" "$T/src/AppData" "$T/src/etc" "$T/home" "$T/logs" \
         "$T/conf/partiverse-backup/age" "$T/dest" "$T/repos"
printf 'note v1\n'      > "$T/src/Documents/note.txt"
printf 'photo bytes\n'  > "$T/src/Documents/photo.bin"
printf 'cfg v1\n'       > "$T/src/AppData/settings.json"
printf 'sys v1\n'       > "$T/src/etc/hosts"
printf '[mjtarget]\ntype = local\n' > "$T/rclone.conf"

cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Mac"
export SYSTEM_ID="E2E-Mac"
export BACKUP_BASE="$T/repos"
export BORG="$(command -v borg)"
export RCLONE="$(command -v rclone)"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=("mjtarget:backup-mac")
export LOG_DIR="$T/logs"
BORG_INCLUDES_config=("$T/src/AppData")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src/Documents")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src/etc")
BORG_EXCLUDES_system=()
CONF
echo "BORG_PASSPHRASE='e2e-pass'" > "$T/conf/partiverse-backup/secrets.env"
chmod 600 "$T/conf/partiverse-backup/secrets.env"

KEYS="$T/conf/partiverse-backup/age"
age-keygen -o "$KEYS/identity.txt" >/dev/null 2>&1 || fail "age-keygen 失败"
chmod 600 "$KEYS/identity.txt"
sed -n 's/^# public key: \(age1[0-9a-z]*\).*/\1/p' "$KEYS/identity.txt" > "$KEYS/recipients.txt"
[[ -s "$KEYS/recipients.txt" ]] || fail "取不到公钥: $(head -1 "$KEYS/identity.txt")"

# 16 份「上个月以前」的快照：日期目录名就是保留策略的唯一判据，所以给旧日期而不是旧 mtime。
# 名字尾部 `0234-old` 必须命中 prune 的形态白名单 ^[0-9]{4}-[a-z0-9-]+$，否则它们根本进不了
# 删除候选，D/E 两段断言会一起变成死断言。
for i in $(seq 1 16); do
    printf -v dd '%02d' "$i"
    seed="$T/repos/timeline/2020/01/$dd/0234-old"
    mkdir -p "$seed"
    printf 'seed %s\n' "$i" > "$seed/MANIFEST.txt"
done

IT="$T/repos/timeline/INTEGRITY.txt"
RT="$T/repos/timeline/rescue-test.txt"
CV="$T/repos/timeline/CLOUD-VERIFY.txt"
CLOUD="$T/dest/backup-mac/E2E-Mac"
LOG="$T/logs/backup.log"

# 一轮真实备份：local 后端的根就是 cwd，所以整轮在 $T/dest 里跑
run_backup() { (
    cd "$T/dest"
    # ${1:-}：set -u 下无参调用是致命变量错误（AGENTS §2 同一条坑）
    # shellcheck disable=SC2086  # 分词是有意的：把 $1 当多个 KEY=VAL 传进 env
    env SKIP_WEBDAV=0 XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" \
        HOME="$T/home" SEM_DRILL=1 SEM_DRILL_COUNT=99 SEM_NTFY_URL="" ${1:-} \
        bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
); }

snap_count() { { find "$1" -mindepth 4 -maxdepth 4 -type d 2>/dev/null || true; } | wc -l | tr -d ' '; }
# 快照名单（相对各自根，已排序）：D 段要拿「云端有而本地没有」的那批去证明裁掉的是最老的，
# 只数条数不够——排序方向反了照样是 14 份
snap_list() { { find "$1" -mindepth 4 -maxdepth 4 -type d 2>/dev/null || true; } \
    | sed "s#^$1/##" | LC_ALL=C sort; }
# grep -c 命中 0 行时 rc=1，pipefail 下会炸掉夹具本身（AGENTS §3「死断言」那一类）
field_of() {  # $1=文件 $2=字段名
    { grep -o "$2=[0-9]*" "$1" 2>/dev/null || true; } | head -1 | cut -d= -f2 | tr -d '[:space:]'
}
boundary_re='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] run 边界: sha=[0-9a-f]{7,40} rc=[0-9]+ dur=[0-9]+s$'
boundary_count() { { grep -E "$boundary_re" "$1" 2>/dev/null || true; } | wc -l | tr -d ' '; }
# 退出码非零时先吐「哪一行把这一轮判红的」，再吐退出码本身（AGENTS §3：两种坏法不能撞成
# 同一句报错）。grep 无命中＝全绿，那也要打点东西，所以退回整份报告的头三行数据
verify_problems() {   # $1=报告文件
    local hits
    hits="$( { grep -E '^(FAIL|UNKNOWN|HEALED)' "$1" 2>/dev/null || true; } | head -3 | tr '\n' '|')"
    [[ -n "$hits" ]] || hits="$( { grep -v '^#' "$1" 2>/dev/null || true; } | head -3 | tr '\n' '|')"
    printf '%s' "$hits"
}

# ---------- 1：首备（KEEP 拉满，让 16 份种子先被推上云端）----------
# 两轮必须给**不同**的 SEM_LABEL：快照目录名是 `HHMM-标签`，本机连着跑两轮会落在同一分钟，
# 同名就等于复用同一个快照目录——第二轮眼里只有 17 份而不是 18 份，裁剪条数与「今天的两份
# 快照都在」两条断言一起歪掉（10-02 实测踩过：两轮都是 1126-noon，只裁了 3 份）。
rc=0; run_backup "SEM_TIMELINE_KEEP=99 SEM_LABEL=mj-first" || rc=$?
# 退出码非零有好几种坏法（自证判红 / 完整性判红 / 推送失败），把自证报告一起吐出来＝「哪条
# 检查抓到的」先于「它改了退出码」（AGENTS §3：两条主张撞成一句就分不清坏在哪一步）
[[ $rc -eq 0 ]] || fail "首备退出非零（rc=${rc}）：自证 $(verify_problems "$CV") | $(tail -20 "$T/out.log")"
cp "$T/out.log" "$T/out1.log"
grep -q 'FULLY COMPLETE' "$T/out1.log" || fail "首备没宣布 FULLY COMPLETE：$(tail -8 "$T/out1.log")"

[ -f "$IT" ] || fail "首备没落 INTEGRITY.txt（时间轴根：$(ls "$T/repos/timeline")）"
[[ "$(field_of "$IT" checks)" == "3" ]] \
    || fail "首备的完整性报告没把三类仓库各自登记（checks=$(field_of "$IT" checks)）：$(grep -v '^#' "$IT")"
[[ "$(field_of "$IT" FAIL)" == "0" ]] || fail "首备完整性报告有 FAIL：$(grep -v '^#' "$IT")"
[ -f "$RT" ] || fail "首备没落 rescue-test.txt"
# A2b：演练这一夜必须是按内容取证，而不是全退回比大小
if ! grep -qE '^RESULT: [0-9]+ PASS / 0 FAIL（抽样 [0-9]+；内容哈希 [1-9]' "$RT"; then
    fail "首备的演练结论没按内容哈希取证：$(grep -E '^(RESULT|# 方式)' "$RT")"
fi
[ -f "$CV" ] || fail "首备没落 CLOUD-VERIFY.txt"
[[ "$(field_of "$CV" FAIL)" == "0" ]] || fail "首备自证有 FAIL：$(grep -v '^#' "$CV")"
[[ "$(snap_count "$CLOUD/timeline")" == "17" ]] \
    || fail "云端时间轴没收下 16 份旧快照 + 本轮快照（实得 $(snap_count "$CLOUD/timeline")）"
# 报告的「晚一轮」是设计：run_integrity_check 排在时间轴推送之后，所以第 1 轮云端不该有它。
# 它一旦被挪到推送之前（变异 m07），这份报告就会自指——云端出现的是本轮刚写的那份，
# 「云端有上轮的结论」这个审计价值就没了。
if [ -e "$CLOUD/timeline/INTEGRITY.txt" ]; then
    fail "第 1 轮云端就有 INTEGRITY.txt——完整性报告被推到了时间轴推送之前（自指）"
fi
if [ -e "$CLOUD/timeline/rescue-test.txt" ]; then
    fail "第 1 轮云端就有 rescue-test.txt（红线 §1.1：带完整文件名，只准留本地）"
fi

it_stamp1="$(head -2 "$IT" | tail -1)"
rt_stamp1="$(head -1 "$RT")"

# ---------- 2：时间推过一个月 ----------
# touch -t 只动 INTEGRITY.txt / rescue-test.txt 的 mtime = 把两个 30 天窗口做到期；
# 时间轴裁剪靠改 KEEP 参数（判据是名字不是 mtime）；轮转靠把现役日志灌过阈值。
AGE_TS=202501010234.00
touch -t "$AGE_TS" "$IT" "$RT"
for i in $(seq 1 5000); do echo "[2026-09-30 02:34:00] [ERR] 一个月攒下的历史噪音 $i" >> "$LOG"; done
[ "$(wc -c < "$LOG")" -gt 60000 ] || fail "前置：预制日志没超过阈值，轮转断言无从谈起"
# 同长度改写：只比大小的口径对这类变化天生看不见，内容哈希必须看得见
printf 'note v2\n' > "$T/src/Documents/note.txt"

rc=0; run_backup "SEM_TIMELINE_KEEP=14 SEM_LOG_MAX_BYTES=60000 SEM_LOG_KEEP=3 SEM_LABEL=mj-jump" || rc=$?
[[ $rc -eq 0 ]] || fail "窗口到期那一轮退出非零（rc=${rc}）：自证 $(verify_problems "$CV") | 完整性 $(verify_problems "$IT") | $(tail -20 "$T/out.log")"
cp "$T/out.log" "$T/out2.log"
grep -q 'FULLY COMPLETE' "$T/out2.log" || fail "两个窗口同夜到期却没 FULLY COMPLETE：$(tail -8 "$T/out2.log")"

# ---------- B：两个 30 天窗口都真的重开了 ----------
if grep -q '未到校验窗口' "$T/out2.log"; then
    # 这句是 info() 写的，走 stdout；它出现＝节流没随 mtime 放开
    fail "INTEGRITY.txt 被做到 40 天前之后仍判「未到校验窗口」——月度窗口不是由产物 mtime 定的"
fi
[[ "$(head -2 "$IT" | tail -1)" != "$it_stamp1" ]] \
    || fail "第二轮没重写 INTEGRITY.txt 的生成时间行（窗口没重开？）：$(head -2 "$IT")"
[[ "$(field_of "$IT" checks)" == "3" ]] \
    || fail "重开的完整性校验没有三类仓库（checks=$(field_of "$IT" checks)）：$(grep -v '^#' "$IT")"
if grep -q '上次演练不足 30 天' "$T/out2.log"; then
    fail "rescue-test.txt 被做到 40 天前之后仍判「不足 30 天」——演练窗口没跟着 mtime 走"
fi
[[ "$(head -1 "$RT")" != "$rt_stamp1" ]] \
    || fail "第二轮没重跑演练（rescue-test.txt 头行还是上一轮那份）：$(head -1 "$RT")"
if ! grep -qE '^RESULT: [0-9]+ PASS / 0 FAIL（抽样 [0-9]+；内容哈希 [1-9]' "$RT"; then
    fail "窗口重开那一夜的演练退回只比大小：$(grep -E '^RESULT' "$RT")"
fi

# ---------- C：真实保留策略造成的「云端多出一份」不得判失败 ----------
# 8 项 = privacy + timeline + 三类 repo + 三类 config（AGENTS §3：汇总计数行值得单独断言，
# 忘了登记某类校验对象时，「有没有 FAIL」看不出来，只有这一行会暴露）
[[ "$(field_of "$CV" checks)" == "8" ]] \
    || fail "自证项数不对（checks=$(field_of "$CV" checks)，应为 privacy/timeline/3×repo/3×config）：$(grep -v '^#' "$CV")"
[[ "$(field_of "$CV" FAIL)" == "0" ]] \
    || fail "本地裁过之后自证判了 FAIL——单向包含被写成了双向相等：$(grep -v '^#' "$CV")"
[[ "$(field_of "$CV" HEALED)" == "0" ]] || fail "全绿轮却出现 HEALED：$(grep -v '^#' "$CV")"
[[ "$(field_of "$CV" UNKNOWN)" == "0" ]] \
    || fail "local 后端没有读不出的道理，UNKNOWN 却出现了（清单/哈希那条路在 BSD 上变形了？）：$(grep '^UNKNOWN' "$CV")"

# ---------- D：裁的是最老的几份，不是「随便留 14 份」----------
local_snaps="$(snap_list "$T/repos/timeline")"
cloud_snaps="$(snap_list "$CLOUD/timeline")"
[[ "$(printf '%s\n' "$local_snaps" | grep -c .)" == "14" ]] \
    || fail "本地时间轴没裁到 14 份（实得 $(printf '%s\n' "$local_snaps" | grep -c .)）"
pruned="$( { comm -23 <(printf '%s\n' "$cloud_snaps") <(printf '%s\n' "$local_snaps"); } )"
[[ -n "$pruned" ]] || fail "本地一份都没裁，「按名字排序取尾」这条断言无从谈起"
newest_pruned="$(printf '%s\n' "$pruned" | tail -1)"
oldest_kept="$(printf '%s\n' "$local_snaps" | head -1)"
# 被裁的那批必须**全部比留下的老**。只数条数抓不到排序方向：方向反了同样是「留下 14 份」，
# 但留下的是最老的 14 份、裁掉的是今天的两份（变异 m05 就是 sort -r）
[[ "$(printf '%s\n%s\n' "$newest_pruned" "$oldest_kept" | LC_ALL=C sort | head -1)" == "$newest_pruned" ]] \
    || fail "裁掉的不是最老的几份（最新被裁=${newest_pruned}，最老留下=${oldest_kept}）"
today="$(date +%Y/%m/%d)"
# glob 计数而不是 ls | grep：名字里将来可能出现别的字符，而 nullglob 保证「零份」是一个
# 空数组而不是一个不存在的字面路径（同 F 段那条规矩）
shopt -s nullglob
today_snaps=( "$T/repos/timeline/$today"/* )
shopt -u nullglob
[[ ${#today_snaps[@]} == "2" ]] \
    || fail "两轮快照没双双留在本地（$today 下实得 ${#today_snaps[@]} 项：${today_snaps[*]-}）"

# ---------- E：云端只增不减 ----------
[[ "$(printf '%s\n' "$cloud_snaps" | grep -c .)" == "18" ]] \
    || fail "云端时间轴应当一份没少（16 种子 + 两轮，实得 $(printf '%s\n' "$cloud_snaps" | grep -c .)）"
[ -f "$CLOUD/timeline/2020/01/01/0234-old/MANIFEST.txt" ] \
    || fail "本地裁掉的 2020-01-01 在云端也没了——云端用了 sync 或发生了删除"
[ -f "$CLOUD/timeline/INTEGRITY.txt" ] || fail "上一轮的 INTEGRITY.txt 没随本轮时间轴推送上云"
[ -f "$CLOUD/timeline/CLOUD-VERIFY.txt" ] || fail "上一轮的 CLOUD-VERIFY.txt 没随本轮时间轴推送上云"
# ---------- G：红线 §1.1 在这一夜仍然成立 ----------
if [ -e "$CLOUD/timeline/rescue-test.txt" ]; then
    fail "云端时间轴里出现 rescue-test.txt（红线 §1.1；--exclude 只挡新副本，这里连新的都挡不住了）"
fi

# ---------- F：轮转 + 边界行在同一夜 ----------
# nullglob 是必需的：没轮转成时 glob 不展开，数组里会躺着一个**不存在**的字面路径，
# 后面 ${copies[0]} 拿去 grep 会得到「没匹配」而不是「文件不存在」，把 F 段变成死断言
shopt -s nullglob
copies=( "$T/logs"/backup.log.[0-9]* )
shopt -u nullglob
[[ ${#copies[@]} == "1" ]] || fail "应当恰好轮转一次（副本数=${#copies[@]}：${copies[*]-}）"
if grep -qF "历史噪音 1" "$LOG"; then
    fail "现役日志里还留着历史噪音——轮转没把这一页翻过去"
fi
if ! grep -qF "历史噪音 1" "${copies[0]}"; then
    fail "轮转副本里没有历史噪音（切错了对象？）"
fi
[[ "$(boundary_count "${copies[0]}")" == "1" ]] \
    || fail "上一轮的边界行没跟着轮转副本走（副本里有 $(boundary_count "${copies[0]}") 行）"
[[ "$(boundary_count "$LOG")" == "1" ]] \
    || fail "本轮的 run 边界行没落进现役日志（$(boundary_count "$LOG") 行）"

echo "MONTH-JUMP-OK: 两个 30 天窗口同夜重开 + 真实保留策略下的云端自证 + 轮转 全绿"
