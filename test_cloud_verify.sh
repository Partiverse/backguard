#!/usr/bin/env bash
# E2E：云端可信副本的清单级自证（research/11 A6 L1）。
# 动机是 10-01 的真机缺陷：这条 remote 上 rclone 的比较退化成「只比大小」，borg 换口令后
# 三个 config 从 700 B 变成 700 B，nightly 报「同步完成」，云端躺着的仍是轮换前那份。
# 也就是说 `rclone copy` 的退出码只证明「rclone 没报错」，不证明「云端有新版」。
# 断言面：
#   1) 全绿轮：CLOUD-VERIFY.txt 在时间轴根、0 FAIL、退出 0，且三类仓库各自都在被校验；
#   2) 云端多出本地已裁的历史副本 → 仍判绿（单向包含，云端只增不减是设计不是缺陷）；
#   3) 同长度改写云端 config（rclone 看不见的那种）→ 内容哈希发现 → 当场 forcing 补传 →
#      记 HEALED 且**独立复核云端内容真与本地一致**（不能只信 rclone 的退出码）；
#   4) 云端残留 rescue-test.txt（推送挡不住既有副本，只有自证看得见）→ 隐私红线 FAIL；
#   5a) 本地有 rescue-test.txt（演练产物，红线规定只留本地）→ 对平不得因此假报云端少一份，
#       隐私检查也不得被连带弄瞎；上一轮的报告必须已随时间轴上云；
#   5b) 网盘读不出对象 → UNKNOWN：既不算证成也不算证败，不改退出码
#       （把 flake 报成 FAIL 会让告警通道失去信任，观察期尤其致命）；
#   6) 网盘清单本身撒谎（少一份 / 尺寸不符）→ 两种不一致分开计数 + 退出非零；
#      差异样本只到目录，**报告里不得出现任何文件名**（它是明文产物且随下轮上云，红线 §1.1）；
#   7) forcing 之后**复核读到的内容**仍与本地不符 → FAIL + 退出非零。这一档锁的是
#      「HEALED 只能由重新读过的内容换来」——`rclone copy` 退出 0 从来不算证据（§1.4）。
# 用法: ./test_cloud_verify.sh   （需 bash 4 + borg + rclone；rclone 用 local 后端，不触网）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borg，未测"; exit 0; }
command -v rclone >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 rclone，未测"; exit 0; }

T="$(mktemp -d /tmp/bg-cverify.XXXXXX)"
# chmod 兜底：5b 会造 000 文件，失败路径也必须删得掉夹具（夹具含 borg 仓库，AGENTS §3）
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log" 2>/dev/null || true; exit 1; }

mkdir -p "$T/src" "$T/conf/partiverse-backup" "$T/home" "$T/dest"
echo hello > "$T/src/a.txt"
printf '[pftarget]\ntype = local\n' > "$T/rclone.conf"

cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Mac"
export SYSTEM_ID="E2E-Mac"
export BACKUP_BASE="$T/repos"
export RCLONE="$(command -v rclone)"
export BORG="$(command -v borg)"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=("pftarget:backup-mac")
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src")
BORG_EXCLUDES_system=()
CONF
echo "BORG_PASSPHRASE='e2e-pass'" > "$T/conf/partiverse-backup/secrets.env"
chmod 600 "$T/conf/partiverse-backup/secrets.env"

CLOUD="$T/dest/backup-mac/E2E-Mac"
REPORT="$T/repos/timeline/CLOUD-VERIFY.txt"

# 一轮真实备份：local 后端的根就是 cwd，所以整轮在 $T/dest 里跑
run_backup() { (
    cd "$T/dest"
    # ${1:-}：set -u 下无参调用是致命变量错误（AGENTS §2 同一条坑）
    # shellcheck disable=SC2086  # 分词是有意的：把 $1 当多个 KEY=VAL 传进 env
    env SKIP_WEBDAV=0 SEM_DRILL=0 XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" \
        HOME="$T/home" ${1:-} bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
); }

# 报告的行形状是 `STATUS 名称(补齐 30 列) 详情`，名称里带空格，所以只能按
# 「首字段 + 名称 + 空格」匹配，不能按列切
status_of() {  # $1=检查名（前缀匹配）
    { grep -E "^[A-Z]+ +$1 " "$REPORT" 2>/dev/null || true; } | awk '{print $1; exit}'
}
summary_field() {  # $1=字段名（FAIL / UNKNOWN / HEALED / checks）
    grep -o "$1=[0-9]*" "$REPORT" | head -1 | cut -d= -f2
}
# 独立复核用的哈希：macOS 无 sha256sum、Linux 无 shasum，两个都探一次
hash_of() {  # $1=文件
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1"
    else
        shasum -a 256 < "$1"
    fi | cut -d' ' -f1
}

