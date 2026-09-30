#!/usr/bin/env bash
# rescue.sh — 逃生恢复单文件脚本（research/06 §6「软件死亡，数据不死」/ 08 章 T3.2）
#
# 约束：不依赖本仓库其它文件，也不依赖 Python——新机器只要能跑
# bash + borg/restic + age，就能只凭「备份目录副本 + 恢复材料」取回文件。
# 目标：30 分钟内盲恢复任一路径。
#
# 两种目录布局都认：
#   本机      <base>/borg-<cls>/     + <base>/timeline/<设备>/YYYY/MM/DD/HHMM-标签/
#   云端副本  <base>/<cls>/          + <base>/timeline/<设备>/…（<base> = 挂载点/<系统标识>/）

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
error()   { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()    { echo -e "${RED}[WARN]${NC} $*" >&2; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }

BASE="${RESCUE_BASE:-$HOME/PartiverseBackup}"
DEVICE="" CLASS="" ARCHIVE="" FIND="" GET="" TO="" SNAPSHOT=""
IDENTITY="" RECOVERY="" ENGINE="auto"
MODE=""   # guide | list | find | get | ledger
WORK=""   # 临时目录：解封出的明文账本只存这里

usage() {
    cat <<'TXT'
rescue.sh — 只凭备份目录副本 + 恢复材料取回文件

  ./rescue.sh --guide                                     先读这个：目录结构与恢复步骤
  ./rescue.sh --base <目录> --list                         列档案 / 归档（快照）/ 设备目录
  ./rescue.sh --base <目录> --class files --find <模式>     在归档内按字面量搜路径
  ./rescue.sh --base <目录> --class files --get <路径> --to <目录>    取回（默认最新归档）
  ./rescue.sh --base <目录> --ledger --find <模式>          解封账本后跨档案搜（含大小）

参数
  --base <目录>      备份根，默认 ~/PartiverseBackup；云端副本请指向 <挂载>/<系统标识>
  --device <设备名>  时间轴下多于一个设备时必须指定（--list 会列出来）
  --class <类别>     config | files | system
  --archive <名称>   borg 归档名 / restic 快照 ID；默认取该档案最新一个
  --to <目录>        取回目标目录（不存在则创建）
  --engine <值>      auto|borg|restic；auto 按仓库目录特征判定
  --identity <文件>  age 主身份（路径 A，日常解密）
  --recovery <文件>  recovery-identity.enc（路径 B，终端会提示输入纸质恢复码）

口令一律交给引擎自己提示：BORG_PASSPHRASE / RESTIC_PASSWORD 未设置时 borg、restic
会各自从终端索取——本脚本不经手、不落盘、不写日志。
TXT
}

guide() {
    cat <<'TXT'
==================================================================
 backguard 逃生恢复 — 目录里有什么、怎么取回一个文件
==================================================================

1) 目录含义（引擎仓库是完整备份的事实源，timeline 只是可读账本）

   borg-config/  或  config/    配置文件档案（引擎仓库）
   borg-files/   或  files/      个人文件档案
   borg-system/  或  system/     系统状态档案
   timeline/<设备>/YYYY/MM/DD/HHMM-标签/
        MANIFEST.txt        明文摘要（只有目录级证据，永不含完整文件名）
        STORY.md            这次备份变了什么（自然语言）
        restore.md          恢复步骤
        manifest.json.enc   完整文件清单（age 密封，含路径与大小）
        exclusions.json     排除规则
   timeline/<设备>/rescue-test.txt   最近一次恢复演练的结果与日期

2) 定位文件（两条路，任选）

   A. 直接问引擎——不需要 age：
        ./rescue.sh --base <目录> --class files --find 关键词
      列出归档内匹配的路径，那串路径就是 --get 的入参。

   B. 问密封账本——需要恢复材料之一：
        路径 A（日常，本机主身份）   --identity <age/identity.txt>
        路径 B（救援，只有恢复码）   --recovery <age/recovery-identity.enc>
                                     → age 提示输入 passphrase 时填恢复码
      账本给的是跨档案结果与文件大小，适合「记得叫什么但不确定在哪个档案」。

3) 取回

        ./rescue.sh --base <目录> --class files --get <路径> --to ~/恢复目录

   归档里存的是「剥掉前导 / 的绝对路径」，文件落在
   ~/恢复目录/Users/… 或 ~/恢复目录/etc/… 之下，确认无误再放回原位。
   取历史快照加 --archive <归档名>（--list 可查）。

