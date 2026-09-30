#!/usr/bin/env bash
# E2E：rescue.sh 逃生恢复单文件脚本（隔离临时目录，不碰真实配置、不触网、不碰真实密钥）。
# 刻意走真实产物形态：borg 真实归档 + bg convert/manifest + age 真实密封，
# restic 分支走「云端副本布局」(<base>/<cls>) 与自动引擎判定。
# 用法: ./test_rescue_e2e.sh   （需 bash 5、borg、age；restic/expect 缺失时对应断言跳过）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-rescue-e2e.XXXXXX)"
trap 'rm -rf "$T"' EXIT   # 失败路径也要清：夹具可能含 age 私钥/解密出的明文账本，不能留在 /tmp
fail() { echo "E2E-FAIL: $1"; exit 1; }
# 可选依赖缺哪块就把块名记进来，末行如实标注——「E2E-OK」不能宣称跑过的比实际多
SKIPPED=""
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borgbackup"; exit 0; }
command -v age >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 age"; exit 0; }

DEV='web[01]-macos'          # 设备名带正则元字符：前缀匹配必须按字面量
BASE="$T/local"              # 本机布局：<base>/borg-<cls> + <base>/timeline/<dev>/…
# 真实布局是 4 层：<dev>/YYYY/MM/DD/HHMM-标签（写成 2026-09-30 会让 --ledger 找不到快照）
SNAP="$BASE/timeline/$DEV/2026/09/30/0948-morning"
KEYS="$T/keys"
mkdir -p "$BASE" "$SNAP" "$KEYS" "$T/src/Documents" "$T/src/Pictures"
export BORG_BASE_DIR="$T/.borg" BORG_PASSPHRASE='rescue-e2e-pass'
bpb() { borg "$@"; }

# 两个归档（名字序即时间序），内容有意不同；危险文件名扛住引号面
printf 'v1\n' > "$T/src/Documents/note.txt"
printf 'a b c\n' > "$T/src/Documents/with space.txt"
printf '简历一\n' > "$T/src/Documents/简历.txt"
head -c 2048 /dev/urandom > "$T/src/Pictures/photo.bin"
bpb init --encryption=repokey "$BASE/borg-files" >/dev/null 2>&1 || fail "borg init 失败"
(cd "$T" && bpb create "$BASE/borg-files::$DEV-files-20260929-023400" src >/dev/null 2>&1) || fail "borg create 1 失败"
printf 'v2\n' > "$T/src/Documents/note.txt"
(cd "$T" && bpb create "$BASE/borg-files::$DEV-files-20260930-023400" src >/dev/null 2>&1) || fail "borg create 2 失败"

# 真实密封账本（与 seal_manifest 同一条路：convert → manifest → age -R）
BG="$V0_DIR/semantic/bg_semantic.py"
age-keygen -o "$KEYS/identity.txt" >/dev/null 2>&1 || fail "age-keygen 失败"
sed -n 's/^# public key: \(age1[0-9a-z]*\).*/\1/p' "$KEYS/identity.txt" > "$KEYS/recipients.txt"
[[ -s "$KEYS/recipients.txt" ]] || fail "取不到公钥"
bpb list --json-lines "$BASE/borg-files::$DEV-files-20260930-023400" > "$T/files.jsonl" \
    || fail "borg list --json-lines 失败"
python3 "$BG" convert --engine borg --class files="$T/files.jsonl" --auto-strip \
    --device "$DEV" --time "2026-09-30T09:48:20" --label morning --out "$T/run.json" >/dev/null \
    || fail "bg convert 失败"
python3 "$BG" manifest --run "$T/run.json" | age -R "$KEYS/recipients.txt" -o "$SNAP/manifest.json.enc" \
    || fail "age 密封失败"

rescue() { HOME="$T/home" bash "$V0_DIR/rescue.sh" "$@"; }
mkdir -p "$T/home"

# 断言 1：--guide 不依赖任何目录（新机器第一步就能读）
out="$(HOME="$T/home" bash "$V0_DIR/rescue.sh" --guide)" || fail "--guide 退出非零"
printf '%s' "$out" | grep -q "recovery-identity.enc" || fail "--guide 未交代恢复材料: $out"

