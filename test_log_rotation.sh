#!/usr/bin/env bash
# E2E：运行史可审计（research/11 A4）——日志轮转 + run 边界行。
# 动机（10-01 复核实测）：现役 backup.log 里混着早已修掉的历史错误，读日志的人
# ——包括下一次会话里的代理自己——会把死缺陷当现役的读，为此白花了十分钟。
# 断言面：
#   1) 超阈值才切：切出的副本装着历史噪音，现役日志里再也找不到它；
#   2) 未超阈值不得多切（轮转不是每轮都跑）；
#   3) 副本数封顶在 SEM_LOG_KEEP，且删除只认 `^backup\.log\.[0-9]{8}-[0-9]{6}$`
#      这一种形态——同目录下不同名字的文件必须活着（AGENTS §3 注入面自查）；
#   4) run 边界行一轮一行，带部署树短 SHA；失败轮如实 rc=1（EXIT trap 的覆盖面）。
# 用法: ./test_log_rotation.sh   （需 bash 5 + borg + rclone）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
# 第 4 阶段靠 chmod 555 造失败，root 下这条不生效（与 test_cloud_failure.sh 同一守卫）
[[ "$(id -u)" == 0 ]] && { echo "E2E-SKIP: root 下 chmod 只读不生效，失败轮 rc 断言无从谈起"; exit 0; }
command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borg，未测"; exit 0; }
command -v rclone >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 rclone，未测"; exit 0; }

T="$(mktemp -d /tmp/bg-logrotate.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log" 2>/dev/null || true; exit 1; }

mkdir -p "$T/src" "$T/conf/partiverse-backup" "$T/home" "$T/logs" "$T/repos"
echo hello > "$T/src/a.txt"
printf '[e2etarget]\ntype = local\n' > "$T/rclone.conf"

cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Mac"
export SYSTEM_ID="E2E-Mac"
export BACKUP_BASE="$T/repos"
export BORG="$(command -v borg)"
export RCLONE="$(command -v rclone)"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=()
export LOG_DIR="$T/logs"
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src")
BORG_EXCLUDES_system=()
CONF
echo "BORG_PASSPHRASE='e2e-pass'" > "$T/conf/partiverse-backup/secrets.env"
chmod 600 "$T/conf/partiverse-backup/secrets.env"

log="$T/logs/backup.log"

run_backup() {  # $1: 追加的环境变量（KEY=VAL，空格分隔；不传就用默认）
    (
        cd "$T"
        # ${1:-} 而不是 $1：set -u 下无参调用是致命变量错误（本仓库 §2 同一条坑）
        # shellcheck disable=SC2086  # 这里的分词是有意的：把 $1 当多个 KEY=VAL 传进 env
        env XDG_CONFIG_HOME="$T/conf" HOME="$T/home" RCLONE_CONFIG="$T/rclone.conf" \
            SKIP_WEBDAV=1 SEM_DRILL=0 SEM_LOG_MAX_BYTES="$MAX_HOT" SEM_LOG_KEEP=3 ${1:-} \
            bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
    )
}

# 边界行形状：`[YYYY-MM-DD HH:MM:SS] run 边界: sha=<短 SHA> rc=<n> dur=<s>s`
boundary_re='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] run 边界: sha=[0-9a-f]{7,40} rc=[0-9]+ dur=[0-9]+s$'
boundary_count() { { grep -E "$boundary_re" "$log" 2>/dev/null || true; } | wc -l | tr -d ' '; }
# 只数**普通文件**：第 3 阶段故意种一个同名的目录，用 ls 计数会把这条守卫的结论带歪
rotated_count()  { { find "$T/logs" -maxdepth 1 -type f -name 'backup.log.????????-??????' 2>/dev/null || true; } | wc -l | tr -d ' '; }

# 阈值取 60 KB：一轮真实备份的 backup.log 实测约 10 KB（borg prune 的表格占大头），
# 所以「超阈值的种子」必须显著大于它，否则第 2 轮会被判成「又超了」。种子 5000 行 ≈ 220 KB。
MAX_HOT=60000
for i in $(seq 1 5000); do echo "[2026-09-30 02:34:00] [ERR] 历史噪音 $i" >> "$log"; done
[ "$(wc -c < "$log")" -gt $MAX_HOT ] || fail "前置：预制日志没超过阈值，轮转断言无从谈起"

# ---------- 1：超阈值 → 切走历史，新日志只含本轮 ----------
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 1 轮备份失败（rc=${rc}）：$(tail -15 "$T/out.log")"
[[ "$(rotated_count)" == "1" ]] || fail "第 1 轮应恰好轮转一次（副本数=$(rotated_count)）"
if ! grep -qF "历史噪音 1" "$log".????????-??????; then
    fail "轮转副本里没有历史噪音（切错了对象？）"
fi
if grep -qF "历史噪音 1" "$log"; then
    fail "现役日志仍混着历史噪音——A4 的动机没被解决"
fi
[[ "$(boundary_count)" == "1" ]] || fail "第 1 轮边界行数=$(boundary_count)（应为 1）"