4) 恢复材料从哪来（当前 v0 的实话）

   age 身份目录（identity.txt / recovery-identity.enc）与 secrets.env 一样
   **不随备份上云**——凭据纪律优先。所以必须另存一份在机器之外：抄恢复码（纸质）
   + 拷贝整个密钥目录（默认 ~/.config/partiverse-backup/age）到密码管理器或 U 盘。
   只有纸质恢复码还不够：路径 B 需要 recovery-identity.enc 这个文件本身。

5) 平时就该验一次

   ./drill.sh --force   在主机器上解封 → 抽样 → 实取 → 校验，写 rescue-test.txt。
   夜间备份每 30 天自动跑一次同一条链路。
==================================================================
TXT
}

# 递归删除只允许作用于本脚本刚创建的 mktemp 目录（AGENTS.md §3.3 的白名单口径）
cleanup() {
    [[ -n "${WORK:-}" ]] || return 0
    if [[ "$WORK" == "${WORK%/bg-rescue.*}" ]]; then
        warn "跳过清理（不是本脚本的临时目录）: $WORK"
        return 0
    fi
    if [[ -d "$WORK" ]]; then rm -rf "$WORK"; fi
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --guide)     MODE="guide"; shift;;
        --list)      MODE="list"; shift;;
        # --find 既能配 --class（问引擎）也能配 --ledger（问账本）：
        # 谁先出现谁定动作，后到的只做修饰，否则 --ledger --find 会被改写成引擎查询
        --find)      [[ -n "$MODE" ]] || MODE="find"; FIND="${2:-}"; [[ -n "$FIND" ]] || error "--find 需要一个模式"; shift 2;;
        --get)       MODE="get"; GET="${2:-}"; [[ -n "$GET" ]] || error "--get 需要一个路径"; shift 2;;
        --ledger)    MODE="ledger"; shift;;
        --base)      BASE="${2:-}"; shift 2;;
        --device)    DEVICE="${2:-}"; shift 2;;
        --class)     CLASS="${2:-}"; shift 2;;
        --archive)   ARCHIVE="${2:-}"; shift 2;;
        --to)        TO="${2:-}"; shift 2;;
        --snapshot)  SNAPSHOT="${2:-}"; shift 2;;
        --identity)  IDENTITY="${2:-}"; shift 2;;
        --recovery)  RECOVERY="${2:-}"; shift 2;;
        --engine)    ENGINE="${2:-}"; shift 2;;
        -h|--help)   usage; exit 0;;
        *)           usage >&2; error "未知参数: $1";;
    esac
done

[[ -n "$MODE" ]] || { usage >&2; error "缺动作：--guide / --list / --find / --get / --ledger"; }
if [[ "$MODE" == "guide" ]]; then guide; exit 0; fi
[[ -d "$BASE" ]] || error "备份根不存在: ${BASE}（云端副本请指向 <挂载点>/<系统标识>，或用 --base 指定）"

CLASSES=(config files system)

cls_valid() {
    local c
    for c in "${CLASSES[@]}"; do [[ "$c" == "$1" ]] && return 0; done
    return 1
}

count_lines() { printf '%s\n' "$1" | grep -c . || true; }

# 引擎二进制：env 显式指定优先，其次 PATH（SC2155：声明与赋值拆两行）
BORG="${BORG:-}"
if [[ -z "$BORG" ]]; then BORG="$(command -v borg || true)"; fi
RESTIC="${RESTIC:-}"
if [[ -z "$RESTIC" ]]; then RESTIC="$(command -v restic || true)"; fi
AGE_BIN="$(command -v age || command -v rage || true)"

# 两种布局：<base>/borg-<cls>（本机）与 <base>/<cls>（云端副本）
repo_for() {
    if [[ -d "$BASE/borg-$1" ]]; then
        echo "$BASE/borg-$1"
    elif [[ -d "$BASE/$1" ]]; then
        echo "$BASE/$1"
    else
        return 1
    fi
}

# restic 仓库有 snapshots/ 与 keys/，borg 1.x 仓库没有——据此判定
engine_of() {
    case "$ENGINE" in
        borg|restic) echo "$ENGINE"; return;;
        auto) ;;
        *) error "--engine 只接受 auto|borg|restic，收到: ${ENGINE}";;
    esac
    if [[ -d "$1/snapshots" && -d "$1/keys" ]]; then
        echo restic
    else
        echo borg
    fi
}