# 断言 2：--list 认出本机布局的两个归档 + 时间轴设备目录
out="$(rescue --base "$BASE" --list)" || fail "--list 退出非零：$out"
# 设备名带 [01]：断言一律字面量匹配（同 rescue.sh 内部的 awk index 口径）
printf '%s' "$out" | grep -qF -- "$DEV-files-20260930-023400" || fail "--list 未列最新归档：$out"
printf '%s' "$out" | grep -qF -- "$DEV-files-20260929-023400" || fail "--list 未列历史归档：$out"
printf '%s' "$out" | grep -q "\[files\].*2 个归档" || fail "--list 归档计数不对：$out"
printf '%s' "$out" | grep -qF -- "  $DEV" || fail "--list 未列时间轴设备目录：$out"

# 断言 3：--find 字面量匹配（空格/中文名必须原样列出，供 --get 复制）
find_out="$(rescue --base "$BASE" --class files --find Documents)" || fail "--find 退出非零：$find_out"
for want in "Documents/note.txt" "Documents/with space.txt" "Documents/简历.txt"; do
    printf '%s' "$find_out" | grep -qF -- "$want" || fail "--find 少了 ${want}：${find_out}"
done
out="$(rescue --base "$BASE" --class files --find 一定没有的名字)" || fail "--find 无匹配却非零：$out"
printf '%s' "$out" | grep -q "无匹配" || fail "--find 无匹配的话术缺失：$out"
# 断言 4：--get 用的路径就照抄 --find 的输出（归档内前缀由 create 的工作目录决定，
# 真实备份是 /，这里是夹具的 src/——脚本不该假设前缀）
p_space="$(printf '%s' "$find_out" | grep -F 'with space.txt' | head -1)"
p_note="$(printf '%s' "$find_out" | grep -F 'note.txt' | head -1)"
[[ -n "$p_space" && -n "$p_note" ]] || fail "--find 输出不可复制为取回路径：$find_out"
rescue --base "$BASE" --class files --get "$p_space" --to "$T/out-latest" \
    >"$T/g1.log" 2>&1 || fail "--get 失败：$(tail -3 "$T/g1.log")"
[ "$(find "$T/out-latest" -type f -name 'with space.txt' -exec cat {} \; 2>/dev/null)" = "a b c" ] \
    || fail "--get 内容不对: $(find "$T/out-latest" -type f | head -3)"
rescue --base "$BASE" --class files --get "$p_note" --to "$T/out-v2" >/dev/null 2>&1 \
    || fail "--get note.txt 失败"
[ "$(cat "$T/out-v2/${p_note}")" = "v2" ] || fail "--get 未取到最新内容"

# 断言 5：--archive 取历史快照（note.txt 回到 v1）
rescue --base "$BASE" --class files --archive "$DEV-files-20260929-023400" \
    --get "$p_note" --to "$T/out-v1" >/dev/null 2>&1 || fail "--archive 历史取回失败"
[ "$(cat "$T/out-v1/${p_note}")" = "v1" ] || fail "--archive 未取到指定快照内容"

# 断言 6：路径写错不能静默「成功」——归档能开、一个文件没落地必须报错
#（borg 1.4 对不匹配的 include 直接 rc=1；脚本自己的兜底是 restic 那条路）
out="$(rescue --base "$BASE" --class files --get "Documents/note-typo.txt" --to "$T/out-bad" 2>&1)" \
    && fail "路径不存在却报成功：$out"
printf '%s' "$out" | grep -qE "borg extract 失败|没有取回任何文件" || fail "空取回的报错不具体：$out"
[[ -z "$(find "$T/out-bad" -type f)" ]] || fail "路径不存在却落了文件: $(find "$T/out-bad" -type f | head -2)"

# 断言 7：账本路径 A（主身份）——跨档案查询给类别/大小/归档内取回路径
out="$(rescue --base "$BASE" --ledger --identity "$KEYS/identity.txt")" || fail "--ledger 主身份失败：$out"
printf '%s' "$out" | grep -q "\[files\]" || fail "账本未标类别：$out"
printf '%s' "$out" | grep -q "photo.bin" || fail "账本未列 photo.bin：$out"
printf '%s' "$out" | grep -q "取回: src/Pictures/photo.bin" \
    || fail "账本给的取回路径不是归档内 raw：$out"
