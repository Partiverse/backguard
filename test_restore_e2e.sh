#!/usr/bin/env bash
# E2E：restore.sh 真实取回文件（隔离 HOME/CONF/仓库，不碰真实配置、不触网）。
# 验证 README「恢复」一节的四条路径：
#   --list / --archive <cls> --list / --archive <cls> --latest --target / --id <归档名> --target
# 用法: ./test_restore_e2e.sh   （需 bash 5 与 borg）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-restore-e2e.XXXXXX)"
trap 'rm -rf "$T"' EXIT   # 失败路径也要清：夹具可能含 age 私钥/解密出的明文账本，不能留在 /tmp
fail() { echo "E2E-FAIL: $1"; exit 1; }
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borgbackup"; exit 0; }

# 设备名带正则元字符：DEVICE_ID = lower(hostname -s)，init.sh 不做字符过滤，
# Linux 上 hostname 允许 [ ] _ + 等——这类名字一旦进 grep 模式就被当正则读，
# 归档选取（restore 列表 / 语义层 prev 归档）静默变空。
DEV='web[01]-macos'
CONF="$T/conf/partiverse-backup"
BASE="$T/repos"
REPO="$BASE/borg-config"
mkdir -p "$CONF" "$BASE" "$T/home" "$T/src/Documents"
export BORG_BASE_DIR="$T/.borg" BORG_PASSPHRASE='restore-e2e-pass'

# 两个归档：名字序即时间序（0930 晚于 0929），内容有意不同
borg init --encryption=repokey "$REPO" >/dev/null 2>&1 || fail "borg init 失败"
echo v1 > "$T/src/Documents/note.txt"
(cd "$T" && borg create "$REPO::$DEV-config-20260929-023400" src >/dev/null 2>&1) || fail "borg create 1 失败"
echo v2 > "$T/src/Documents/note.txt"
echo new > "$T/src/Documents/added.txt"
(cd "$T" && borg create "$REPO::$DEV-config-20260930-023400" src >/dev/null 2>&1) || fail "borg create 2 失败"

cat > "$CONF/config.sh" <<CFG
export PLATFORM=macos
export DEVICE_ID="$DEV"
export SYSTEM_ID="$DEV"
export BACKUP_BASE="$BASE"
export BORG="$(command -v borg)"
export RCLONE="$(command -v rclone || true)"
# 与生产 config.sh 同形：三个类别各有 includes/excludes 索引数组（语义层的
# export_exclusions 会逐类读取，缺一个就是一条下方断言 6c 的死法）
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=("--exclude" "*/.git")
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=("--exclude" "*/.cache")
BORG_INCLUDES_system=()
BORG_EXCLUDES_system=()
CFG
printf "BORG_PASSPHRASE='%s'\n" "$BORG_PASSPHRASE" > "$CONF/secrets.env"
chmod 600 "$CONF/secrets.env"

run_restore() { HOME="$T/home" XDG_CONFIG_HOME="$T/conf" bash "$V0_DIR/restore.sh" "$@"; }

# 断言 1：裸 --list（README 首条示例，不带 --archive）
out="$(run_restore --list 2>&1)" || fail "--list 退出非零：$out"
printf '%s' "$out" | grep -q -e "-20260930-023400" || fail "--list 未列出归档：$out"

# 断言 2：--archive config --list 两个归档都在（设备名含 [01]，只能按字面量匹配）
out="$(run_restore --archive config --list 2>&1)" || fail "--archive --list 失败：$out"
n="$(printf '%s\n' "$out" | grep -cF "$DEV-config-")"
[ "$n" = 2 ] || fail "--archive --list 应列 2 个归档，实际 $n"

# 断言 3：--latest 取回的是最新快照内容
run_restore --archive config --latest --target "$T/out-latest" >"$T/l.log" 2>&1 \
    || fail "--latest 恢复失败：$(tail -5 "$T/l.log")"
[ "$(cat "$T/out-latest/src/Documents/note.txt" 2>/dev/null)" = v2 ] || fail "--latest 未取到最新内容"
[ -f "$T/out-latest/src/Documents/added.txt" ] || fail "--latest 缺 added.txt"

# 断言 4：--id 精确取回历史快照（note 回到 v1，added 不存在）
run_restore --archive config --id "$DEV-config-20260929-023400" --target "$T/out-id" >"$T/i.log" 2>&1 \
    || fail "--id 恢复失败：$(tail -5 "$T/i.log")"
