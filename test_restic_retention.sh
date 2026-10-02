#!/usr/bin/env bash
# E2E：restic 侧的「本地保留」必须真的回收字节（Windows 差距清单 ⑦，AGENTS §5）。
#
# 为什么要单独一套：backup.sh 的 windows 分支（restic-under-MSYS）此前**没有任何测试跑过它**，
# 10-02 第一次把它跑起来的现场是三类全红——backup 调用少了 -r，restic 直接 rc=1
# 「Please specify repository location」（它不记得上一条 init 用的哪个仓库）。这正是
# 「一处调用点喂多个分支、每个分支都要各调一次」那一课的第二发（HANDOVER §4.18）：
# borg 分支每晚都在真机上跑，restic 分支只在文档里「支持 Windows」。
# 第二发在同一条命令上：forget 不带 --prune 时，引擎**只删快照对象、不删数据**
# （restic 帮助页原话：「In order to remove the unreferenced data after "forget" was run
# successfully, see the "prune" command」）。实测 9 份日快照 forget 退出 0、快照少两份、
# 仓库字节数一字节没少——于是「本地保留 7d/4w/6m」在 backup.sh 与 backup.ps1 里都是装饰，
# 而 backup.ps1 第 174 行「本地已 prune，云端保留全部历史」的前提也不成立。
#
# 断言面：
#   1) 生产 backup.sh（PLATFORM=windows + 真 restic）三类全部成功、退出 0；
#   2) 策略真的裁了快照，且 prune 真的回收了字节（data/ 包数下降 + 释放量 ≥1 MiB +
#      日志出现「running prune」）——只数快照条数的断言在「forget 没带 --prune」下照样绿；
#   3) 回收之后仓库仍读得动（restic check）：prune 删错东西比不删更糟；
#   4) rc=3（部分源文件读不到）只告警、不判败——归档已经落库，判败等于白扔一晚；
#   5) forget 的非零非 3（这里用口令不对 rc=12）必须让本类失败且不宣布 COMPLETE；
#   6) backup.ps1 那一份带的必须是同一发（静态：--prune + 同一张 rc 表）；
#   7) A2a 存储完整性接到 restic 分支：健康轮三类各记 PASS 且节流生效 / pack 数据段翻坏只有
#      --read-data 看得见（那一类 FAIL、别类 PASS、退出非零、不宣布 COMPLETE）/ rc=11 记
#      UNKNOWN 且不改退出码。
#
# 用法: ./test_restic_retention.sh   （需要 restic；夹具全在 mktemp 里，不触真实配置）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v restic >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 restic，未测"; exit 0; }

T="$(mktemp -d /tmp/bg-restic-retention.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -30 "$T/out.log" 2>/dev/null || true; exit 1; }

mkdir -p "$T/src/文档" "$T/conf/partiverse-backup" "$T/home"
echo hello > "$T/src/文档/tiny.txt"
export RESTIC_PASSWORD='e2e-pass'

# 配置每次重写：BACKUP_BASE 按场景分仓库根，RESTIC 可指到桩（场景 5 要它只对 forget 改口令）
write_config() {   # $1=BACKUP_BASE  $2=restic 可执行路径
    cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="windows"
export DEVICE_ID="E2E-Win"
export SYSTEM_ID="E2E-Win"
export BACKUP_BASE="$1"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=()
export RESTIC="$2"
export RCLONE="$(command -v rclone || echo /usr/bin/true)"
export BORG="$(command -v borg || echo /usr/bin/true)"
RESTIC_INCLUDES_config=("$T/src")
RESTIC_EXCLUDES_config=()
RESTIC_INCLUDES_files=("$T/src")
RESTIC_EXCLUDES_files=()
RESTIC_INCLUDES_system=("$T/src")
RESTIC_EXCLUDES_system=()
CONF
    printf "RESTIC_PASSWORD='e2e-pass'\n" > "$T/conf/partiverse-backup/secrets.env"
    chmod 600 "$T/conf/partiverse-backup/secrets.env"
}