# ---------- 2：本轮输出远小于阈值 → 不得再切 ----------
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 2 轮备份失败（rc=${rc}）"
[[ "$(rotated_count)" == "1" ]] || fail "第 2 轮没超阈值却轮转了（副本数=$(rotated_count)）"
[[ "$(boundary_count)" == "2" ]] || fail "两轮后边界行数=$(boundary_count)（应一轮一行 = 2）"
grep -q 'FULLY COMPLETE' "$T/out.log" || fail "第 2 轮未打 FULLY COMPLETE"

# ---------- 3：KEEP 封顶 + 两道删除守卫 ----------
# 种子的 mtime 全部写死，让 ls -1t 的排序是确定的（否则同秒的并列会让「留哪几份」变成运气）：
#   20250101..20250105  五份轮转形态的旧副本（越靠后越新）
#   20240101-000000     同名**目录**，插在排序中间（mtime 2025-01-03）——它必须落进
#                       「超出 KEEP」的那一段，才能测到 rm -f 对目录失败会不会炸掉整轮
#   keepme              宽 glob 会捞到、但形态守卫必须放过的文件（mtime 最旧，同样落在删除段）
# 前一两阶段切出的真实副本先清掉：它们会占掉 KEEP 的名额，让「留哪三份」变得不可预期
rm -f -- "$log".????????-??????
for i in 1 2 3 4 5; do
    d="$(printf '2025010%d-023400' "$i")"
    echo "旧副本 $i" > "$log.$d"
    touch -t "2025010${i}0234.00" "$log.$d"
done
mkdir -p "$log.20240101-000000"
touch -t 202501030234.00 "$log.20240101-000000"
echo "不是轮转形态" > "$log.keepme"
touch -t 202412010234.00 "$log.keepme"
rc=0; run_backup "SEM_LOG_MAX_BYTES=1" || fail "第 3 阶段触发轮转的这轮失败"
[[ "$(rotated_count)" == "3" ]] || fail "轮转副本没封顶在 SEM_LOG_KEEP=3（实际 $(rotated_count)）"
# 留下的必须是最新的三份（本轮切出的那份 + 种子里 20250105 / 20250104）
for d in 20250104-023400 20250105-023400; do
    [ -f "$log.$d" ] || fail "KEEP 语义反了：$d 被删了"
done
for d in 20250101-023400 20250102-023400; do
    [ ! -e "$log.$d" ] || fail "超出 KEEP 的旧副本没被清理：$d 还在"
done
# 两道守卫各管一段：形态守卫放过 keepme，普通文件守卫放过同名目录（并且整轮不得被它带崩）
[ -f "$log.keepme" ] || fail "形态白名单没守住：$log.keepme 被删了"
[ -d "$log.20240101-000000" ] || fail "同名目录被删了（rm -f 本该跳过它）"
# 上面两条单独看都有假绿的风险：目录若**根本没进候选清单**，它也照样「没被删」。
# 而 `ls -1t "$f".*`（少一个 d）对目录操作数打印的是**目录内容**，目录就此从清单里消失，
# 普通文件守卫等于没被测到——10-01 变异 4「摘掉守卫 E2E 仍绿」抓到的正是这个。
# 所以直接断言守卫真的运作过。取 out.log 而不是 backup.log：info/warn 只走 stdout
# （backup.sh:14-16），$LOG 里只有引擎 tee 进来的输出和边界行。
grep -qF "跳过非普通文件: $log.20240101-000000" "$T/out.log" \
    || fail "同名目录没进删除候选（ls 少了 -d？普通文件守卫无从谈起）"
# 边界行落在轮转后的新日志里（不是切出去的旧副本里）
grep -qE "$boundary_re" "$log" || fail "轮转后本轮的边界行没落进现役日志"

# 指向一个**不可写**的新仓库根：前面的轮次已经在 $T/repos 建好仓库，只 chmod 555 父目录
# 挡不住往既有仓库写入（borg 照样成功，夹具就成了假阳性）。改 config.sh 里的 BACKUP_BASE
# 指向一个只读目录下的新路径，让首备当场失败。
mkdir -p "$T/ro" && chmod 555 "$T/ro"
sed -e "s#^export BACKUP_BASE=.*#export BACKUP_BASE=\"$T/ro/repos\"#" \
    "$T/conf/partiverse-backup/config.sh" > "$T/conf/config.tmp" \
    && mv "$T/conf/config.tmp" "$T/conf/partiverse-backup/config.sh"
rc=0; run_backup || rc=$?
chmod 755 "$T/ro"
[[ $rc -ne 0 ]] || fail "只读仓库根下备份竟然成功（夹具失效，rc 断言无从谈起）"
if ! grep -qE 'run 边界: sha=[0-9a-f]{7,40} rc=[1-9] ' "$log"; then
    fail "失败轮的边界行 rc 不是非零（末行：$(tail -1 "$log")）"
fi

echo "E2E-OK: 日志轮转（超阈值才切 / 历史噪音离开现役日志 / 副本封顶 SEM_LOG_KEEP / 非轮转形态不误删）+ run 边界行（一轮一行、含部署树 sha、失败轮 rc 如实）"