need_engine() {
    case "$1" in
        borg)   [[ -n "$BORG" ]]   || error "未找到 borg（Linux: apt/dnf install borgbackup，macOS: brew install borgbackup）";;
        restic) [[ -n "$RESTIC" ]] || error "未找到 restic（Linux: apt/dnf install restic，macOS: brew install restic）";;
    esac
}

# 时间轴下只有一个设备目录时直接用它；多于一个返回空，让调用方决定报不报错
detect_device() {
    [[ -n "$DEVICE" ]] && { echo "$DEVICE"; return 0; }
    [[ -d "$BASE/timeline" ]] || return 0
    local dirs
    dirs="$( (cd "$BASE/timeline" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | sort; true) )"
    [[ "$(count_lines "$dirs")" == "1" ]] || return 0
    printf '%s\n' "$dirs" | head -1
}

resolve_device() {
    [[ -n "$DEVICE" ]] && return 0
    local d
    d="$(detect_device || true)"
    [[ -n "$d" ]] || error "无法确定设备：请用 --device 指定（--list 会列出时间轴下的设备目录）"
    DEVICE="$d"
}

# 归档/快照列表。设备名可含 [ ] + 等正则元字符 → 一律字面量前缀匹配。
# stderr 保持透传：口令错、仓库错都必须在终端看得见，否则只剩「无归档」这句误导话。
# (; true) 中和 pipefail：管道任一段非零会炸掉整个赋值语句。
borg_archives() {  # $1=repo $2=前缀（空 = 全量）
    if [[ -n "$2" ]]; then
        ( "$BORG" list --short "$1" | awk -v p="$2" 'index($0, p) == 1' | sort; true )
    else
        ( "$BORG" list --short "$1" | sort; true )
    fi
}

# restic 0.19 没有 snapshots --short；表格行首是 8 位以上十六进制 ID
restic_archives() {  # $1=repo
    ( "$RESTIC" -r "$1" snapshots 2>/dev/null \
        | grep -E '^[0-9a-f]{8,}[[:space:]]' | awk '{print $1}'; true )
}

archives_for() {  # $1=repo $2=engine $3=class（borg 前缀 = <设备>-<类别>-，缺谁就少筛一层）
    case "$2" in
        borg)   borg_archives "$1" "${DEVICE:+$DEVICE-}${3:+$3-}";;
        restic) restic_archives "$1";;
    esac
}

latest_archive() {  # $1=repo $2=engine $3=class
    local all
    all="$(archives_for "$1" "$2" "$3")"
    [[ -n "$all" ]] || return 1
    printf '%s\n' "$all" | tail -1
}

list_mode() {
    local cls repo eng all cnt
    info "备份根: $BASE"
    for cls in "${CLASSES[@]}"; do
        repo="$(repo_for "$cls" || true)"
        [[ -n "$repo" ]] || { info "[$cls] 无仓库"; continue; }
        eng="$(engine_of "$repo")"
        need_engine "$eng"
        # 列表阶段不强制 --device：没有设备上下文就全量列，让人先看清有什么
        all="$(archives_for "$repo" "$eng" "")"
        cnt="$(count_lines "$all")"
        info "[$cls] ${repo}（${eng}）: ${cnt} 个归档/快照"
        [[ -z "$all" ]] || printf '%s\n' "$all" | sed 's/^/    /'
    done
    [[ -d "$BASE/timeline" ]] || { info "无时间轴目录（$BASE/timeline）"; return 0; }
    info "时间轴设备目录（其下 YYYY/MM/DD/HHMM-标签 即可读层）:"
    local d snap_dirs
    for d in "$BASE"/timeline/*/; do
        [[ -d "$d" ]] || continue
        printf '  %s\n' "$(basename "$d")"
        # cd 进去取相对路径：变量拼进 sed 模式会被当正则读（路径里的 [ ] + 同理）
        # 快照目录名是 YYYY/MM/DD/HHMM-标签（4 层），排序按名字不按 ls 的 mtime
        # 这里不能用 (; true) 抹平失败：set -e 下裸赋值的管道若炸掉，整个 --list
        # 会无声退出，用户看到的是「没有输出」而不是「这个设备目录读不了」
        if ! snap_dirs="$(cd "$d" && find . -mindepth 4 -maxdepth 4 -type d | sed 's|^\./||' | sort -r | head -5)"; then
            warn "  无法列出快照目录（${d}）——权限或磁盘问题？继续看下一个设备"
            continue
        fi
        [[ -z "$snap_dirs" ]] || printf '%s\n' "$snap_dirs" | sed 's/^/    /'
    done
}

# 设备目录 → 最新快照目录（YYYY/MM/DD/HHMM-标签，字典序即时间序）
latest_snapshot() {
    resolve_device
    local s
    s="$( (find "$BASE/timeline/$DEVICE" -mindepth 4 -maxdepth 4 -type d 2>/dev/null \
            | sort | tail -1; true) )"
    [[ -n "$s" ]] || error "无时间轴快照: $BASE/timeline/$DEVICE"
    echo "$s"
}

# 解封后的账本 → 「class<TAB>path<TAB>size<TAB>raw」逐行。
# 纯 awk 状态机，只认我们自己写入的 schema（format=backguard/manifest/1，
# json.dumps(indent=1) 下每字段一行）；不依赖 Python。
# 已知边界：路径里的 JSON 转义（\" 与 \\）按字面输出——要精确路径以 --find 的引擎列表为准。
ledger_entries() {  # $1=解开的 manifest.json
    awk '
        /^ *"(config|files|system)": \{/ {
            cls=$0; sub(/^ *"/, "", cls); sub(/".*/, "", cls); next
        }
        /^ *"path": / { p=$0; sub(/^ *"path": *"/, "", p); sub(/",?$/, "", p); have=1; next }
        /^ *"size": / { sz=$0; sub(/^ *"size": */, "", sz); sub(/[, ].*$/, "", sz); next }
        /^ *"raw": /  { r=$0; sub(/^ *"raw": *"/, "", r); sub(/",?.*/, "", r);
                        if (r ~ /^null/) r=""; next }
        /^ *\},?$/    { if (have) printf "%s\t%s\t%s\t%s\n", cls, p, sz, r;
                        have=0; p=""; sz=""; r="" }
    ' "$1"
}