run_backup() { (
    cd "$T/home"
    # shellcheck disable=SC2086  # 分词是有意的：把 $1 当多个 KEY=VAL 传进 env
    env XDG_CONFIG_HOME="$T/conf" HOME="$T/home" SKIP_WEBDAV=1 SEM_PREFLIGHT=0 \
        ${1:-} bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
); }

# 每份「往晚」快照带一份**之后从磁盘删掉**的独有数据：不删的话当晚的新快照仍引用全部旧
# 内容，prune 无可回收（第一版夹具就是这样把「没 prune」测成了「prune 没活干」）
seed_repo() {   # $1=仓库路径  $2=份数  $3=每份独有字节数
    local repo="$1" n="$2" bytes="$3" i day
    restic -r "$repo" init >/dev/null 2>&1 || true
    for i in $(seq 1 "$n"); do
        # restic 的 --time 只认 "2006-01-02 15:04:05"（RFC3339 反而报解析失败）
        day=$(printf "2026-09-%02d 23:00:00" $((9 + i)))
        if [[ $bytes -gt 0 ]]; then
            head -c "$bytes" /dev/urandom > "$T/src/文档/only-$i.bin"
        fi
        restic -r "$repo" backup --host E2E-Win --time "$day" "$T/src" >/dev/null 2>&1 \
            || fail "预置快照 $day 失败（${repo}）"
        if [[ $bytes -gt 0 ]]; then
            rm -f "$T/src/文档/only-$i.bin"
        fi
    done
    return 0
}

snaps_of() { restic -r "$1" snapshots --json 2>/dev/null |
    python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }
packs_of() { find "$1/data" -mindepth 2 -type f 2>/dev/null | wc -l | tr -d ' '; }
kib_of()   { du -sk "$1" | cut -f1; }

REAL_RESTIC="$(command -v restic)"
MAIN_REPO="$T/main/repos/restic-files"

# ---------- 1+2+3：生产链路跑通、策略裁剪、prune 真回收、仓库仍健康 ----------
write_config "$T/main/repos" "$REAL_RESTIC"
mkdir -p "$T/main/repos"
seed_repo "$T/main/repos/restic-files" 9 6291456
seed_repo "$T/main/repos/restic-config" 9 6291456
seed_repo "$T/main/repos/restic-system" 9 6291456
before_snaps=$(snaps_of "$MAIN_REPO"); before_packs=$(packs_of "$MAIN_REPO")
before_kib=$(kib_of "$MAIN_REPO")
[[ $before_snaps -eq 9 ]] || fail "预置快照数不对（$before_snaps ≠ 9）"

rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 1 步：生产 backup.sh 在 restic 分支没跑成（rc=${rc}）——三类里至少一类在引擎调用上就断了"
grep -q 'FULLY COMPLETE' "$T/out.log" || fail "第 1 步：没宣布 FULLY COMPLETE：$(tail -4 "$T/out.log")"
if grep -qE 'Please specify repository location' "$T/out.log"; then
    fail "第 1 步：restic backup 少了 -r（引擎直接找不到仓库）"
fi

# 策略得真的裁掉东西，否则「prune 回收了多少」无从谈起
after_snaps=$(snaps_of "$MAIN_REPO")
[[ $after_snaps -lt $before_snaps ]] \
    || fail "第 2 步：保留策略一份都没裁（$before_snaps → ${after_snaps}，含本轮新增一份）：$(grep -A2 'Applying Policy' "$T/out.log" | head -6)"
grep -q 'running prune' "$T/out.log" \
    || fail "第 2 步：forget 没带 --prune（日志里找不到「running prune」这一行）"
freed=$(( before_kib - $(kib_of "$MAIN_REPO") ))
after_packs=$(packs_of "$MAIN_REPO")
# 没有 prune 时实测释放量只有索引重写的 4 KiB 级；带 prune 是 MiB 级——阈值取 1 MiB 把两者分开
[[ $freed -ge 1024 ]] \
    || fail "第 2 步：快照裁了但字节没回收（释放 ${freed} KiB，包数 $before_packs → ${after_packs}）——forget 不带 --prune 就是这个形状"
[[ $after_packs -lt $before_packs ]] \
    || fail "第 2 步：data/ 包数没下降（$before_packs → ${after_packs}）"

if restic -r "$MAIN_REPO" check > "$T/check.log" 2>&1; then
    :