# ---------- 1：全绿轮 ----------
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 1 轮退出非零（rc=${rc}）：$(tail -15 "$T/out.log")"
[ -f "$REPORT" ] || fail "CLOUD-VERIFY.txt 没落在时间轴根（本地暂存根 = BACKUP_BASE 下的 timeline）"
[[ "$(summary_field FAIL)" == "0" ]] || fail "全绿轮却有 FAIL：$(grep -v '^#' "$REPORT")"
for name in "timeline @" "repo:config @" "repo:files @" "repo:system @" \
            "config:config @" "config:files @" "config:system @"; do
    [[ "$(status_of "$name")" == "PASS" ]] \
        || fail "检查「${name}」没跑或没通过（实际：$(status_of "$name")）：$(grep -v '^#' "$REPORT")"
done

# ---------- 2：云端多出一份本地已裁的历史副本 → 仍判绿 ----------
# 生产里这是 borg prune / SEM_TIMELINE_KEEP 的正常后果：本地删掉的老快照仍全量躺在云上。
# 若把对平成「双向相等」，每晚都会假报一次「云端和本地不一样」。
# 种子与生产同形：时间轴根下面直接是日期树（AGENTS §2「时间轴没有设备层」），
# 路径按段拼——日期分隔符在转录里会被显示成连字符，拼出来才可靠。
SLASH="/"
PLANTED="$CLOUD/timeline"
for seg in 2020 01 01 0234-old; do PLANTED="$PLANTED$SLASH$seg"; done
mkdir -p "$PLANTED"
echo "上一轮之前就被本地裁掉的快照" > "$PLANTED${SLASH}MANIFEST.txt"
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "云端多出历史副本被判失败（单向包含口径没落地，rc=${rc}）：$(grep -v '^#' "$REPORT")"
[[ "$(summary_field FAIL)" == "0" ]] || fail "云端多出的历史副本造成 FAIL：$(grep -v '^#' "$REPORT")"
if ! grep -qE 'PASS +timeline @ .*云端另有 [0-9]+ 份' "$REPORT"; then
    fail "报告没写出「云端另有 N 份本地已裁的副本」——多出来这件事得让读的人看见：$(grep 'timeline @' "$REPORT")"
fi

# ---------- 3：同长度改写云端 config（rclone 的「只比大小」看不见的那种）----------
# 10-01 真机：轮换口令后 config 700 B → 700 B，copy 报成功、云端还是旧 key blob。
# 夹具复刻：内容与本地等长但不同，再把 mtime 对齐——rclone 判定「两端一致」直接跳过，
# 于是这一轮的推送环节不会把它修好，只有 config 的内容哈希能发现。
cfg_local="$T/repos/borg-files/config"
cfg_cloud="$CLOUD/files/config"
[ -f "$cfg_cloud" ] || fail "夹具：云端没有 files/config"
cfg_size="$(wc -c < "$cfg_local")"
cfg_size="${cfg_size// /}"     # BSD/GNU 的 wc 都可能带前导空格，head -c 只认纯数字
head -c "$cfg_size" /dev/urandom > "$T/config.tampered"
cp "$T/config.tampered" "$cfg_cloud"
touch -r "$cfg_local" "$cfg_cloud"
rc=0; run_backup || rc=$?
# 不一致里有一类是能**当场修好**的：同长度重写永远不会被推送带走，但显式 forcing 可以。
# 所以这一轮的期望是「修好并留痕」而不是「报警退出」——云端真的对上以后就没可信度问题了。
[[ $rc -eq 0 ]] || fail "云端 config 的同长度改写应被当场强制补传修好（rc=${rc}）：$(grep -v '^#' "$REPORT")"
[[ "$(status_of "config:files @")" == "HEALED" ]] \
    || fail "config:files 没记 HEALED（实际：$(status_of "config:files @")）：$(grep 'config:files' "$REPORT")"
[[ "$(summary_field HEALED)" == "1" ]] || fail "HEALED 没落进汇总：$(grep '汇总' "$REPORT")"
[[ "$(summary_field FAIL)" == "0" ]] || fail "已经修好的不一致仍算失败：$(grep -v '^#' "$REPORT")"
# 「修好了」不能只信 rclone 的退出码——这正是 10-01 那次翻车的地方，必须自己比内容
cloud_hash="$(hash_of "$cfg_cloud")"
local_hash="$(hash_of "$cfg_local")"
[[ "$cloud_hash" == "$local_hash" ]] \
    || fail "报告说补传好了，云端 config 却还是另一份（${cloud_hash:0:12}… ≠ ${local_hash:0:12}…）"
