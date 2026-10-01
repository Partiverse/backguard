#!/usr/bin/env bash
# E2E：drill.sh 独立恢复演练入口（隔离 HOME/CONF/仓库/age 密钥，不碰真实配置、不触网）。
# 覆盖：无身份时的失败可见 → 主身份 + 真实 age 密封 + 真实 borg 取回 → 30 天节流。
# 链路刻意用真实产物形态：清单由 bg convert 从 borg list --json-lines 生成，
# 再由 age -R 密封——和 seal_manifest 走的是同一条路，夹具造假会掩盖真问题。
# 用法: ./test_drill_e2e.sh   （需 bash 5、borg、age）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-drill-e2e.XXXXXX)"
trap 'rm -rf "$T"' EXIT   # 失败路径也要清：夹具可能含 age 私钥/解密出的明文账本，不能留在 /tmp
fail() { echo "E2E-FAIL: $1"; exit 1; }
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borgbackup"; exit 0; }
command -v age >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 age"; exit 0; }
command -v age-keygen >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 age-keygen"; exit 0; }

# 设备名带正则元字符（Linux hostname 允许），归档前缀匹配必须是字面量
DEV='web[01]-macos'
CONF="$T/conf/partiverse-backup"
KEYS="$CONF/age"
BASE="$T/repos"
REPO="$BASE/borg-files"
REPO_CONFIG="$BASE/borg-config"
REPO_SYSTEM="$BASE/borg-system"
# 时间轴根下直接是日期树（10-01 去掉设备层）：YYYY/MM/DD/HHMM-标签 共 4 层，
# rescue-test.txt 落在时间轴根，即快照目录上 4 层
SNAP="$BASE/timeline/2026/09/30/0948-morning"
mkdir -p "$KEYS" "$BASE" "$T/home" "$SNAP" \
    "$T/src/Documents" "$T/src/Pictures" "$T/src/config" "$T/src/system-meta"
export BORG_BASE_DIR="$T/.borg"
# 口令刻意不 export 给测试自身之外的环境：它只应通过 secrets.env 进入 drill.sh，
# 由 drill.sh 自己 export——这样 run_drill 的 borg extract 才是在验证真实链路
PASS='drill-e2e-pass'
bpb() { BORG_PASSPHRASE="$PASS" borg "$@"; }

cat > "$CONF/config.sh" <<CFG
export PLATFORM=macos
export DEVICE_ID="$DEV"
export SYSTEM_ID="$DEV"
export BACKUP_BASE="$BASE"
export BORG="$(command -v borg)"
export RCLONE="$(command -v rclone || true)"
CFG
printf "BORG_PASSPHRASE='%s'\n" "$PASS" > "$CONF/secrets.env"
chmod 600 "$CONF/secrets.env"

# age 身份：测试用新生成的密钥（绝不触碰真实 ~/.config/partiverse-backup/age）
# age-keygen 把公钥写在密钥文件的首行注释里，stderr 那句不是机器可读格式
age-keygen -o "$KEYS/identity.txt" >/dev/null 2>&1 || fail "age-keygen 失败"
chmod 600 "$KEYS/identity.txt"
sed -n 's/^# public key: \(age1[0-9a-z]*\).*/\1/p' "$KEYS/identity.txt" > "$KEYS/recipients.txt"
[[ -s "$KEYS/recipients.txt" ]] || fail "取不到公钥: $(head -1 "$KEYS/identity.txt")"

# 真实归档：三类各存自己的子树，路径互不重叠——这是跨类别取回的回归守卫。
# 若三类都塞同一棵树，「拿 files 仓库去解 config 路径」照样能解出来，缺陷就测不出。
# files 侧刻意含空格与中文（抽样取回时引号面必须扛住）
printf 'note-v2\n'      > "$T/src/Documents/note.txt"
printf 'a b c\n'        > "$T/src/Documents/with space.txt"
printf '简历\n'          > "$T/src/Documents/简历.txt"
head -c 4096 /dev/urandom > "$T/src/Pictures/photo.bin"
printf 'cfg=1\n'       > "$T/src/config/app.pref"
printf 'x y\n'         > "$T/src/config/with space.cfg"
head -c 2048 /dev/urandom > "$T/src/system-meta/meta.bin"
bpb init --encryption=repokey "$REPO" >/dev/null 2>&1 || fail "borg init 失败"
bpb init --encryption=repokey "$REPO_CONFIG" >/dev/null 2>&1 || fail "borg init（config）失败"
bpb init --encryption=repokey "$REPO_SYSTEM" >/dev/null 2>&1 || fail "borg init（system）失败"
(cd "$T" && bpb create "$REPO::$DEV-files-20260930-023400" src/Documents src/Pictures >/dev/null 2>&1) \
    || fail "borg create 失败"