# 把 manifest.json.enc 解到 $WORK/manifest.json（两条恢复路径任选其一）
open_ledger() {
    local enc="$1" rec="$WORK/recovery-identity.txt"
    [[ -n "$AGE_BIN" ]] || error "未找到 age（Linux: apt/dnf install age，macOS: brew install age）"
    if [[ -n "$IDENTITY" ]]; then
        [[ -f "$IDENTITY" ]] || error "主身份文件不存在: $IDENTITY"
        "$AGE_BIN" -d -i "$IDENTITY" -o "$WORK/manifest.json" "$enc" \
            || error "主身份解封失败（身份文件与密文不配对？）: $enc"
    elif [[ -n "$RECOVERY" ]]; then
        [[ -f "$RECOVERY" ]] || error "recovery-identity.enc 不存在: $RECOVERY"
        info "路径 B：接下来 age 提示输入 passphrase —— 填你抄写的恢复码"
        # 私钥明文只存在于临时目录，退出时由 cleanup 的白名单守卫删除
        "$AGE_BIN" -d -o "$rec" "$RECOVERY" || error "恢复码未能解开救援身份"
        "$AGE_BIN" -d -i "$rec" -o "$WORK/manifest.json" "$enc" \
            || { rm -f "$rec"; error "账本解封失败（身份与密文不配对？）"; }
        rm -f "$rec"
    else
        error "解封账本需要恢复材料：--identity <age/identity.txt> 或 --recovery <age/recovery-identity.enc>"
    fi
}

# 定位到「某个仓库的某个归档」；把结果回填到全局，供 find/get 共用
pick_target() {
    [[ -n "$CLASS" ]] || error "需要 --class（config | files | system）"
    cls_valid "$CLASS" || error "--class 只接受 config|files|system，收到: $CLASS"
    TARGET_REPO="$(repo_for "$CLASS" || true)"
    [[ -n "$TARGET_REPO" ]] || error "找不到 ${CLASS} 档案仓库（${BASE}/borg-${CLASS} 或 ${BASE}/${CLASS}）"
    TARGET_ENG="$(engine_of "$TARGET_REPO")"
    need_engine "$TARGET_ENG"
    [[ "$TARGET_ENG" == restic ]] || resolve_device   # restic 快照 ID 不含设备名
    if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="$(latest_archive "$TARGET_REPO" "$TARGET_ENG" "$CLASS" || true)"
        [[ -n "$ARCHIVE" ]] || error "[$CLASS] 无归档可取（--device 是否给对？）"
        info "使用最新归档: $ARCHIVE"
    fi
}