[ "$(cat "$T/out-id/src/Documents/note.txt" 2>/dev/null)" = v1 ] || fail "--id 未取到指定快照"
[ ! -e "$T/out-id/src/Documents/added.txt" ] || fail "--id 快照不应含 added.txt"

# 断言 5：语义层的 prev 归档选取走同一份 fixture——元字符设备名下仍要取到
# 「名排序后的前一个」，且最老归档没有 prev
log(){ :; }; info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }
BORG="$(command -v borg)"
DEVICE_ID="$DEV"
source "$V0_DIR/semantic/semantic.sh"
declare -F prev_archive_for >/dev/null || fail "prev_archive_for 未定义（prev 选取仍是内联 grep 正则）"
newest="$DEV-config-20260930-023400"
oldest="$DEV-config-20260929-023400"
[ "$(prev_archive_for "$REPO" config "$newest")" = "$oldest" ] || \
    fail "prev 归档选取失败（设备名被当正则读）: [$(prev_archive_for "$REPO" config "$newest")]"
[ -z "$(prev_archive_for "$REPO" config "$oldest")" ] || fail "最老归档不应有 prev"

# 断言 6：restore.md 教的命令必须能照抄执行——「产物即脚本」。
# 10-01 复核实测：模板写的是 `borg extract --list`，borg 1.4 没有这个选项，
# 而 extract --list 会**真的解包**（在仓库目录里跑等于往工作树落文件）。
# 指南写错不是显示问题，是恢复链路的一部分。
mkdir -p "$T/logs"
# 与生产同形：backup.sh 是 source config.sh 之后才调 generate_semantic 的，
# 这里也照做——SCRIPT_DIR 同理（backup.sh export 它，semantic_bg 用它找 vendored bg）
# shellcheck disable=SC1090
source "$CONF/config.sh"
# generate_semantic 读这三个全局（backup.sh 在生产里都备好了）：SCRIPT_DIR 让
# semantic_bg 找到 vendored bg，LOG_DIR 是 runs/ 落点，LOG 是它的日志。
# 少一个就是 set -u 下的致命变量错误——消息会被调用点的 2>&1 吞进 gen.log，
# 表面症状是「脚本静默退出 1」，10-01 在这条上排查了三次才挖出来。
SCRIPT_DIR="$V0_DIR"
LOG_DIR="$T/logs"
LOG="$T/logs/sem.log"
# SEM_TIME 必须写死：generate_semantic 不传 --time 时用**真实现在**，快照就落在
# `<今天>/<现在HHMM>-<时段>`。断言 7 要验的是「时间轴上上一份快照」取自目录名，而它
# 按 `sort | tail -1` 挑最后一份——只要今天恰好就是那天的日期（10-01 写这条时种子是
# 2026-10-02，一切正常；到 10-02 当天，这两发没写时间的快照就排到了种子目录**后面**，
# 于是「上一次备份」变成跑测试的那一刻，断言当场红）。CI runner 同理：它红不红取决于
# 派工时刻，这种「按日期腐化」的夹具等于给未来埋雷。
SEM_TIME="2026-09-30T09:48:00" generate_semantic "config:$REPO:$newest" >"$T/gen.log" 2>&1 \
    || fail "断言 6 前置：generate_semantic 失败：$(tail -5 "$T/gen.log")"
sdir_all="$(find "$BASE/timeline" -mindepth 4 -maxdepth 4 -type d)"
[ -n "$sdir_all" ] || fail "断言 6：没生成深度 4 的快照目录"
# 不用 `find | head -1`：pipefail 下 head 先退会让 find 收到 SIGPIPE，
# 赋值语句的非零状态在 set -e 里直接静默终止整个脚本（AGENTS §2 同一条坑）
sdir="${sdir_all%%$'\n'*}"
[ -f "$sdir/restore.md" ] || fail "断言 6：快照里没有 restore.md（${sdir}）"

# 6a：任何明文产物都不得再出现那条错命令
for f in MANIFEST.txt STORY.md COVERAGE.txt restore.md; do
    [ -f "$sdir/$f" ] || continue
    if grep -qF 'extract --list' "$sdir/$f"; then
        fail "断言 6a：明文产物 $f 里出现 extract --list（borg 1.4 无此选项且会真解包）"
    fi
done

# 6b：把产物里的命令行原文抽出来，替换占位符后真跑一遍
grep -E '^[[:space:]]+(borg|cd) ' "$sdir/restore.md" | sed \
    -e "s#<仓库路径>#$REPO#g" \
    -e "s#<归档名>#$newest#g" \
    -e "s#<恢复目标目录>#$T/out-guide#g" \
    -e "s#<要恢复的子路径>#src/Documents/note.txt#g" > "$T/guide.sh"