(cd "$T" && bpb create "$REPO_CONFIG::$DEV-config-20260930-023400" src/config >/dev/null 2>&1) \
    || fail "borg create（config）失败"
(cd "$T" && bpb create "$REPO_SYSTEM::$DEV-system-20260930-023400" src/system-meta >/dev/null 2>&1) \
    || fail "borg create（system）失败"

# 密封清单（走 semantic.sh seal_manifest 的同一形态：convert → manifest → age -R）
BG="$V0_DIR/semantic/bg_semantic.py"
bpb list --json-lines "$REPO::$DEV-files-20260930-023400" > "$T/files.jsonl" \
    || fail "borg list --json-lines 失败"
bpb list --json-lines "$REPO_CONFIG::$DEV-config-20260930-023400" > "$T/config.jsonl" \
    || fail "borg list --json-lines（config）失败"
bpb list --json-lines "$REPO_SYSTEM::$DEV-system-20260930-023400" > "$T/system.jsonl" \
    || fail "borg list --json-lines（system）失败"
python3 "$BG" convert --engine borg \
    --class files="$T/files.jsonl" --class config="$T/config.jsonl" --class system="$T/system.jsonl" \
    --auto-strip \
    --device "$DEV" --time "2026-09-30T09:48:20" --label morning \
    --out "$T/run.json" >/dev/null || fail "bg convert 失败"
python3 "$BG" manifest --run "$T/run.json" | age -R "$KEYS/recipients.txt" -o "$SNAP/manifest.json.enc" \
    || fail "age 密封失败"
# 明文层不该有清单落进快照目录（隐私红线：完整文件名只进密文账本）
[[ ! -e "$SNAP/manifest.json" ]] || fail "快照目录残留未密封 manifest.json"

# SEM_DRILL_COUNT=99：把整份清单都拉进样本，断言才是「每个危险文件名都被取回过」，
# 而不是「当天日期那个种子碰巧抽到了它」（默认抽样数按日期种子变，测试不能跟着抖）
run_drill_sh() { HOME="$T/home" XDG_CONFIG_HOME="$T/conf" SEM_DRILL_COUNT=99 \
    bash "$V0_DIR/drill.sh" "$@"; }
RT="$BASE/timeline/rescue-test.txt"
# drill.sh 打印的是 cd+pwd 解析后的**物理**路径（macOS 上 /tmp 是 /private/tmp 的软链），
# 夹具同口径归一化，否则「结果见 …」这条断言拿软链去比物理路径，永远差一层
RT="$(cd "$(dirname "$RT")" && pwd)/rescue-test.txt"

# 断言 1：缺主身份时，drill 必须失败可见——不能静默「跳过」后还报成功
mv "$KEYS/identity.txt" "$KEYS/identity.hold"
out="$(run_drill_sh --force 2>&1)" && fail "缺身份却退出 0：$out"
printf '%s' "$out" | grep -q "演练未执行" || fail "缺身份的错误不具体：$out"
[[ ! -e "$RT" ]] || fail "缺身份却写出了 rescue-test.txt"
mv "$KEYS/identity.hold" "$KEYS/identity.txt"

# 断言 1.5：设备还没有 rescue-test.txt 时，不带 --force 也必须真跑
#（节流只该针对「上次演练过」）。回归守卫：drill.sh 曾把 run_drill 调两次，
# 第一次写出 rescue-test.txt 后第二次被自己刚触发的节流挡住，脚本于是打印
# 「本轮被 30 天节流跳过」并退出 0——演练其实跑了，用户读到的是反话。
out="$(run_drill_sh 2>&1)" || fail "首次无 --force 演练退出非零：$out"
printf '%s' "$out" | grep -q "\[drill\] 上次演练不足 30 天" \
    && fail "无 rescue-test.txt 却自称被节流（演练被调用了多次）：$out"
[[ -f "$RT" ]] || fail "首次无 --force 演练未产出 rescue-test.txt: $RT"