else
    fail "第 3 步：回收后仓库自检失败（prune 删到还在用的数据？）：$(tail -6 "$T/check.log")"
fi

# ---------- 4：rc=3（部分源文件读不到）只告警、不判败 ----------
# 前提检查：以 root 跑时 chmod 000 挡不住读，那这一发就造不出 rc=3——如实 SKIP 而非假绿
if [[ "$(id -u)" == "0" ]]; then
    echo "E2E-SKIP 第 4 步：root 身份造不出不可读文件，rc=3 这一档未测"
else
    write_config "$T/partial/repos" "$REAL_RESTIC"
    mkdir -p "$T/partial/repos"
    seed_repo "$T/partial/repos/restic-files" 2 0
    seed_repo "$T/partial/repos/restic-config" 2 0
    seed_repo "$T/partial/repos/restic-system" 2 0
    echo 机密 > "$T/src/文档/读不到.txt"
    chmod 000 "$T/src/文档/读不到.txt"
    rc=0; run_backup || rc=$?
    chmod 644 "$T/src/文档/读不到.txt" 2>/dev/null || true
    if [[ $rc -ne 0 ]]; then
        fail "第 4 步：restic rc=3（快照已存、只是缺那一条读不到的文件）被判成本类失败——归档已经落库，判败等于白扔一晚：$(grep -E 'restic backup 失败|exit 3' "$T/out.log" | head -3)"
    fi
    grep -q '部分文件读不到' "$T/out.log" \
        || fail "第 4 步：rc=3 没有落成「部分文件读不到」的告警（静默当成功，观察期就没人知道快照不完整）：$(grep -i 'exit 3\|read' "$T/out.log" | head -3)"
    grep -q 'FULLY COMPLETE' "$T/out.log" || fail "第 4 步：rc=3 那轮没宣布 COMPLETE：$(tail -3 "$T/out.log")"
fi

# ---------- 5：forget 的非零非 3 必须让本类失败且不宣布 COMPLETE ----------
# 桩只把**口令**换掉（转发真实二进制），复现引擎 EXIT STATUS 表里的 12 = 口令不对：
# 这一档若被静默吞掉，后果是仓库无限增长而每晚都报成功
mkdir -p "$T/bin"
cat > "$T/bin/restic-badpw-forget" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    if [ "\$arg" = "forget" ]; then
        export RESTIC_PASSWORD='wrong-on-purpose'
    fi
done
exec "$REAL_RESTIC" "\$@"
STUB
chmod 755 "$T/bin/restic-badpw-forget"
write_config "$T/badpw/repos" "$T/bin/restic-badpw-forget"
mkdir -p "$T/badpw/repos"
seed_repo "$T/badpw/repos/restic-files" 2 0
seed_repo "$T/badpw/repos/restic-config" 2 0
seed_repo "$T/badpw/repos/restic-system" 2 0
rc=0; run_backup || rc=$?
[[ $rc -ne 0 ]] || fail "第 5 步：forget/prune 失败（rc=12）却整轮退出 0——保留策略没跑成的唯一后果是仓库无限增长，没人会主动去查仓库尺寸"
grep -qE 'forget/prune 失败' "$T/out.log" \
    || fail "第 5 步：没有把失败报到具体那一步（只报「备份失败」的话，读的人分不清是备份还是清理）：$(grep -i 'forget\|prune' "$T/out.log" | head -3)"
if grep -q 'FULLY COMPLETE' "$T/out.log"; then
    fail "第 5 步：forget/prune 失败的一轮仍宣布 FULLY COMPLETE"
fi

# ---------- 6：PowerShell 那一份必须带同一发（静态守卫）----------
# 为什么这一发是静态的：本机无 pwsh 跑不了 backup.ps1，而 CI 的 windows job 每轮新建空仓库，
# forget 在那里一份都裁不掉、prune 无事可做——「没带 --prune」和「带了」在那一轮里长得一模一样。
# 行为面已由前五段在同一引擎、同一策略、同一 EXIT STATUS 表上验过，这里只钉两份实现的形状对齐。
PS1="$V0_DIR/backup.ps1"
if ! grep -nE 'restic .*forget[^|]*--prune' "$PS1" > "$T/ps1-forget.txt" 2>/dev/null; then
    fail "第 6 步：backup.ps1 的 forget 没有 --prune——Windows 真机上一旦接入，本地仓库就只增不减（第 2 步已在 bash 侧量过那 4 KiB 与 6 MiB 的差别）"