grep -q '强制补传' "$REPORT" || fail "报告没写明是哪一次动作修好的，读的人无从判断"
if ! grep -q '强制补传' "$T/out.log"; then
    fail "stdout 没有 HEALED 的 warn 行——自修也得留痕，否则「云端曾躺着一份陈旧 key blob」这件事没人知道"
fi

# ---------- 4：云端残留 rescue-test.txt → 隐私红线 FAIL ----------
# 推送环节的 --exclude 只挡**新**副本，10-01 真机上那条老副本就是这么留下的。
restore_cloud_config() {
    cp "$cfg_local" "$cfg_cloud"
    touch -r "$cfg_local" "$cfg_cloud"
}
restore_cloud_config
echo "PASS [files] Users/me/Documents/秘密.doc (1 B)" > "$CLOUD/timeline/rescue-test.txt"
rc=0; run_backup || rc=$?
# 先认定「哪一条检查抓到了它」，再认定「这件事改了退出码」——顺序反过来时，隐私检查被摘掉
# 与 FAIL 不落退出码两种坏法会报同一句话，读的人分不清坏在哪一步（变异测试就是这么露馅的）
[[ "$(status_of "privacy @")" == "FAIL" ]] \
    || fail "privacy 检查没判 FAIL（实际：$(status_of "privacy @")）：$(grep -i 'rescue-test' "$REPORT")"
[[ $rc -ne 0 ]] || fail "云端有 rescue-test.txt（带完整文件名）却仍算通过"

# ---------- 5a：本地演练产物不得污染对平，也不得弄瞎隐私检查 ----------
restore_cloud_config
rm -f "$CLOUD/timeline/rescue-test.txt"
# 真机上时间轴根**一定**有 rescue-test.txt（CI 与本机都带 age 密钥跑演练）。它在本地而不在
# 云端是红线 §1.1 的设计，所以清单对平必须把它摘掉——否则每晚都假报「云端少一份」。
echo "PASS [files] 本地演练产物" > "$T/repos/timeline/rescue-test.txt"
rc=0; run_backup || rc=$?
# 这一段的两条主张各有一个专属变异，谁先谁后决定了报错说不说真话：云端真多了那份文件时，
# 必须先说「漏推上云了」（红线 §1.1），不能让下一句「假报云端缺对象」顶在前面误导人
if [ -e "$CLOUD/timeline/rescue-test.txt" ]; then
    fail "本地那份 rescue-test.txt 被 --exclude 漏过、推上云了（红线 §1.1）"
fi
[[ $rc -eq 0 ]] || fail "本地有 rescue-test.txt 就假报云端缺对象（对平里的摘除没落地，rc=${rc}）：$(grep -v '^#' "$REPORT")"
[[ "$(summary_field FAIL)" == "0" ]] || fail "本地演练产物造成 FAIL：$(grep -v '^#' "$REPORT")"
[[ "$(summary_field UNKNOWN)" == "0" ]] || fail "干净环境的基线就该是 0 UNKNOWN（实为 $(summary_field UNKNOWN)）"
[[ "$(status_of "privacy @")" == "PASS" ]] \
    || fail "对平的摘除把隐私检查一起弄瞎了（实际：$(status_of "privacy @")）"
# 报告头写着「本文件随下一轮时间轴推送上云」——这句口径必须是真的，否则云端永远看不到
# 自证结论，异机排查的人只能看见一个没有下文的目录
[ -f "$CLOUD/timeline/CLOUD-VERIFY.txt" ] \
    || fail "上一轮的 CLOUD-VERIFY.txt 没随时间轴上云（报告头那句口径是假的）"

# ---------- 5b：网盘读不出对象 → UNKNOWN，不改退出码 ----------
# root 下 chmod 000 挡不住读（与 test_cloud_failure.sh / test_log_rotation.sh 同一守卫）：
# 只跳这一段，前面各段与身份无关，照跑照断言。
if [[ "$(id -u)" == 0 ]]; then
    echo "NOTE: UNKNOWN 段需非 root 才能注入只读，本次未测"
    ph_unknown="未测(root)"