# 隐私红线：查询用完，明文清单不得留在快照目录
[[ ! -e "$SNAP/manifest.json" ]] || fail "明文 manifest.json 落在了快照目录"

# 断言 8：账本按关键词过滤 + 缺恢复材料必须失败可见
out="$(rescue --base "$BASE" --ledger --identity "$KEYS/identity.txt" --find 简历)" \
    || fail "--ledger --find 失败：$out"
printf '%s' "$out" | grep -q "简历.txt" || fail "--ledger --find 未命中：$out"
printf '%s' "$out" | grep -qF "photo.bin" && fail "--ledger --find 过滤没生效：$out"
out="$(rescue --base "$BASE" --ledger 2>&1)" && fail "缺恢复材料却退出 0：$out"
printf '%s' "$out" | grep -q "需要恢复材料" || fail "缺恢复材料的报错不具体：$out"

# 断言 9：路径 B（只有恢复码）——age 只读 /dev/tty，必须由 expect 驱动伪终端
#（与 init-keys.exp 同一口径；没装 expect 就跳过这条）
if command -v expect >/dev/null 2>&1; then
    tmp_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'bg-rescue.*' 2>/dev/null | grep -c . || true)"
    export BG_RCODE='rescue-e2e-recovery-code'
    export BG_REC_RAW="$T/recovery-identity.txt"
    export BG_REC_ENC="$KEYS/recovery-identity.enc"
    age-keygen -o "$BG_REC_RAW" >/dev/null 2>&1 || fail "生成救援身份失败"
    # 真实密封流程里两个 recipient 一起写：救援身份的公钥必须进 recipients.txt
    age-keygen -y "$BG_REC_RAW" >> "$KEYS/recipients.txt"
    python3 "$BG" manifest --run "$T/run.json" | age -R "$KEYS/recipients.txt" -o "$SNAP/manifest.json.enc" \
        || fail "按双 recipient 重新密封失败"
    # age -p 的提示是「Enter passphrase …」+「Confirm passphrase:」，先匹配 confirm。
    # expect 脚本落文件再用 -f 跑：把 heredoc 塞进 $( ) 会让 bash 报
    # "unterminated here-document"，喂给 age 的内容是否完整就成了运气
    cat > "$T/exp-wrap.exp" <<'EXP'
set timeout 20
log_user 0
spawn age -p -o $env(BG_REC_ENC) $env(BG_REC_RAW)
expect {
    -re "(?i)confirm"    { send -- "$env(BG_RCODE)\r"; exp_continue }
    -re "(?i)passphrase" { send -- "$env(BG_RCODE)\r"; exp_continue }
    eof                  { }
    timeout              { exit 1 }
}
catch wait result
exit [lindex $result 3]
EXP
    expect -f "$T/exp-wrap.exp" >/dev/null 2>&1 || fail "age -p 包裹救援身份失败"
    rm -f "$BG_REC_RAW"        # 明文私钥用完即删

    cat > "$T/exp-rescue.exp" <<'EXP'
set timeout 60
log_user 1
spawn bash $env(BG_RESCUE) --base $env(BG_BASE) --ledger --recovery $env(BG_REC_ENC)
expect {
    -re "(?i)passphrase" { send -- "$env(BG_RCODE)\r"; exp_continue }
    eof                  { }
    timeout              { puts "\n>>TIMEOUT"; exit 1 }
}
catch wait result
# 把 rescue.sh 的退出码转述给外层 shell（expect 自身退出码没意义）
if { [lindex $result 3] == 0 } { exit 0 } else { exit 2 }
EXP
    export BG_RESCUE="$V0_DIR/rescue.sh" BG_BASE="$BASE"
    out="$(HOME="$T/home" expect -f "$T/exp-rescue.exp" 2>&1)" \
        || fail "恢复码路径退出非零：$out"
    printf '%s' "$out" | grep -q "photo.bin" || fail "恢复码路径没解到账本：$(printf '%s' "$out" | tail -5)"
    printf '%s' "$out" | grep -q "取回: src/Pictures/photo.bin" || fail "恢复码路径的取回路径不对：$out"

    # 错恢复码必须失败可见（不能解开了还当成功）
    export BG_RCODE='wrong-code'
    out="$(HOME="$T/home" expect -f "$T/exp-rescue.exp" 2>&1)" \
        && fail "错恢复码却退出 0：$out"
    printf '%s' "$out" | grep -q "恢复码未能解开救援身份" || fail "错码的报错不具体：$out"

    # 临时目录（含解密出的明文账本与私钥）必须被清掉
    tmp_after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'bg-rescue.*' 2>/dev/null | grep -c . || true)"
    [ "$tmp_before" = "$tmp_after" ] || fail "临时目录未清理（明文残留）: $tmp_after 个"
    unset BG_RCODE BG_REC_RAW BG_REC_ENC BG_RESCUE BG_BASE