fi
forget_line=$(cut -d: -f1 < "$T/ps1-forget.txt" | head -1)
# 取窗口用 sed 而不是 `tail -n +N | head -8`：后者在 pipefail 下是个定时炸弹——文件一大，
# head 读完 8 行就退出，tail 还在写，SIGPIPE 让整条赋值语句 rc=141 直接炸掉脚本（10-02 给
# backup.ps1 加完 A6 那 315 行就当场露头，本机 5/5 复现，而 466 行的旧版一直侥幸为 0）。
after=$(sed -n "$(( forget_line + 1 )),$(( forget_line + 8 ))p" "$PS1")
grep -q 'LASTEXITCODE -eq 3' <<<"$after" \
    || fail "第 6 步：backup.ps1 的 forget 之后没有 rc=3 的容忍分支（两份实现对同一档退出码判得不一样，第一次真机接入就会看到两种结果）"
grep -q 'LASTEXITCODE -ne 0' <<<"$after" \
    || fail "第 6 步：backup.ps1 的 forget 之后没检查退出码（第 5 步那一发在 Windows 上就是静默的）"

# ---------- 7：A2a 存储完整性接到 restic 分支（0 PASS / 11 UNKNOWN / 其余 FAIL）----------
# 这一发原先压着不动的理由是「CI 从不跑 restic，写上去就是永远不被执行的死代码」（AGENTS §2
# A2a 那条末句），第 1~5 段把 restic 分支挂上 CI 之后这个理由失效了，于是接上
# `restic check --read-data`。三段各钉一种坏法：
#   7a 健康轮：checks=3 且三类都是 **restic:** 前缀的 PASS（少登记一类 → checks=2；引擎标签
#      写错 → 拿 borg 去开 restic 仓库当场 fatal）。报告是随时间轴上云的明文产物，红线 §1.1
#      的隐私口径一并扫；**窗口节流也得在这条分支上测一次**，否则「月度」只是形容词。
#   7b 真损坏：翻掉一个 pack 的数据段字节。10-02 实测「只查结构」的 restic check（不带
#      --read-data）对这种仓库照样 rc=0，只有 --read-data 看得见——所以「files 类判 FAIL」
#      这一条断言同时钉住那个 flag，不必再去日志里找它（引擎原文按红线只进本地日志）。
#   7c rc=11（引擎 EXIT STATUS 表的「repository is already locked」）：记 UNKNOWN、不改退出码。
#      为什么用桩：restic 在本地后端上的锁是**建议锁**，10-02 实测并发两个 check、以及 300 MiB
#      备份进行中的 check 全是 rc=0，真造不出 11 —— 那就按引擎文档的表复现它。
# 三段都用独立小仓库：整仓读取要把仓库全读一遍，夹具得留在秒级。
status_of() { { grep -E "^[A-Z]+ +$1 " "$2" 2>/dev/null || true; } | awk '{print $1; exit}'; }
summary_field() { { grep -o "$1=[0-9]*" "$2" || true; } | head -1 | cut -d= -f2; }
hash_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi
}

head -c 204800 /dev/urandom > "$T/src/文档/payload.bin"

I_BASE="$T/integ/repos"; I_REPORT="$I_BASE/timeline/INTEGRITY.txt"
write_config "$I_BASE" "$REAL_RESTIC"
mkdir -p "$I_BASE"
seed_repo "$I_BASE/restic-files" 2 0
seed_repo "$I_BASE/restic-config" 2 0
seed_repo "$I_BASE/restic-system" 2 0
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 7a 步：仓库全都健康，却因为这一轮跑了完整性校验而退出非零：$(tail -6 "$T/out.log")"
[[ -f "$I_REPORT" ]] \
    || fail "第 7a 步：restic 分支没落下 INTEGRITY.txt（${I_REPORT}）——那个目录在 borg 那一路由语义层创建，restic 这一路没人建就等于这月的证据没了：$(grep -i integrity "$T/out.log" | head -4)"