# 断言 2：真实演练——主身份解封 → 抽样 → borg 实取 → 大小校验，全部 PASS
out="$(run_drill_sh --force 2>&1)" || fail "drill.sh --force 退出非零：$out"
[[ -f "$RT" ]] || fail "rescue-test.txt 未落在时间轴根（rt 路径算错）: $RT"
# drill.sh 自己算的 rt（快照上 4 层）必须和夹具期望的根是同一个文件：
# 去掉设备层时两边一起上移，相对距离不变——少一层就写到 2026/09/ 里去了
printf '%s' "$out" | grep -qF "结果见 $RT" || fail "drill.sh 的 rt 解析不是时间轴根：$out"
grep -q "^RESULT: 0 PASS" "$RT" && fail "一项都没取回：$RT"
res="$(grep -o '^RESULT: [0-9]* PASS / [0-9]* FAIL' "$RT")" || fail "无 RESULT 行：$(cat "$RT")"
[[ "$res" == *"PASS / 0 FAIL"* ]] || fail "演练有失败项: $res"
n="$(printf '%s' "${res#RESULT: }" | awk '{print $1}')"
# 三类合计 7 个非空文件（files 4 + config 2 + system 1），SEM_DRILL_COUNT=99 → 全量入样
[[ "$n" -eq 7 ]] || fail "应演练 7 个文件，实际 ${n}：$(cat "$RT")"
for tricky in "with space.txt" "简历.txt" "photo.bin" "Documents/note.txt"; do
    grep -q "^PASS .*${tricky}" "$RT" \
        || fail "演练未覆盖或未通过 ${tricky}（引号面/抽样有问题）: $(cat "$RT")"
done
# 跨类别取回守卫：bg sample 是按类别占比抽样的，config/system 的样本必须从
# 各自的仓库取回。曾经 run_drill 只拿到 files 仓库，这两类 100% 报假失败，
# 而 30 天节流让它在生产上从未露头（真机 10-01 首次 --force 才抓到）
for cls in config system; do
    grep -q "^PASS \[$cls\] " "$RT" \
        || fail "[$cls] 类样本一条 PASS 都没有——取回用的仓库写死成 files 了：$(cat "$RT")"
done
grep -q "^PASS \[config\] .*app.pref" "$RT" \
    || fail "config 的 app.pref 未经由 config 仓库取回：$(cat "$RT")"

# 断言 3：不带 --force 时 30 天节流生效（上一步刚写过 rescue-test.txt，不应重写）
before="$(md5 -q "$RT" 2>/dev/null || cksum "$RT" | tr -d ' ')"
out="$(run_drill_sh 2>&1)" || fail "节流路径退出非零：$out"
printf '%s' "$out" | grep -q "不足 30 天" || fail "节流未生效：$out"
after="$(md5 -q "$RT" 2>/dev/null || cksum "$RT" | tr -d ' ')"
[[ "$before" == "$after" ]] || fail "节流仍改写了 rescue-test.txt"

# 断言 3.5：rescue-test.txt 已存在但本轮缺主身份（密钥目录指到空处）时，
# 必须按 rc=20 报「未执行」，而不是拿陈旧文件判「通过」——
# 秒级 mtime 分不开陈旧文件与刚写的文件，所以判定走退出码而非文件考古
mkdir -p "$T/empty-keys"
out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/conf" SEM_KEYS_DIR="$T/empty-keys" \
      bash "$V0_DIR/drill.sh" --force 2>&1)" && fail "密钥目录指空处却报成功：$out"
printf '%s' "$out" | grep -q "演练未执行" || fail "陈旧结果被当成通过：$out"

# 断言 4：指定 --snapshot 时不需要自动发现；快照不存在必须报错而非静默
out="$(run_drill_sh --snapshot "$SNAP" --force 2>&1)" || fail "--snapshot 显式路径失败：$out"
out="$(run_drill_sh --snapshot "$BASE/timeline/1999/01/01/0000-night" 2>&1)" \
    && fail "不存在的快照目录却成功了"
printf '%s' "$out" | grep -q "快照目录不存在" || fail "快照不存在的报错不具体：$out"

# 断言 5：结论判定函数本身——历史判定式 grep 'RESULT: .*FAIL' 会匹配到汇总行里的
# 「0 FAIL」，全通过也报失败；30 天节流让这个假告警一直没在生产上露头
log(){ :; }; info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }
source "$V0_DIR/semantic/semantic.sh"
declare -F drill_has_failure >/dev/null || fail "drill_has_failure 未定义（判定仍是内联 grep）"
mkrt() { printf '%s\n' "$@" > "$T/rt.txt"; }
mkrt "# 恢复演练 rescue-test" "PASS [files] a.txt (8 B)" "RESULT: 4 PASS / 0 FAIL（抽样 4）"
drill_has_failure "$T/rt.txt" && fail "全通过被判成有失败项"
mkrt "PASS [files] a.txt (8 B)" "FAIL [files] b.txt（取回或大小不符）" "RESULT: 1 PASS / 1 FAIL（抽样 2）"
drill_has_failure "$T/rt.txt" || fail "逐条 FAIL 却判成通过"
mkrt "RESULT: FAIL（manifest 解封失败）"
drill_has_failure "$T/rt.txt" || fail "解封失败却判成通过"
mkrt "RESULT: 3 PASS / 2 FAIL（抽样 5）"
drill_has_failure "$T/rt.txt" || fail "FAIL 计数非零却判成通过"
mkrt "PASS [files] a.txt (8 B)"
drill_has_failure "$T/rt.txt" || fail "无结论行必须判失败（宁可误报不可漏报）"

echo "E2E-OK: drill.sh 独立入口（缺身份失败可见 / 真实解封+实取+校验 / 30 天节流 / --snapshot 两条路径 / 结论判定不误报）"