else
    echo "SKIP: 未装 expect，恢复码（路径 B）分支未测"
    SKIPPED="$SKIPPED 恢复码路径B(expect)"
fi

# 断言 10：云端副本布局 <base>/<cls> + restic 仓库（引擎自动判定，Windows 设备同款）
if command -v restic >/dev/null 2>&1; then
    CLOUD="$T/cloud"
    mkdir -p "$CLOUD" "$T/wsrc/reports"
    printf 'Q3\n' > "$T/wsrc/reports/季度报告.txt"
    export RESTIC_PASSWORD='rescue-e2e-restic'
    restic -r "$CLOUD/files" init >/dev/null 2>&1 || fail "restic init 失败"
    (cd "$T/wsrc" && restic -r "$CLOUD/files" backup --host "$DEV" reports >/dev/null 2>&1) \
        || fail "restic backup 失败"
    out="$(rescue --base "$CLOUD" --list)" || fail "restic 布局 --list 失败：$out"
    printf '%s' "$out" | grep -q "（restic）" || fail "引擎判定未走 restic：$out"
    out="$(rescue --base "$CLOUD" --class files --find 季度报告)" || fail "restic --find 失败：$out"
    rpath="$(printf '%s' "$out" | grep -F "季度报告.txt" | head -1)"
    [[ -n "$rpath" ]] || fail "restic --find 未命中：$out"
    rescue --base "$CLOUD" --class files --get "$rpath" --to "$T/out-restic" >/dev/null 2>&1 \
        || fail "restic --get 失败"
    got="$(find "$T/out-restic" -type f -name '季度报告.txt' | head -1)"
    [[ -n "$got" ]] || fail "restic 取回后找不到文件: $(find "$T/out-restic" -type f | head -3)"
    [ "$(cat "$got")" = "Q3" ] || fail "restic 取回内容不对"

    # restic restore 对不匹配的 --include 是 rc=0 + 「Restored 0 files」——
    # 取回判据若数的是目标目录里的文件总数，目录里原本有个无关文件就会被当成成功
    mkdir -p "$T/out-restic-decoy"
    printf 'decoy\n' > "$T/out-restic-decoy/preexisting.txt"
    out="$(rescue --base "$CLOUD" --class files --get "/reports/does-not-exist.txt" \
                  --to "$T/out-restic-decoy" 2>&1)" \
        && fail "restic 空取回却报成功：$out"
    printf '%s' "$out" | grep -q "没有取回任何文件" || fail "restic 空取回的报错不具体：$out"
    # 目录里只该剩下那颗诱饵：没有新文件落地，也没有把诱饵当成果
    [[ "$(find "$T/out-restic-decoy" -type f | grep -c . || true)" == "1" ]] \
        || fail "空取回却落了文件: $(find "$T/out-restic-decoy" -type f | head -3)"
else
    echo "SKIP: 未装 restic，云端布局/restic 分支未测"
    SKIPPED="$SKIPPED restic(restic)"
fi

echo "E2E-OK: rescue.sh 逃生恢复（指引 / 两种布局 / 引擎自动判定 / borg+restic 搜与取 / 双 age 路径 / 空取回与缺材料失败可见）${SKIPPED:+ ｜ 未测:$SKIPPED}"