find_mode() {
    pick_target
    local lst="$WORK/list.txt" hits
    # 引擎列表失败与「没有匹配」必须分开说：前者不能被后者的话说成成功
    # borg 1.4.5 实测：归档内路径清单走 `borg list --short repo::归档`（stdout 干净）；
    # `extract --list` 把同一份清单打到 **stderr**，重定向 stdout 只会拿到空文件
    case "$TARGET_ENG" in
        borg)   "$BORG" list --short "$TARGET_REPO::$ARCHIVE" > "$lst" \
                    || error "borg 列归档失败: $ARCHIVE";;
        restic) "$RESTIC" -r "$TARGET_REPO" ls "$ARCHIVE" 2>/dev/null \
                    | grep -v '^snapshot ' > "$lst" || error "restic 列快照失败: $ARCHIVE";;
    esac
    # grep -F：模式是字面量（文件名里的 [ ] . 不该被当正则读）
    hits="$(grep -F -- "$FIND" "$lst" || true)"
    if [[ -n "$hits" ]]; then
        printf '%s\n' "$hits"
        info "$(count_lines "$hits") 条匹配 —— 取回: ./rescue.sh --base <目录> --class $CLASS --archive $ARCHIVE --get <路径> --to <目录>"
    else
        info "无匹配「${FIND}」（换关键词，或用 --ledger 查跨档案账本）"
    fi
}

get_mode() {
    pick_target
    [[ -n "$TO" ]] || error "--get 需要 --to <目标目录>"
    mkdir -p "$TO"
    TO="$(cd "$TO" && pwd)"
    info "取回 [$CLASS] $ARCHIVE :: $GET → $TO"
    case "$TARGET_ENG" in
        # borg extract 没有 --destination（1.4 实测）：解包路径相对 cwd，必须先进目标目录
        borg)   (cd "$TO" && "$BORG" extract "$TARGET_REPO::$ARCHIVE" "$GET") \
                    || error "borg extract 失败: $GET";;
        restic) "$RESTIC" -r "$TARGET_REPO" restore "$ARCHIVE" --include "$GET" --target "$TO" \
                    || error "restic restore 失败: $GET";;
    esac
    local got
    got="$(find "$TO" -type f | grep -c . || true)"
    # 「解开了归档但一个文件都没落下来」不能算成功：路径写错、大小写差一个字符
    # 都会到这里静默返回 0，用户看到的是空目录
    [[ "$got" -gt 0 ]] || error "没有取回任何文件——路径请从 --find 的输出原样复制: $GET"
    success "已取回（$TO 下共 ${got} 个文件）"
    info "归档内是剥掉前导 / 的绝对路径，文件在 $TO/Users/… 或 $TO/etc/… 下"
}

ledger_mode() {
    local snap enc fmt rows n
    snap="$SNAPSHOT"
    [[ -n "$snap" ]] || snap="$(latest_snapshot)"
    [[ -d "$snap" ]] || error "快照目录不存在: $snap"
    enc="$snap/manifest.json.enc"
    [[ -f "$enc" ]] || error "快照内没有密封账本: ${enc}（该次备份未密封，或 --snapshot 指错）"
    open_ledger "$enc"
    fmt="$(sed -n 's/^ *"format": *"\([^"]*\)".*/\1/p' "$WORK/manifest.json" | head -1)"
    [[ "$fmt" == "backguard/manifest/1" ]] \
        || warn "账本格式非预期（${fmt:-空}）——下面的结果可能不全"
    info "快照: $(basename "$snap") · 格式 ${fmt:-未知} · [类别] 路径 (大小) + 归档内取回路径"
    rows="$(ledger_entries "$WORK/manifest.json")"
    [[ -z "$FIND" ]] || rows="$(printf '%s\n' "$rows" | grep -F -- "$FIND" || true)"
    # 明文清单用完即删（隐私红线：完整文件名只存在于密文账本）
    rm -f "$WORK/manifest.json"
    if [[ -z "$rows" ]]; then
        info "账本内无匹配「${FIND}」"
    else
        printf '%s\n' "$rows" \
            | awk -F'\t' '{ k = ($4 == "" ? $2 : $4);
                            printf "  [%s] %s (%s B)\n      取回: %s\n", $1, $2, $3, k }'
        n="$(count_lines "$rows")"
        info "${n} 条匹配"
    fi
    success "账本查询完成（明文清单已删除，未写入任何日志）"
}

TARGET_REPO="" TARGET_ENG=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bg-rescue.XXXXXX")"
trap cleanup EXIT

case "$MODE" in
    list)   list_mode;;
    find)   find_mode;;
    get)    get_mode;;
    ledger) ledger_mode;;
esac