[ -s "$T/guide.sh" ] || fail "断言 6b：restore.md 里抽不到任何 borg/cd 命令行"
mkdir -p "$T/out-guide"
bash "$T/guide.sh" >"$T/guide.log" 2>&1 || fail "断言 6b：照抄 restore.md 的命令执行失败：$(cat "$T/guide.log")"
[ "$(cat "$T/out-guide/src/Documents/note.txt" 2>/dev/null)" = v2 ] \
    || fail "断言 6b：按指南取回的文件内容不对（应为 v2）：$(ls -R "$T/out-guide" 2>/dev/null)"
# extract 只解那一个子路径，不该把整份归档倒进目标目录
[ ! -e "$T/out-guide/src/Documents/added.txt" ] \
    || fail "断言 6b：指南命令解出了未指定的文件（子路径过滤失效）"

# 6c：非致命分层（AGENTS §1.3）——老配置/半手改配置缺一个 BORG_EXCLUDES_* 时，
# 语义层不得终止整次备份。修复前 `${#e_ref[@]}` 在 set -u 下是**致命变量错误**：
# 它不是 return，`backup.sh` 那句 `|| warn` 根本兜不住，整轮备份当场退出且无一条错误消息。
( set -e
  unset BORG_EXCLUDES_files
  SEM_TIME="2026-10-01T08:00:00" SEM_LABEL=partial generate_semantic "config:$REPO:$newest" >"$T/gen2.log" 2>&1 ) \
    || fail "断言 6c：缺 BORG_EXCLUDES_files 时语义层终止了备份（应只跳过该类别的排除清单）：$(tail -3 "$T/gen2.log")"
find "$BASE/timeline" -maxdepth 4 -type d -name '*-partial' | grep -q . \
    || fail "断言 6c：降级后仍应产出快照（partial 标签目录不存在）"

# 断言 7：STORY 的两个「基线」口径必须分开（10-01 真机缺陷）。
# parent_time 来自引擎里尚未被 prune 裁掉的上一份归档（本 fixture 是 09-29），
# 「上一次备份」来自时间轴上的上一份快照（这里种成 10-02）。borg prune 把中间几次
# 备份裁掉后两者能差几天：增量数字是跨这几天合计的，不断说明就是「冻住的数字」；
# 更糟的是断档提醒若按 parent 算，保留策略会**伪造出**停摆告警。
# 时间轴形状是 timeline/YYYY/MM/DD/HHMM-标签（深度 4，AGENTS §2 去设备层那条）
mkdir -p "$BASE/timeline/2026/10/02/0234-night"
SEM_TIME="2026-10-03T02:34:00" SEM_LABEL=pruned \
    generate_semantic "config:$REPO:$newest" >"$T/gen3.log" 2>&1 \
    || fail "断言 7：generate_semantic 失败：$(tail -5 "$T/gen3.log")"
s7="$(find "$BASE/timeline" -mindepth 4 -maxdepth 4 -type d -name '*-pruned')"
s7="${s7%%$'\n'*}"
[ -n "$s7" ] || fail "断言 7：没生成 pruned 快照"
grep -qF '上一次备份是 2026-10-02 02:34' "$s7/STORY.md" \
    || fail "断言 7：STORY 没写时间轴口径的上一次备份（--prev-run-time 没传进 convert？）：$(cat "$s7/STORY.md")"
grep -qF '能回到的上一份归档是 2026-09-29 02:34' "$s7/STORY.md" \
    || fail "断言 7：STORY 没写引擎口径的上一份归档：$(cat "$s7/STORY.md")"
grep -qF '上一次备份: 2026-10-02 02:34' "$s7/MANIFEST.txt" \
    || fail "断言 7：MANIFEST 卡片仍用引擎口径当「上一次」（应优先时间轴口径）"
# 距上一次备份只有 24h：不得因为 parent 归档是 4 天前就报断档
# （`grep && fail` 在 set -e 下 grep 不命中就等于脚本退出，用 if 形式）
if grep -qF '断档' "$s7/STORY.md"; then
    fail "断言 7：prune 裁掉的间隔被当成断档（告警应由上一次备份触发，不是 parent 归档）"
fi

echo "E2E-OK: restore.sh 四条路径（--list / --archive --list / --latest / --id）+ 语义层 prev 归档选取 + restore.md 命令照抄可执行 + 缺数组时语义层不杀备份 + STORY 基线双口径分离，均真实可用"