else
    chmod 000 "$cfg_cloud"      # 清单读得到、内容读不出：正是网盘抖动的形状
    rc=0; run_backup || rc=$?
    chmod 644 "$cfg_cloud"
    [[ $rc -eq 0 ]] || fail "UNKNOWN 项把备份拖成非零退出（flake 不该等于失败，rc=${rc}）"
    [[ "$(status_of "config:files @")" == "UNKNOWN" ]] \
        || fail "云端 config 读不出时没记 UNKNOWN（实际：$(status_of "config:files @")）"
    [[ "$(summary_field FAIL)" == "0" ]] || fail "UNKNOWN 被算进了 FAIL：$(grep -v '^#' "$REPORT")"
    if ! grep -q 'UNKNOWN' "$T/out.log"; then
        fail "stdout 没打 UNKNOWN 告警——报告文件是给机器读的，人当场得看见「这一轮没证成」"
    fi
    ph_unknown="已测"
fi


# ---------- 6：网盘清单本身撒谎（少一份 + 尺寸不符）→ 分开计数 ----------
# 桩：转发真实 rclone，只在 lsl 的输出上动手——抹掉一行（少一份）、某行尺寸 +1（尺寸不符）。
# 为什么只能拿桩测：真实的「云端少一份」下一轮 push 就自愈，而自证要防的是**宣称成功的那
# 一轮**就已经不一致（10-01 的 config 正是这一类，只不过它同尺寸、清单看不见）。
mkdir -p "$T/bin"
cat > "$T/bin/rclone" <<'STUB'
#!/usr/bin/env bash
# 只伪造 lsl / cat；其余子命令原样转发，推送与补传环节照旧真跑
if [[ "${1:-}" == "lsl" ]]; then
    out="$("$CV_REAL" "$@")" || true
    [[ -z "${CV_HIDE:-}" ]] || out="$(printf '%s\n' "$out" | { grep -vF "$CV_HIDE" || true; })"
    [[ -z "${CV_BADSIZE:-}" ]] || out="$(printf '%s\n' "$out" | awk -v b="$CV_BADSIZE" '{ if (index($0,b)) $1=$1+1; print }')"
    printf '%s\n' "$out"
    exit 0
fi
if [[ "${1:-}" == "cat" && -n "${CV_FAKE_CAT:-}" && "$2" == *"$CV_FAKE_CAT"* ]]; then
    head -c "${CV_FAKE_LEN:-64}" /dev/urandom
    exit 0
fi
exec "$CV_REAL" "$@"
STUB
chmod 755 "$T/bin/rclone"
# 靶子必须是**本地清单里真有、且这一轮真推上了云**的产物：时间轴根的 profile.json 由
# init.sh 写（夹具不跑向导，没这件），所以自己往最新快照里放一份，再取一份现成产物。
# 放的那份刻意用**像用户文件的文件名**——报告是明文产物且随下一轮上云，红线 §1.1 要在这里
# 当场证明它只到目录为止。名字不带空格：env 传参走分词（本文件 run_backup 那条注释）。
tl_root="$T/repos/timeline"
restore_abs="$(find "$tl_root" -type f -name 'restore.md' | LC_ALL=C sort | tail -1)"
bad_abs="$(find "$tl_root" -type f -name 'COVERAGE.txt' | LC_ALL=C sort | tail -1)"
[[ -n "$restore_abs" && -n "$bad_abs" ]] || fail "夹具：时间轴里没有 restore.md / COVERAGE.txt，清单造假没有靶子"
plant_base="秘密-王峭楠-简历.doc"
plant_abs="$(dirname "$restore_abs")/$plant_base"
echo "一个像用户文件的名字" > "$plant_abs"
hide_rel="${plant_abs#"$tl_root"/}"
bad_rel="${bad_abs#"$tl_root"/}"
[[ "$hide_rel" != "$bad_rel" ]] || fail "夹具：两个靶子撞在同一行上，两种不一致就没法分开计数了"
hide_dir="${hide_rel%/*}"
[[ "$hide_dir" != "$hide_rel" ]] || fail "夹具：靶子文件在时间轴根级，目录样本会退化成「根级」而测不出泄漏"
# 把 config.sh 里的 RCLONE 指向桩：backup.sh 用的是配置里那个绝对路径，改 PATH 没用
sed -e "s#^export RCLONE=.*#export RCLONE=\"$T/bin/rclone\"#" \
    "$T/conf/partiverse-backup/config.sh" > "$T/conf/config.tmp" \
    && mv "$T/conf/config.tmp" "$T/conf/partiverse-backup/config.sh"