[[ "$(summary_field checks "$I_REPORT")" == "3" ]] \
    || fail "第 7a 步：三类仓库没有各自被校验（汇总 checks=$(summary_field checks "$I_REPORT")，应为 3）：$(grep -v '^#' "$I_REPORT")"
for cls in config files system; do
    [[ "$(status_of "restic:$cls" "$I_REPORT")" == "PASS" ]] \
        || fail "第 7a 步：restic:$cls 没记成 PASS（实际 $(status_of "restic:$cls" "$I_REPORT")）——引擎调用或退出码映射断了：$(grep -v '^#' "$I_REPORT")"
done
# 明文报告的隐私面（红线 §1.1）：仓库绝对路径、源码树路径、被备份的文件名都不许出现
for forbidden in "$I_BASE" "$T/src" "payload.bin" "tiny.txt"; do
    if grep -qF "$forbidden" "$I_REPORT"; then
        fail "第 7a 步：报告里出现了「${forbidden}」——它随下轮时间轴推上网盘：$(grep -F "$forbidden" "$I_REPORT")"
    fi
done
# 窗口节流：第二轮不该重写报告（低频路径的节流本身要被测）
report_hash="$(hash_of "$I_REPORT")"
rc=0; run_backup || rc=$?
[[ $rc -eq 0 ]] || fail "第 7a 步：第二轮（窗口未到）本该照常通过：$(tail -6 "$T/out.log")"
if [[ "$(hash_of "$I_REPORT")" == "$report_hash" ]]; then
    :
else
    fail "第 7a 步：30 天窗口没拦住第二轮（报告被重写了）——每晚读一遍全仓不是「月度校验」：$(tail -6 "$T/out.log")"
fi
grep -q '未到校验窗口' "$T/out.log" \
    || fail "第 7a 步：节流生效却没留下任何说明（静默跳过读的人分不清是没跑还是坏了）：$(grep -i integrity "$T/out.log" | head -3)"

C_BASE="$T/corrupt/repos"; C_REPORT="$C_BASE/timeline/INTEGRITY.txt"
C_FILES="$C_BASE/restic-files"
write_config "$C_BASE" "$REAL_RESTIC"
mkdir -p "$C_BASE"
seed_repo "$C_FILES" 2 0
seed_repo "$C_BASE/restic-config" 2 0
seed_repo "$C_BASE/restic-system" 2 0
# 挑最大的那个 pack：小的可能整份都是末尾的清单（TOC），翻它等于改文件名而不是改数据
pack=""; pack_size=0
while IFS= read -r p; do
    s=$(wc -c < "$p" | tr -d ' ')
    if [[ $s -gt $pack_size ]]; then pack_size=$s; pack="$p"; fi
done < <(find "$C_FILES/data" -mindepth 2 -type f)
if [[ $pack_size -lt 4096 ]]; then
    fail "第 7b 步：夹具里的 pack 只有 ${pack_size} 字节，没有可翻的数据段（偏移 1024 会落到 TOC 之外）"
fi
chmod u+w "$pack"   # restic 的 pack 建完即只读，不改权限直接写会 EACCES
python3 - "$pack" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(1024)
    b = f.read(1)
    f.seek(1024)
    f.write(bytes([b[0] ^ 0xFF]))
PY
if restic -r "$C_FILES" check --read-data > "$T/precheck.log" 2>&1; then
    fail "第 7b 步：夹具没能造出损坏（翻过字节的仓库 --read-data 仍 rc=0），后面的断言会踩空——偏移或 pack 选错了：$(tail -4 "$T/precheck.log")"
fi
rc=0; run_backup "INTEGRITY_DAYS=0" || rc=$?
[[ -f "$C_REPORT" ]] \
    || fail "第 7b 步：损坏那一轮没落报告（备份或 forget 先炸了就永远走不到完整性这一步）：$(grep -iE 'integrity|失败|exit' "$T/out.log" | head -6)"