rc=0; run_backup "CV_REAL=$(command -v rclone) CV_HIDE=$hide_rel CV_BADSIZE=$bad_rel" || rc=$?
[[ $rc -ne 0 ]] || fail "云端清单少一份 + 尺寸不符，仍宣布 FULLY COMPLETE"
[[ "$(status_of "timeline @")" == "FAIL" ]] \
    || fail "timeline 对平没判 FAIL（实际：$(status_of "timeline @")）：$(grep 'timeline @' "$REPORT")"
# 只该有 timeline 这一条 FAIL：桩只动 lsl，仓库前缀的清单里没有这两个路径，不该被牵连
[[ "$(summary_field FAIL)" == "1" ]] \
    || fail "两种不一致牵连到了别的检查（汇总应为 1 条 FAIL）：$(grep -v '^#' "$REPORT")"
if ! grep -qE '云端缺 1 个 / 尺寸不符 1 个' "$REPORT"; then
    fail "报告没把两种不一致分开计数（缺 / 尺寸不符），失败了也分不清是哪种：$(grep 'timeline @' "$REPORT")"
fi
# 报告要指名差异**在哪棵子树**（否则失败了无从下手），但一个字节的文件名都不能带：
# 这份报告随时间轴推上网盘，裸文件管理器打开就能看见「你有哪些文件」——红线 §1.1 的例外
# 只有 rescue-test.txt 一个，而它只留本地。被校验的两棵树今天恰好都是系统生成的名字，
# 所以这条断言现在咬不住任何真实泄漏，它防的是**将来**把校验面扩到 system-meta/ 那天。
grep -qF "$hide_dir" "$REPORT" \
    || fail "报告的差异样本没指名那个被抹掉的对象所在目录：$(grep 'timeline @' "$REPORT")"
if grep -qF "$plant_base" "$REPORT"; then
    fail "报告的差异样本把对象名写全了（明文产物带完整文件名，红线 §1.1）：$(grep 'timeline @' "$REPORT")"
fi

# ---------- 7：forcing 之后复核仍不一致 → FAIL（HEALED 只能由内容换来）----------
# 桩只伪造 cat：这一次补传**真的**把本地 config 推上去了（copy 退出 0、落盘内容也对），
# 但自证读回来的仍不是那一份——网盘答非所问的形状。若把 HEALED 记在 copy 的退出码上，
# 等于退回 10-01 那个坑：「rclone 没报错」被当成「云端有新版」。
# 为什么不用 chmod 444 造「云端写不进去」：rclone 默认非原地写（目标目录建临时文件再
# rename），只读的那个小文件本身挡不住替换——实测反而把不一致修好了，假 FAIL。
rc=0; run_backup "CV_REAL=$(command -v rclone) CV_FAKE_CAT=files/config" || rc=$?
[[ "$(status_of "config:files @")" == "FAIL" ]] \
    || fail "forcing 后复核不一致没判 FAIL（实际：$(status_of "config:files @")）：$(grep 'config:files' "$REPORT")"
[[ $rc -ne 0 ]] || fail "云端 config 复核仍对不上，却宣布 FULLY COMPLETE（补传退出 0 被当成了证据）"
[[ "$(summary_field HEALED)" == "0" ]] \
    || fail "没把一致的内容读回来却记了 HEALED：$(grep 'config:files' "$REPORT")"
[[ "$(summary_field FAIL)" == "1" ]] \
    || fail "桩只动了 files 的 cat，别的不该被牵连（汇总应为 1 条 FAIL）：$(grep -v '^#' "$REPORT")"
grep -q '强制补传' "$REPORT" \
    || fail "FAIL 详情没写出这是补传之后仍不一致，读的人无从判断还剩几步：$(grep 'config:files' "$REPORT")"
grep -q '云端副本自证' "$T/out.log" \
    || fail "stdout 没有自证失败的 error 行（launchd / CI 只看退出码就不知道原因）"

echo "E2E-OK: 云端自证（全绿轮三类仓库+config 哈希全 PASS / 单向包含不因 prune 假报 / 同长度改写被内容哈希抓住并当场强制补传修好、记 HEALED 且云端内容真与本地一致 / 云端 rescue-test.txt 残留判隐私失败 / 本地演练产物不污染对平也不弄瞎隐私检查、报告随下一轮上云 / 网盘读不出记 UNKNOWN 不改退出码：${ph_unknown} / 清单少一份与尺寸不符分开计数、差异样本只到目录不带文件名 / 补传后复核仍不一致判 FAIL、HEALED 不认 copy 退出码）"