[[ "$(status_of "restic:files" "$C_REPORT")" == "FAIL" ]] \
    || fail "第 7b 步：pack 数据段被翻过一个字节的仓库没判 FAIL（实际 $(status_of "restic:files" "$C_REPORT")）——不带 --read-data 的 restic check 只看结构，这种仓库它就是 rc=0：$(grep -v '^#' "$C_REPORT")"
for cls in config system; do
    [[ "$(status_of "restic:$cls" "$C_REPORT")" == "PASS" ]] \
        || fail "第 7b 步：损坏只在 files 仓库，别的类别跟着判红就是把结论并到了错的粒度（${cls} → $(status_of "restic:$cls" "$C_REPORT")）：$(grep -v '^#' "$C_REPORT")"
done
[[ "$(summary_field FAIL "$C_REPORT")" == "1" ]] \
    || fail "第 7b 步：汇总 FAIL 计数不是 1（实际 $(summary_field FAIL "$C_REPORT")）——逐仓库的粒度没保住：$(grep -v '^#' "$C_REPORT")"
if grep -qF "$(basename "$pack")" "$C_REPORT"; then
    fail "第 7b 步：报告抄了引擎原文（里面那个 pack 的文件名）——它随时间轴上云，而错误行里还带着仓库绝对路径"
fi
if [[ $rc -eq 0 ]]; then
    fail "第 7b 步：报告里已经写了 FAIL，退出码却还是 0——仓库有坏数据而 nightly 报成功，观察期没人会去翻报告正文"
fi
if grep -q 'FULLY COMPLETE' "$T/out.log"; then
    fail "第 7b 步：发现坏数据的一轮仍宣布 FULLY COMPLETE"
fi

mkdir -p "$T/bin"
cat > "$T/bin/restic-lock-check" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    if [ "\$arg" = "check" ]; then
        echo "repository is already locked" >&2
        exit 11
    fi
done
exec "$REAL_RESTIC" "\$@"
STUB
chmod 755 "$T/bin/restic-lock-check"
L_BASE="$T/locked/repos"; L_REPORT="$L_BASE/timeline/INTEGRITY.txt"
write_config "$L_BASE" "$T/bin/restic-lock-check"
mkdir -p "$L_BASE"
seed_repo "$L_BASE/restic-files" 2 0
seed_repo "$L_BASE/restic-config" 2 0
seed_repo "$L_BASE/restic-system" 2 0
rc=0; run_backup "INTEGRITY_DAYS=0" || rc=$?
[[ -f "$L_REPORT" ]] || fail "第 7c 步：拿不到锁的一轮没落报告：$(grep -i integrity "$T/out.log" | head -4)"
for cls in config files system; do
    [[ "$(status_of "restic:$cls" "$L_REPORT")" == "UNKNOWN" ]] \
        || fail "第 7c 步：rc=11（已被锁）没记成 UNKNOWN（${cls} → $(status_of "restic:$cls" "$L_REPORT")）——把它按最坏情况判 FAIL 的话，一次手工演练就能把 nightly 报成仓库腐化：$(grep -v '^#' "$L_REPORT")"
done
[[ "$(summary_field UNKNOWN "$L_REPORT")" == "3" ]] \
    || fail "第 7c 步：UNKNOWN 计数不是 3（实际 $(summary_field UNKNOWN "$L_REPORT")）：$(grep -v '^#' "$L_REPORT")"
[[ "$(summary_field FAIL "$L_REPORT")" == "0" ]] \
    || fail "第 7c 步：锁冲突被记成了 FAIL（汇总 $(summary_field FAIL "$L_REPORT")）：$(grep -v '^#' "$L_REPORT")"
if [[ $rc -ne 0 ]]; then
    fail "第 7c 步：UNKNOWN 改变了退出码（rc=${rc}）——这一项既没证成也没证败，不该把用户叫醒：$(tail -6 "$T/out.log")"
fi
grep -q 'FULLY COMPLETE' "$T/out.log" || fail "第 7c 步：全是 UNKNOWN/PASS 的一轮没宣布 COMPLETE：$(tail -3 "$T/out.log")"

echo "E2E-OK: restic 分支端到端 + 保留策略真回收字节 + 回收后仓库可读 + rc=3 容忍 + forget 失败可见 + ps1 同形 + A2a 完整性三档"
