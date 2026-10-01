#!/usr/bin/env bash
#================================================================
# Partiverse Backup System — 跨平台统一备份脚本 v6
# Linux / macOS (borg)  |  Windows (restic via rclone)
# 用法: ./backup.sh
#================================================================
set -euo pipefail
# 出错时打印行号与命令；::error:: 会成为 CI 检查注解（匿名可查）
trap 'error "line ${LINENO}: ${BASH_COMMAND}"; echo "::error::backup.sh line ${LINENO}: ${BASH_COMMAND}"; [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "**ERR** line ${LINENO}: \`${BASH_COMMAND}\`" >> "$GITHUB_STEP_SUMMARY"' ERR

# ---------- 彩色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

# ---------- 平台检测 ----------
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Linux*)     PLATFORM=linux;;
    Darwin*)    PLATFORM=macos;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows;;
    *)          error "FATAL: unknown platform $PLATFORM"; exit 1;;
esac

# ---------- 目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# run 边界行的耗时起点：从脚本入口算，不含「config 加载花了多久」这段日志里看不见的空白
RUN_START_TS="$(date +%s)"
# 本轮的代码基：部署树是纯 checkout，「哪一轮跑的什么代码」只能靠这个 SHA 回答
# （run 边界行与 CLOUD-VERIFY.txt 共用；取不到就是 nogit，不报错）
RUN_GIT_SHA="$( { git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || true; } )"
RUN_GIT_SHA="${RUN_GIT_SHA%%$'\n'*}"
[[ "${RUN_GIT_SHA}" =~ ^[0-9a-f]{7,40}$ ]] || RUN_GIT_SHA=nogit
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
LOG_DIR="$HOME/.local/share/partiverse-backup"
# 全程 umask 077：本次运行新建的每个文件（backup.log / sem.log / drill.log /
# preflight-latest.json / run-*.json / 引擎仓库）建出来就是私有的——备份产物没有任何
# 需要同机可读的东西，borg 自己也建议仓库目录 700。只靠后面 chmod 列举会漏掉「本次
# 运行中途才新建」的日志——真机 10-01 实测：列举式 chmod 赶不上 sem.log/drill.log，
# 它们仍是 0644）。
umask 077
mkdir -p "$CONF_DIR" "$LOG_DIR"
# 老部署留下的 0755 目录就地收紧：CONF_DIR 底下是 secrets.env 与 age/ 私钥，LOG_DIR
# 底下是含引擎输出完整路径的日志；父目录 ~/.config、~/.local/share 常被 mkdir -p 建成 755
chmod 700 "$CONF_DIR" "$LOG_DIR" 2>/dev/null || true

# ---------- 加载配置 ----------
if [[ -f "$CONF_DIR/config.sh" ]]; then
    source "$CONF_DIR/config.sh"
else
    error "配置文件不存在: $CONF_DIR/config.sh"
    info "运行 ./init.sh（Linux/macOS）或 .\\backup.ps1 -Task Init（Windows），详见 DEPLOY.md"
    exit 1
fi

# ---------- 凭证加载 ----------
load_secrets() {
    if [[ -f "$CONF_DIR/secrets.env" ]]; then
        set -a; source "$CONF_DIR/secrets.env"; set +a
    fi
}

# ---------- 依赖检查 ----------
check_deps() {
    local rc=0
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            local extra_bin=""
            for dir in "$HOME/bin" "$HOME/.local/bin" "$SCRIPT_DIR/bin"; do
                [[ -x "$dir/$cmd" ]] && { extra_bin="$dir/$cmd"; break; }
            done
            if [[ -n "$extra_bin" ]]; then
                info "  $cmd 在 $extra_bin"
            else
                error "缺少依赖: $cmd"
                rc=1
            fi
        fi
    done
    return $rc
}

# ---------- Borg 备份单档案 ----------
backup_borg_class() {
    local cls="$1"; local repo="$2"; local arc_name="$3"
    # nameref 引用 config.sh 中的索引数组 BORG_INCLUDES_$cls / BORG_EXCLUDES_$cls
    local -n inc_ref="BORG_INCLUDES_$cls"
    # shellcheck disable=SC2154  # exc_ref 经 eval 动态绑定
    eval "local -n exc_ref=\"BORG_EXCLUDES_$cls\""

    info "[$cls] 归档: $arc_name"

    if [[ ! -d "$repo" ]]; then
        info "[$cls] 初始化仓库: $repo"
        # borg init 不会自动创建父目录
        mkdir -p "$(dirname "$repo")"
        # 注意: 本函数在 || 列表中被调用，set -e 在函数体内失效，必须显式判错
        if ! BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" init --encryption=repokey "$repo" 2>&1 | tee -a "$LOG"; then
            error "[$cls] borg init 失败"
            echo "::error::[$cls] borg init failed: $(tail -n 3 "$LOG" 2>/dev/null | tr '\n' ' ' | cut -c1-250)"
            return 1
        fi
    fi

    set +e
    # shellcheck disable=SC2154  # exc_ref 由上方 eval 动态绑定
    BORG_PASSPHRASE="$BORG_PASSPHRASE" "$BORG" create \
        --stats --compression lz4 \
        "${exc_ref[@]}" \
        "$repo::$arc_name" \
        "${inc_ref[@]}" \
        2>&1 | tee -a "$LOG"
    local create_rc=${PIPESTATUS[0]}
    set -e

    if [[ $create_rc -ne 0 && $create_rc -ne 1 ]]; then
        error "[$cls] borg create 失败 (exit $create_rc)"
        echo "::error::[$cls] borg create exit $create_rc: $(tail -n 3 "$LOG" 2>/dev/null | tr '\n' ' ' | cut -c1-250)"
        return 1
    fi
    [[ $create_rc -eq 1 ]] && warn "[$cls] 部分路径不存在（已归档）"

    info "[$cls] 清理旧归档 (7d/4w/6m)..."
    # prune rc=1 = warning 级（tam 提示等），pipefail 下裸管道会炸整个备份——与 create 同等容忍
    set +e
    "$BORG" prune \
        --stats --keep-daily=7 --keep-weekly=4 --keep-monthly=6 \
        "$repo" 2>&1 | tee -a "$LOG"
    prune_rc=${PIPESTATUS[0]}
    set -e
    if [[ $prune_rc -ne 0 && $prune_rc -ne 1 ]]; then
        error "[$cls] borg prune 失败 (exit $prune_rc)"
        return 1
    fi
    [[ $prune_rc -eq 1 ]] && warn "[$cls] prune 带 warning (rc=1，已容忍)"
    return 0
}

# ---------- Restic 备份单档案 (Windows) ----------
backup_restic_class() {
    local cls="$1"; local repo_path="$2"; local arc_name="$3"
    local -n inc_ref="RESTIC_INCLUDES_$cls"
    # shellcheck disable=SC2154  # exc_ref 经 eval 动态绑定
    eval "local -n exc_ref=\"RESTIC_EXCLUDES_$cls\""

    info "[$cls] 归档: $arc_name"

    "$RESTIC" -r "$repo_path" init 2>&1 | \
        grep -v "repository already exists" || true

    set +e
    # shellcheck disable=SC2154  # exc_ref 由上方 eval 动态绑定
    "$RESTIC" backup \
        --host "$DEVICE_ID" \
        "${exc_ref[@]}" \
        "${inc_ref[@]}" \
        2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e

    if [[ $rc -ne 0 ]]; then
        error "[$cls] restic backup 失败 (exit $rc)"; return 1
    fi

    info "[$cls] 清理旧归档..."
    "$RESTIC" forget \
        --keep-daily=7 --keep-weekly=4 --keep-monthly=6 \
        -r "$repo_path" 2>&1 | tee -a "$LOG"
}

# ---------- 云端同步（rclone 统一管理） ----------
# 存储目标 = rclone remote，由用户自行 rclone config 增删（WebDAV/B2/S3/SFTP/NAS…）。
# BACKUP_TARGETS=("remote:子路径" ...)，设备段 <SYSTEM_ID> 自动追加避免多设备互覆；
# 兼容旧单目标写法 WEBDAV_REMOTE(+WEBDAV_ROOT)。
# 用 copy 而非 sync：本地 prune 后旧归档不应从云端删除，云端保留全部历史
# 云端推送计数（main 汇总）：本地三个档案都成功 ≠ 云端拿到副本
cloud_total=0
cloud_failed=0
# 调用方可在 sync_target 前设置要排除的模式（每项一个 --exclude，见时间轴推送）
SYNC_EXCLUDES=()
sync_target() {
    local local_path="$1"; local dest="$2"
    # ":/" 会被子类后端解析成文件系统绝对路径——
    # 空子路径的目标（"remote:" + "/设备/..."）必须归一为 "remote:设备/..."
    dest="$(sed 's|:/*|:|g' <<< "$dest")"  # BSD sed 兼容（不支持 \+）
    info "rclone copy -> $dest"
    "$RCLONE" mkdir "$dest" 2>>"$LOG" || true
    set +e
    local -a ex_args=()
    local _e
    for _e in ${SYNC_EXCLUDES[@]+"${SYNC_EXCLUDES[@]}"}; do ex_args+=(--exclude "$_e"); done
    "$RCLONE" copy "$local_path/" "$dest/" \
        --bwlimit 10M --transfers 2 --checkers 4 \
        ${ex_args[@]+"${ex_args[@]}"} \
        --log-file "$RCLONE_LOG" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    cloud_total=$((cloud_total + 1))
    if [[ $rc -eq 0 ]]; then
        success "[rclone] $dest 同步完成"
    else
        # 失败计数由 main 汇总：本地成功 ≠ 云端有副本，不能只留一行 WARN 就宣布完成
        cloud_failed=$((cloud_failed + 1))
        warn "[rclone] $dest 同步失败 (rc=$rc)"
    fi
    return 0
}

# 解析备份目标：兼容旧 WEBDAV_REMOTE；无任何目标时仅本地备份。
# 调用后 BACKUP_TARGETS 恒为已定义数组（可能为空）——set -u 下安全。
resolve_targets() {
    # [*]+x：shellcheck 认可的「数组已定义？」测试（[@] 在 [ ]/[[ ]] 里触发 SC2198/2199）
    if [ -z "${BACKUP_TARGETS[*]+x}" ]; then
        BACKUP_TARGETS=()
    fi
    if [[ ${#BACKUP_TARGETS[@]} -eq 0 && -n "${WEBDAV_REMOTE:-}" ]]; then
        BACKUP_TARGETS=("${WEBDAV_REMOTE}:${WEBDAV_ROOT:-}${SYSTEM_ID}")
    fi
}

# ---------- 云端可信副本的清单级自证（research/11 A6 L1） ----------
# 为什么「copy 退出 0」不算证据：123Pan 这条 remote 上 rclone 拿不到 modtime/hash，比较
# 退化成**只比大小**（AGENTS §2）。10-01 实测过后果——borg 换口令后三个 `config` 从 700 B
# 变成 700 B，nightly 报告「同步完成」，云端躺着的仍是轮换前那份。所以每轮备份后自己
# 对平一次：本地每个对象都必须在云端存在且尺寸一致（**单向包含**——云端只增不减，
# 本地 prune 掉的历史副本仍留在云上，多出来不算失败）。
# 分层：L1 清单级（这里，零提取流量）抓「没上去 / 少一份 / 云端被改动」；
# 「同长度不同内容」L1 天生抓不住，由仓库 `config` 的**内容哈希**（几百字节，key blob
# 就在里面，正是 10-01 那次没传播的东西）单独一档，再加 L2 月度逐文件哈希、L3 异机盲恢复。
# 网盘抖动记 UNKNOWN：既不改退出码也不算证成——把 flake 报成 FAIL 会让告警通道失去信任。
# 不一致里有一类是**已知能当场修好**的（仓库 config 的同长度重写）：先 forcing 补传再复核，
# 修好了记 HEALED（本轮结论依旧可信，但「云端刚躺着一份陈旧的 key blob」必须留痕）。
verify_failed=0
verify_unknown=0
verify_healed=0
VERIFY_LINES=()
CLOUD_VERIFY_REPORT=""

note_verify() {   # $1=检查名 $2=PASS|FAIL|SKIP|UNKNOWN|HEALED $3=详情
    VERIFY_LINES+=("$(printf '%-8s %-30s %s\n' "$2" "$1" "$3")")
    case "$2" in
        FAIL) verify_failed=$((verify_failed + 1)) ;;
        UNKNOWN) verify_unknown=$((verify_unknown + 1)) ;;
        HEALED) verify_healed=$((verify_healed + 1)) ;;
    esac
}

# macOS 无 sha256sum、Linux 无 shasum；launchd 的受限 PATH 里两者都在 /usr/bin。
SHA256_CMD=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA256_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA256_CMD="shasum -a 256"
fi
sha256_stdin() {
    [[ -n "$SHA256_CMD" ]] || return 1
    # shellcheck disable=SC2086  # 两个词是命令本身，分词是有意的
    $SHA256_CMD | cut -d' ' -f1
}

# 本地清单：`<相对路径>\t<字节>`，按路径排序。`rescue-test.txt` 从对平里摘掉——红线 §1.1
# 规定它只留本地（它在云端出现另有专门一条 FAIL 检查），本地有、云端没有才是对的形状。
# 报告自己不用摘：run_cloud_verify 是**先比对、后落笔**，比对那一刻躺着的还是上一轮那份，
# 它已经随这一轮的时间轴推送上云了，两端同尺寸。
local_listing() {   # $1=root
    local root="$1" f sz out=""
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
        [[ -n "$sz" ]] || continue
        out+="${f#"$root"/}"$'\t'"$sz"$'\n'
    done < <(find "$root" -type f ! -name 'rescue-test.txt' 2>/dev/null)
    printf '%s' "$out" | LC_ALL=C sort
}

# `rclone lsl` 每行是「size 日期 时间 路径」；路径可能含空格，所以摘掉前三个字段而不是
# 按空格切——输出统一成和本地一样的 `<路径>\t<size>` 并排序。
cloud_listing_from_lsl() {
    awk '{ sz=$1; p=$0;
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", p);
            printf "%s\t%s\n", p, sz }' | LC_ALL=C sort
}

# 差异样本只到**目录**：这份报告是明文产物且随时间轴上云，红线 §1.1 的例外只有
# rescue-test.txt 那一个。定位到目录已经够用——要补传的是那一棵子树，不是一个神秘文件名。
dir_sample() {   # $1=相对路径清单（换行分隔）→ 前 3 条所在目录，去重后空格连接
    local p
    { printf '%s\n' "$1" | sed -n '1,3p'; } | {
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            if [[ "$p" == */* ]]; then printf '%s\n' "${p%/*}"; else printf '（根级）\n'; fi
        done
    } | LC_ALL=C sort -u | tr '\n' ' '
}

# 单个前缀的清单对平：$1=本地目录 $2=云端前缀 $3=检查名 $4=是否查隐私残留（1=是）
verify_one_prefix() {
    local root="$1" dest="$2" label="$3" privacy="${4:-}"
    local lstd cstd rc=0 missing bad extra miss_paths bad_paths
    [[ -d "$root" ]] || { note_verify "$label" "SKIP" "本地没有这一棵树（该类别没备份或路径变了）"; return 0; }
    lstd="$(local_listing "$root")"
    cstd="$( { "$RCLONE" lsl "$dest" 2>>"$RCLONE_LOG" | cloud_listing_from_lsl; } )" || rc=$?
    if [[ $rc -ne 0 ]]; then
        note_verify "$label" "UNKNOWN" "rclone lsl rc=${rc}（网盘抖动或该前缀读不出），这一项既没证成也没证败"
        return 0
    fi
    # 红线 §1.1 的自证面：`rescue-test.txt` 逐条写着抽样文件的完整路径，规定只留本地。
    # 推送环节的 --exclude 只挡**新**副本——10-01 真机上那条老副本就是这么一直躺在云端的。
    # 所以云端清单里只要出现这个名字就是违例，无论它是怎么上去的。
    # 只对时间轴前缀查：引擎仓库是 borg 自己的对象存储，同名文件不可能由我们推上去，
    # 逐类别查只会把报告灌满永远 PASS 的行。
    if [[ "$privacy" == "1" ]]; then
        if printf '%s\n' "$cstd" | cut -f1 | grep -qE '(^|/)rescue-test\.txt$'; then
            note_verify "privacy @ ${label#* @ }" "FAIL" "云端时间轴里有 rescue-test.txt（红线 §1.1：它带完整文件名，只准留本地；--exclude 挡不住历史副本，得手工删）"
        else
            note_verify "privacy @ ${label#* @ }" "PASS" "云端时间轴没有 rescue-test.txt"
        fi
    fi
    # 三条计数都走 `|| true`：grep -c 命中 0 行时 rc=1，pipefail 下会把这轮自证自己炸掉
    miss_paths="$( { comm -23 <(printf '%s\n' "$lstd" | cut -f1) <(printf '%s\n' "$cstd" | cut -f1); } || true )"
    bad_paths="$( { join -t$'\t' <(printf '%s\n' "$lstd") <(printf '%s\n' "$cstd") \
        | awk -F'\t' '$2!=$3 { print $1 }'; } || true )"
    missing="$(printf '%s\n' "$miss_paths" | grep -c . || true)"
    bad="$(printf '%s\n' "$bad_paths" | grep -c . || true)"
    extra="$( { comm -13 <(printf '%s\n' "$lstd" | cut -f1) <(printf '%s\n' "$cstd" | cut -f1) | grep -c .; } || true )"
    if [[ "${missing:-0}" == "0" && "${bad:-0}" == "0" ]]; then
        note_verify "$label" "PASS" "本地 $(printf '%s\n' "$lstd" | grep -c . || true) 个对象云端全在且尺寸一致（云端另有 ${extra:-0} 份本地已裁的历史副本，按只增不减不计失败）"
        return 0
    fi
    # 差异样本**只到目录**，不带文件名：这份报告是明文产物且随时间轴上云，红线 §1.1 说得很
    # 死——例外只有 rescue-test.txt 那一个，而它只留本地。今天被校验的两棵树（时间轴产物 /
    # 引擎 chunk）名字都是系统生成的，看着无害，但「反正调用点选的是我们自己的目录」不是一道
    # 闸门：校验面哪天扩到 system-meta/（mounts/crontab 转储，里面全是用户路径）就会顺着这里漏。
    # 定位到目录已经够用——要补传的是那一棵子树，不是一个神秘文件名。
    note_verify "$label" "FAIL" "云端缺 ${missing:-0} 个 / 尺寸不符 ${bad:-0} 个；缺失所在目录：$(dir_sample "$miss_paths")；尺寸不符所在目录：$(dir_sample "$bad_paths")"
}

# 仓库 config 的内容哈希：这是 10-01 那次「同长度重写永远推不上云」的正面对策。
# 发现不一致不能只一报了事——在这条 remote 上它永远不会自己修好（尺寸相同 → rclone 直接
# 跳过），所以按 AGENTS §2 的办法**显式 forcing 补传那一个文件**再复核：修好了记 HEALED，
# 修不好才是 FAIL。判平只认内容哈希，「copy 退出 0」在这条 remote 上什么都没证明。
verify_config_hash() {   # $1=本地仓库目录 $2=云端仓库前缀 $3=检查名
    local repo="$1" dest="$2" label="$3"
    local lhash="" chash="" stale_cloud="" rc=0 heal_rc=0
    [[ -f "$repo/config" ]] || { note_verify "$label" "SKIP" "本地仓库没有 config"; return 0; }
    [[ -n "$SHA256_CMD" ]] || { note_verify "$label" "SKIP" "本机既无 sha256sum 也无 shasum"; return 0; }
    lhash="$(sha256_stdin < "$repo/config")"
    [[ -n "$lhash" ]] || { note_verify "$label" "UNKNOWN" "本地 config 哈希失败"; return 0; }
    chash="$( { "$RCLONE" cat "$dest/config" 2>>"$RCLONE_LOG" | sha256_stdin; } )" || rc=$?
    if [[ $rc -ne 0 || -z "$chash" ]]; then
        note_verify "$label" "UNKNOWN" "云端 config 读取失败 (rc=${rc})"
        return 0
    fi
    if [[ "$chash" == "$lhash" ]]; then
        note_verify "$label" "PASS" "sha256 ${lhash:0:12}… 两端一致（key blob 云端有新版）"
        return 0
    fi
    # 先把云端那份陈旧证据留下来（报告里要能看出它躺了多久），再补传
    stale_cloud="$chash"
    "$RCLONE" copy -I "$repo" "$dest" --include "config" >>"$RCLONE_LOG" 2>&1
    heal_rc=$?
    rc=0
    chash="$( { "$RCLONE" cat "$dest/config" 2>>"$RCLONE_LOG" | sha256_stdin; } )" || rc=$?
    if [[ $rc -ne 0 || -z "$chash" ]]; then
        note_verify "$label" "UNKNOWN" "强制补传 (rc=${heal_rc}) 之后云端 config 反而读不到了"
    elif [[ "$chash" == "$lhash" ]]; then
        note_verify "$label" "HEALED" "云端原是 ${stale_cloud:0:12}…（同长度重写正是被「只比大小」静默丢掉的那类），已强制补传成 ${lhash:0:12}…"
    else
        note_verify "$label" "FAIL" "强制补传 (rc=${heal_rc}) 后仍 本地 ${lhash:0:12}… ≠ 云端 ${chash:0:12}…——云端副本不可信"
    fi
}

# 全量自证：每个目标 × 时间轴 + 每个类别仓库，结论写进时间轴根级 CLOUD-VERIFY.txt。
# repo_pairs 由 main 维护（元素 `类别:本地仓库路径`）——bash 的动态作用域让被调函数看得见
# main 的 local，这里不另设全局；用全局变量而不是 nameref 传数组，是为了不额外抬高对
# bash 4.3 的版本要求（AGENTS §2 的 3.2/5 双轨）。
run_cloud_verify() {
    local tgt dest pair cls repo
    VERIFY_LINES=()
    verify_failed=0
    verify_unknown=0
    verify_healed=0
    for tgt in "${BACKUP_TARGETS[@]}"; do
        dest="$(sed 's|:/*|:|g' <<< "${tgt}/${SYSTEM_ID}")"
        verify_one_prefix "$BACKUP_BASE/timeline" "$dest/timeline" "timeline @ ${tgt}" 1
        for pair in ${repo_pairs[@]+"${repo_pairs[@]}"}; do
            cls="${pair%%:*}"
            repo="${pair#*:}"
            verify_one_prefix "$repo" "$dest/$cls" "repo:$cls @ ${tgt}"
            verify_config_hash "$repo" "$dest/$cls" "config:$cls @ ${tgt}"
        done
    done

    CLOUD_VERIFY_REPORT="$BACKUP_BASE/timeline/CLOUD-VERIFY.txt"
    {
        printf '# 云端副本自证（A6 L1）——每轮备份后跑一次，零提取流量\n'
        printf '# 生成时间: %s   代码基: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${RUN_GIT_SHA:-nogit}"
        printf '# 判定口径: 单向包含。本地每个对象都必须在云端且尺寸一致；云端多出来的是本地\n'
        printf '#   已被保留策略裁掉的历史副本（云端只增不减，AGENTS §1.4），不计失败。\n'
        printf '#   同长度不同内容这一档 L1 抓不住，所以仓库 config 单独走内容哈希（下面\n'
        printf '#   config: 那几条）：不一致就当场 forcing 补传那一个文件再复核——修好了记\n'
        printf '#   HEALED（云端曾躺着陈旧 key blob，得留痕），修不好才是 FAIL。其余文件由\n'
        printf '#   L2 月度逐文件哈希与 L3 异机盲恢复覆盖。\n'
        printf '# 本文件随**下一轮**时间轴推送上云：比对发生在落笔之前，所以它比的是上一轮那份。\n'
        printf '# 汇总: checks=%d FAIL=%d UNKNOWN=%d HEALED=%d\n' \
            "${#VERIFY_LINES[@]}" "$verify_failed" "$verify_unknown" "$verify_healed"
        local vline
        for vline in ${VERIFY_LINES[@]+"${VERIFY_LINES[@]}"}; do printf '%s\n' "$vline"; done
    } > "$CLOUD_VERIFY_REPORT" 2>/dev/null || {
        warn "[verify] CLOUD-VERIFY.txt 写入失败（不阻断备份）"
        CLOUD_VERIFY_REPORT=""
    }
    chmod 600 "$CLOUD_VERIFY_REPORT" 2>/dev/null || true
}

# ---------- A2a：引擎仓库的存储完整性校验（roadmap 11 章 §2）----------
# 与恢复演练是两个不互相替代的问题：drill 证明「取回路径可用」，这一步证明「存着的字节
# 没腐化、还能解密解压缩」——3-2-1-1-0 末位那个 0 指的是后者。腐化只在**读取**时暴露，
# 所以按月主动把整仓读一遍（10-01 实测：真机 7.6 GB 是分钟级，且只跑月度窗口）。
# 引擎调用一律留在编排层：语义层是旁路、bg preflight 只做纯文件系统检查（红线 §1.3）。
integrity_failed=0
INTEGRITY_LINES=()
INTEGRITY_REPORT=""

note_integrity() {   # $1=检查名 $2=PASS|FAIL|SKIP|UNKNOWN $3=详情
    INTEGRITY_LINES+=("$(printf '%-8s %-14s %s\n' "$2" "$1" "$3")")
    if [[ "$2" == "FAIL" ]]; then
        integrity_failed=$((integrity_failed + 1))
    fi
    return 0
}

# 窗口判据用**产物自身的 mtime**当标记，与 rescue-test.txt 同一条机制（不用再养一个状态文件）。
# INTEGRITY_DAYS=0 就是「现在立刻跑一遍」的人工入口。
integrity_due() {
    [[ "${INTEGRITY_VERIFY:-1}" == "1" ]] || return 1
    [[ -f "$INTEGRITY_REPORT" ]] || return 0
    # 语义层缺失时 backup.sh 仍要能跑完（上面那组桩就是为这一刻），别去依赖它的 helper
    declare -F file_mtime >/dev/null || return 0
    local days="${INTEGRITY_DAYS:-30}" last now
    last="$(file_mtime "$INTEGRITY_REPORT")"
    now="$(date +%s)"
    [[ -n "$last" ]] || return 0
    (( now - last >= days * 86400 ))
}

# integrity_pairs 由 main 登记（元素 `类别:本地仓库路径`）。规矩与 repo_pairs 完全一样：
# 忘了登记＝这一类根本没跑，而整轮结论照样全绿（A6 第一版就是这么把缺陷藏过去的）。
run_integrity_check() {
    local pair cls repo rc out dur t0
    INTEGRITY_REPORT="$BACKUP_BASE/timeline/INTEGRITY.txt"
    integrity_due || {
        info "[integrity] 未到校验窗口（${INTEGRITY_DAYS:-30} 天内已跑过，或 INTEGRITY_VERIFY=0），跳过"
        return 0
    }
    INTEGRITY_LINES=()
    integrity_failed=0
    if [[ ${#integrity_pairs[@]} -eq 0 ]]; then
        # restic 侧（Windows）没有接：backup.ps1 连自证层都还没有（AGENTS §6 的 Windows 欠账
        # 同批）。这里**不写报告**——一份 checks=0 的「完整性通过」比没有更坏，它会被下一个人读成绿。
        warn "[integrity] 本轮没有可校验的 borg 仓库（restic 侧尚未接入），未做存储完整性校验"
        INTEGRITY_REPORT=""
        return 0
    fi
    for pair in ${integrity_pairs[@]+"${integrity_pairs[@]}"}; do
        cls="${pair%%:*}"
        repo="${pair#*:}"
        [[ -d "$repo" ]] || { note_integrity "borg:$cls" "UNKNOWN" "本地仓库目录读不到，这一项没证成也没证败"; continue; }
        t0="$(date +%s)"
        rc=0
        out="$("$BORG" check --verify-data "$repo" 2>&1)" || rc=$?
        dur=$(( $(date +%s) - t0 ))
        # 引擎原文只进本地日志（600、不上云）。明文报告一个字节都不抄：10-01 实测那类
        # 锁错误里带着**仓库绝对路径**，而这份文件随时间轴推上网盘。
        {
            printf '%s\n' "$out"
            printf '[integrity] borg check --verify-data %s -> rc=%s (%ss)\n' "$cls" "$rc" "$dur"
        } >>"$LOG"
        case "$rc" in
            0) note_integrity "borg:$cls" "PASS" "${dur}s 逐块解密校验通过（存储没腐化）" ;;
            1) note_integrity "borg:$cls" "FAIL" "${dur}s 后 rc=1：逐块校验发现坏数据，详见 ${LOG}" ;;
            *)
                # borg 把「仓库可能已毁」「用法错误」「拿不到锁」放在同一个 rc=2 档里（10-01 实测
                # 持锁即 rc=2）。只有明确报锁的才是 flake——并发的手工演练不该把用户叫醒；
                # 其余按最坏情况算，因为「potentially destroyed」正属于宁可误报的一档。
                # borg 1.4 的两条原文（10-01 实测）："Lock timeout 10000 ms exceeded" 与
                # "Failed to create/acquire the lock <仓库>/lock.exclusive (timeout)."。
                # 别把模式写松成 'lock.*timeout'——那会把任何同时含这两个词的真错误也放过去。
                if printf '%s\n' "$out" | grep -qiE 'lock timeout|failed to create/acquire the lock'; then
                    note_integrity "borg:$cls" "UNKNOWN" "${dur}s 拿不到仓库锁（有别的 borg 在跑，多半是手工演练），这一项没证成也没证败"
                else
                    note_integrity "borg:$cls" "FAIL" "${dur}s 后 rc=${rc}：不是锁问题，按「仓库可能已毁」处理，详见 ${LOG}"
                fi
                ;;
        esac
    done
    {
        printf '# 存储完整性校验（A2a）——按月把每个引擎仓库整仓读一遍\n'
        printf '# 生成时间: %s   代码基: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${RUN_GIT_SHA}"
        printf '# 它证明的是「存着的字节没坏、还能解密解压缩」；「取回路径可用」由 rescue-test.txt\n'
        printf '#   那条恢复演练负责，两者不互相替代。\n'
        printf '# 判据: rc=0 通过；rc=1 逐块校验发现坏数据＝FAIL（会告警）；rc>=2 是 borg 的\n'
        printf '#   fatal/用法/拿不到锁共用档，其中明确报 Lock timeout 的记 UNKNOWN（并发手工\n'
        printf '#   演练不该改变本轮结论），其余按最坏情况判 FAIL。\n'
        printf '# 引擎原文**不抄进本文件**：它是随时间轴上云的明文产物，而 borg 的错误行里会带\n'
        printf '#   仓库绝对路径。细节看本地日志（600、不上云）。\n'
        local line
        for line in ${INTEGRITY_LINES[@]+"${INTEGRITY_LINES[@]}"}; do printf '%s\n' "$line"; done
        printf '# 汇总: checks=%d FAIL=%d UNKNOWN=%d\n' \
            "${#INTEGRITY_LINES[@]}" "$integrity_failed" \
            "$( { printf '%s\n' ${INTEGRITY_LINES[@]+"${INTEGRITY_LINES[@]}"} | grep -c '^UNKNOWN' || true; } )"
    } > "$INTEGRITY_REPORT" 2>/dev/null || {
        warn "[integrity] INTEGRITY.txt 写入失败（不阻断备份）"
        INTEGRITY_REPORT=""
    }
    [[ -n "$INTEGRITY_REPORT" ]] && chmod 600 "$INTEGRITY_REPORT" 2>/dev/null || true
}

# ---------- 语义层（research/06：MANIFEST.txt/STORY.md/restore.md） ----------
# 非致命：语义层任何失败只告警，不影响备份结论
if [[ -f "$SCRIPT_DIR/semantic/semantic.sh" ]]; then
    source "$SCRIPT_DIR/semantic/semantic.sh"
else
    generate_semantic() { warn "semantic/semantic.sh 缺失，跳过语义层"; }
    notify_alert() { return 0; }
fi

# ---------- 系统元数据收集 ----------
collect_meta() {
    local meta_dir="$HOME/.local/share/partiverse-backup/system-meta"
    mkdir -p "$meta_dir"
    {
        echo "# Partiverse Backup System Meta — $(date -Iseconds)"
        echo "PLATFORM=$PLATFORM"
        echo "OS=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
        echo "HOSTNAME=$(hostname)"
        echo "KERNEL=$(uname -r)"
        "$BORG" --version 2>/dev/null | head -1
        "$RCLONE" --version 2>/dev/null | head -1
        [[ -n "${DOTFILES_REPO:-}" ]] && echo "DOTFILES_REPO=$DOTFILES_REPO"
        command -v dpkg >/dev/null && dpkg --get-selections 2>/dev/null | awk '$2=="install" {print $1}' > "$meta_dir/packages.txt"
        command -v flatpak >/dev/null && flatpak list 2>/dev/null | awk -F'\t' '{print $2}' > "$meta_dir/flatpak.txt"
        lsblk -f -o NAME,FSTYPE,SIZE,UUID,MOUNTPOINT > "$meta_dir/block-devices.txt" 2>/dev/null || true
        findmnt -rn -o SOURCE,TARGET,FSTYPE 2>/dev/null | grep -vE '^(sysfs|proc|devpts|tmpfs|cgroup|securityfs|pstore|bpf|debugfs|tracefs|fusectl|configfs|mqueue|hugetlbfs|efivarfs|none)' > "$meta_dir/mounts.txt" 2>/dev/null || true
        cat /etc/fstab > "$meta_dir/fstab.txt" 2>/dev/null || true
        command -v efibootmgr >/dev/null && efibootmgr -v > "$meta_dir/efiboot.txt" 2>/dev/null || true
        crontab -l > "$meta_dir/crontab.txt" 2>/dev/null || true
    } > "$meta_dir/manifest.txt" 2>&1 || true
    info "元数据已采集: $meta_dir/manifest.txt"
}

# ---------- 运行史可审计（research/11 A4）----------
# 两个互补的小东西，都不碰备份本体：
#
# 1) 轮转。现役日志里混着**早已修掉**的历史错误时，读日志的人（包括下一次会话里的
#    代理自己）会把死缺陷当现役的读——10-01 复核就在 backup.log 里为一条 09-30 的
#    rclone 500 花了十分钟才确认它不再复发。超阈值切一份带时间戳的副本，留最近 N 份。
#    删除按 `^<名字>\.[0-9]{8}-[0-9]{6}$` 白名单逐行判（AGENTS §3 注入面自查），
#    绝不 `ls | xargs rm`：路径含空格时那会把删除目标指到别处。
# 2) run 边界行。一轮一行写明「哪个代码基、退出码、跑了多久」——夜间出问题时，
#    「这条错误属于哪一轮、那轮部署点是什么 SHA」现在全靠翻提交时间猜。
rotate_log_if_oversized() {
    local f="$1"
    local size max keep base stale g
    [[ -f "$f" ]] || return 0
    size="$(wc -c < "$f" 2>/dev/null || true)"
    size="${size//[^0-9]/}"
    [[ -n "$size" ]] || return 0
    max="${SEM_LOG_MAX_BYTES:-4194304}"   # 4 MiB
    keep="${SEM_LOG_KEEP:-7}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=4194304
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=7
    (( size > max )) || return 0
    base="${f##*/}"
    if ! mv -- "$f" "${f}.$(date +%Y%m%d-%H%M%S)"; then
        warn "[log] 轮转失败（不阻断备份）: $f"
        return 0
    fi
    # 宽 glob + 窄守卫：`$f.*` 会把用户手放的 `backup.log.bak`、同名目录之类都捞进来，
    # 真正放行删除的是下面两道判定（形态正则 + 必须是普通文件）。反过来「窄 glob + 无守卫」
    # 看着安全，其实守卫一旦漏改就无人兜底——E2E 的变异验证正是从这两道各自摘一次咬住的。
    # -d 是必需的，不是排版偏好：`ls -1t "$f".*` 遇到目录操作数会**打印它的内容**而不是它
    # 自己（真机同名目录因此在候选清单里根本不存在，「挡住目录」那道守卫等于没被测到，
    # 摘掉它 E2E 照样绿）。不加 -d 还有第二个后果：ls 给目录内容加前缀（子目录里的项变成
    # `20240101-000000/a.txt`，含 / 或不再是 `<base>.<纯时间戳>`），形态守卫把它挡在
    # 删除之外——两个 bug 正好互相掩盖。
    stale="$( { ls -1dt -- "$f".* 2>/dev/null || true; } | tail -n +$((keep + 1)) )"
    [[ -n "$stale" ]] || return 0
    while IFS= read -r g; do
        [[ -n "$g" ]] || continue
        [[ "${g##*/}" =~ ^"${base}"\.[0-9]{8}-[0-9]{6}$ ]] || {
            warn "[log] 跳过非轮转形态: $g"; continue; }
        # 同名形态的**目录**也要挡住：rm -f 对目录是失败退出，而本函数在 main 的正常
        # 路径上——set -e 下轮转就会把整次备份带走（红线 §1.3 的反面）
        [[ -f "$g" ]] || { warn "[log] 跳过非普通文件: $g"; continue; }
        rm -f -- "$g"
    done <<< "$stale"
    info "[log] 已轮转 ${base}（${size} B > ${max} B，留最近 ${keep} 份）"
}

log_run_boundary() {
    local rc="$1" dur
    # LOG 在 main 里才定稿（config 可覆盖），早退的轮次没有落点就整条跳过——
    # 边界行本身属于旁路，绝不反过来把备份拖进 set -u 的致命变量错误
    [[ -n "${LOG:-}" ]] || return 0
    dur=$(( $(date +%s) - ${RUN_START_TS:-$(date +%s)} ))
    printf '[%s] run 边界: sha=%s rc=%s dur=%ss\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${RUN_GIT_SHA:-nogit}" "$rc" "$dur" >> "$LOG" || true
}

# ---------- 主流程 ----------
main() {
    LOG="${LOG:-$LOG_DIR/backup.log}"
    RCLONE_LOG="${RCLONE_LOG:-$LOG_DIR/rclone.log}"
    # 先轮转再登记边界：本轮那一行要落在**新**日志的开头附近，
    # 而上一轮的痕迹已经在切出去的副本里
    # 只轮转 $LOG_DIR 底下的标准日志：$LOG / $RCLONE_LOG 允许被 config 指到别处，
    # 而那两个路径已经在上面单独 chmod 过——对**用户指定**的路径动手删除，等于让一次
    # 日志尺寸超限变成「删掉某个不在 LOG_DIR 里的文件」，风险与收益完全不成比例。
    # 轮转清单是**点名**的，不像权限那样整树归一化：launchd.{out,err}.log 由 launchd
    # 持有句柄，mv 走之后它继续往旧 inode 写，输出就悄悄消失在副本里（比日志长更糟）。
    # runs/ 与 system-meta/ 有自己的留存策略（prune_run_jsons / 每轮覆写），preflight-latest.json
    # 是每轮重写的快照，都不该按尺寸切。
    local lf
    for lf in "$LOG_DIR/backup.log" "$LOG_DIR/rclone.log" "$LOG_DIR/sem.log" "$LOG_DIR/drill.log"; do
        rotate_log_if_oversized "$lf"
    done
    if [[ "$LOG" != "$LOG_DIR/backup.log" ]]; then
        info "[log] LOG 被 config 指到 LOG_DIR 之外（${LOG}），该文件不做轮转（只归一化权限）"
    fi
    trap 'log_run_boundary "$?"' EXIT
    # umask 只影响「新建」，已存在的得就地修。这里**不按文件名列举**：10-01 一夜实测漏过
    # 两次——先漏 runs/run-*.json（渲染前的**全量文件名清单**，真机单个 22 MB）与
    # system-meta/（mounts/crontab 转储），补齐清单后又漏 $CONF_DIR/age 子目录本身：
    # 09:36 nightly 把 $CONF_DIR 收紧成 700，而 age/ 仍是 0755、recipients.txt 仍 0644，
    # 只因 glob 写的是 *.log。备份产物没有任何需要同机可读的东西，所以整棵树统一收，
    # 一项都不靠点名（目录闸门会回退：重装、手工 chmod -R、新设备首备前）。
    # $BACKUP_BASE/borg-* 与 restic-* 不递归：仓库内文件由引擎自建即 600，仓库根已由
    # 下面 base_dir 的 700 挡住，为几千个 chunk 每轮全扫不划算。
    local base_dir="${BACKUP_BASE:-$HOME}"
    local perms_root
    # $LOG / $RCLONE_LOG 允许被 config 指到 LOG_DIR 之外，所以这两个单独点名
    chmod 600 "$LOG" "$RCLONE_LOG" 2>/dev/null || true
    for perms_root in "$CONF_DIR" "$LOG_DIR" "$base_dir/timeline"; do
        [[ -d "$perms_root" ]] || continue
        find "$perms_root" -type d ! -perm 700 -exec chmod 700 {} + 2>/dev/null || true
        find "$perms_root" -type f ! -perm 600 -exec chmod 600 {} + 2>/dev/null || true
    done
    chmod 700 "$base_dir" 2>/dev/null || true

    load_secrets

    if [[ -z "${BORG_PASSPHRASE:-}" && -z "${RESTIC_PASSWORD:-}" ]]; then
        error "未设置备份密码 (BORG_PASSPHRASE / RESTIC_PASSWORD)"
        info "运行 ./init.sh 或在 $CONF_DIR/secrets.env 中设置"
        exit 1
    fi
    # 子进程（borg/restic/语义层）经环境继承取用；不在命令行前缀传递凭据变量
    export BORG_PASSPHRASE RESTIC_PASSWORD

    if [[ "$PLATFORM" == windows ]]; then
        check_deps "$RCLONE" "$RESTIC" || exit 1
    else
        check_deps "$BORG" "$RCLONE" || exit 1
        collect_meta
    fi

    if [[ -d "$BACKUP_BASE" ]]; then
        local avail_gb
        # df -Pk 为 POSIX 写法，Linux/macOS/BSD 通用（-BG 是 GNU 专有，macOS 上报错）
        avail_gb=$(df -Pk "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
        if [[ "${avail_gb:-0}" -lt 5 ]]; then
            error "磁盘空间不足 (${avail_gb}GB < 5GB)，备份中止"
            exit 1
        fi
        info "磁盘剩余: ${avail_gb}GB"
    fi

    # ---------- 预检（research/08 T2.2）：对位「什么不会被有效备份」 ----------
    # bg 做文件系统检查（占位文件/.git 排除/磁盘）；编排层补引擎版本与凭据链。
    # error(2) 中止备份；warning(1) 继续并留在日志。SEM_PREFLIGHT=0 可关闭。
    if [[ "${SEM_PREFLIGHT:-1}" == "1" ]] && [[ "$PLATFORM" != windows ]]; then
        local -a pf_args=(--check-disk "${BACKUP_BASE:-$HOME}" --min-free-gb 5)
        local pf_cls pf_inc
        for pf_cls in config files system; do
            eval "local -n pf_inc_ref=\"BORG_INCLUDES_$pf_cls\""
            eval "local -n pf_exc_ref=\"BORG_EXCLUDES_$pf_cls\""
            # shellcheck disable=SC2154  # nameref 经上方 eval 动态绑定
            for pf_inc in "${pf_inc_ref[@]}"; do pf_args+=(--include "$pf_inc"); done
            # shellcheck disable=SC2154  # 同上
            pf_args+=(--excludes "${pf_exc_ref[@]}")
        done
        local pf_rc=0
        # --json-out 落盘供覆盖报告引用（research/08 T2.5）；文本照常进日志
        semantic_bg preflight --json-out "${LOG_DIR}/preflight-latest.json" "${pf_args[@]}" | tee -a "$LOG" || pf_rc=$?
        if [[ $pf_rc -eq 2 ]]; then
            error "preflight 发现致命问题，备份中止（修复后重跑；或 SEM_PREFLIGHT=0 跳过预检）"
            exit 1
        fi

        # 引擎版本下限（python 比较，避开 macOS sort 无 -V）
        if [[ -n "$BORG" ]]; then
            local bv
            bv="$("$BORG" --version 2>/dev/null | awk '{print $2}')"
            if ! python3 -c "import sys;sys.exit(0 if tuple(map(int,'${bv:-0}.0'.split('.')[:2]))>=(1,2) else 1)" 2>/dev/null; then
                warn "borg ${bv:-?} 低于最低支持版 1.2，建议升级"
            fi
        fi
        # 告警出口检查：没配 ntfy 时 notify_alert/notify_story 直接 return 0，
        # 「云端失败必须可见」这条红线在无人看日志时等于没有出口（真机 10-01 就是这样
        # 静默了一整夜）。只 warning，不阻断——ntfy 是可选 sidecar
        if [[ -z "${SEM_NTFY_URL:-}" ]]; then
            warn "未配置 SEM_NTFY_URL：云端失败告警与 STORY 推送都不会发出，失败只进日志"
        fi
        # 凭据外部化静默失效检测（research/05 §7）
        if [[ -n "${BORG_PASSCOMMAND:-}" ]]; then

            local pc="${BORG_PASSCOMMAND%% *}"
            if ! command -v "$pc" >/dev/null 2>&1; then
                error "BORG_PASSCOMMAND 引用的 $pc 不在 PATH——备份将失败，中止"
                exit 1
            fi
            if [[ "$pc" == "rbw" ]] && ! rbw unlocked >/dev/null 2>&1; then
                warn "rbw-agent 未解锁——备份时将挂起等待，可先执行 rbw unlock"
            fi
        fi

        # 备份目标 remote 存在性（rclone 统一管理，research/05 §7）
        resolve_targets
        if [[ ${#BACKUP_TARGETS[@]} -gt 0 && -n "${RCLONE:-}" ]]; then
            local tgt rname
            local -a targets_rc=()
            for tgt in "${BACKUP_TARGETS[@]}"; do
                rname="${tgt%%:*}"
                if ! "$RCLONE" listremotes 2>/dev/null | grep -qx "${rname}:"; then
                    error "备份目标 remote '$rname' 不在 rclone 配置中（rclone listremotes 查看）——中止"
                    targets_rc+=(bad)
                fi
            done
            [[ ${#targets_rc[@]} -eq 0 ]] || exit 1
        fi
    fi

    log "=== Backup STARTED ($PLATFORM) ==="
    log "Device: $DEVICE_ID | System: $SYSTEM_ID"
    resolve_targets
    if [[ ${#BACKUP_TARGETS[@]} -eq 0 ]]; then
        warn "未配置备份目标（BACKUP_TARGETS/WEBDAV_REMOTE 均空）——本次仅本地备份"
    fi

    local failed=0
    local -a sem_archives=()
    # 云端自证要拿「本地仓库在哪」当输入，两个引擎分支各登记一次（类别:路径）
    local -a repo_pairs=()
    # 存储完整性校验的清单（A2a）。和 repo_pairs 分开、各自登记：一个查云端有没有，
    # 一个查本地仓库里的字节还在不在——同一批仓库，两个不相干的判据。
    local -a integrity_pairs=()
    # 带时区，与 --parent-time 口径一致（bg 统一转本地显示）；
    # %z 产 ±HHMM，py<3.11 的 fromisoformat 不认——补冒号为 ±HH:MM
    SEM_TIME="$(date +"%Y-%m-%dT%H:%M:%S%z")"
    SEM_TIME="${SEM_TIME%??}:${SEM_TIME: -2}"

    for cls in config files system; do
        local archive_name
        archive_name="${DEVICE_ID}-${cls}-$(date +%Y%m%d-%H%M%S)"

        if [[ "$PLATFORM" == windows ]]; then
            # restic-under-MSYS 路径：语义层由 backup.ps1（semantic.ps1）提供，M0 不在此覆盖
            local repo_path="$BACKUP_BASE/restic-$cls"
            backup_restic_class "$cls" "$repo_path" "$archive_name" || { failed=$((failed+1)); continue; }
            repo_pairs+=("$cls:$repo_path")
            if [[ "${SKIP_WEBDAV:-0}" != "1" ]]; then
                local tgt
                for tgt in "${BACKUP_TARGETS[@]}"; do sync_target "$repo_path" "${tgt}/${SYSTEM_ID}/${cls}"; done
            fi
        else
            local repo="$BACKUP_BASE/borg-$cls"
            backup_borg_class "$cls" "$repo" "$archive_name" || { failed=$((failed+1)); continue; }
            sem_archives+=("$cls:$repo:$archive_name")
            repo_pairs+=("$cls:$repo")
            integrity_pairs+=("$cls:$repo")
            if [[ "${SKIP_WEBDAV:-0}" != "1" ]]; then
                local tgt
                for tgt in "${BACKUP_TARGETS[@]}"; do sync_target "$repo" "${tgt}/${SYSTEM_ID}/${cls}"; done
            fi
        fi
    done

    # 语义层红线（AGENTS.md §1.3）：任何失败降级为告警，不得改写备份结论
    generate_semantic "${sem_archives[@]}" || warn "[semantic] 语义层异常（不影响备份结论，详见 ${LOG}）"
    if [[ ${#sem_archives[@]} -gt 0 && "${SKIP_WEBDAV:-0}" != "1" ]]; then
        local tgt
        # rescue-test.txt（恢复演练结论）逐条写着抽样文件的**完整路径**，是明文层里
        # 唯一带文件名的产物——按红线 §1.1 它只留本地，不随时间轴上云（云端取证看
        # MANIFEST/STORY/COVERAGE 那几件按红线渲染的即可）
        SYNC_EXCLUDES=("rescue-test.txt")
        for tgt in "${BACKUP_TARGETS[@]}"; do sync_target "$BACKUP_BASE/timeline" "${tgt}/${SYSTEM_ID}/timeline"; done
        SYNC_EXCLUDES=()
    fi

    if [[ $failed -gt 0 ]]; then
        error "=== Backup FINISHED WITH ERRORS ($failed 个档案失败) ==="
        exit 1
    fi
    # 云端可见性：本地全部成功不等于云端有副本——有失败就必须非零退出并留下明确标记，
    # 让 launchd / CI / ntfy 告警链看得见，而不是宣布 FULLY COMPLETE（下次运行会自动补传）
    if [[ $cloud_failed -gt 0 ]]; then
        error "=== 本地完成，云端同步失败 $cloud_failed/$cloud_total 次——云端可能没有本次备份（详见 ${RCLONE_LOG}） ==="
        notify_alert "云端同步失败 $cloud_failed/$cloud_total 次（设备 ${DEVICE_ID}），云端可能没有本次备份。详见 $RCLONE_LOG"
        exit 1
    fi
    # A6 L1：上面两条只回答「rclone 没报错」。这一步才回答「云端到底有没有」——
    # 只在一切自称成功之后跑（本地失败或推送失败时结论已经定了，再花几分钟列云端没意义）。
    if [[ "${SKIP_WEBDAV:-0}" != "1" && "${SEM_CLOUD_VERIFY:-1}" == "1" \
          && ${#BACKUP_TARGETS[@]} -gt 0 && -n "${RCLONE:-}" ]]; then
        run_cloud_verify || warn "[verify] 自证流程异常退出（少一份证据，不改备份结论）"
        if [[ $verify_healed -gt 0 ]]; then
            warn "[verify] ${verify_healed} 个仓库 config 与云端不一致，已当场强制补传修好——这类不一致推送永远不会自己带走（详见 ${CLOUD_VERIFY_REPORT}）"
        fi
        if [[ $verify_unknown -gt 0 ]]; then
            warn "[verify] $verify_unknown 项 UNKNOWN：网盘读不出清单，这一轮没证成也没证败"
        fi
    fi
    if [[ $verify_failed -gt 0 ]]; then
        error "=== 推送都报成功，但云端副本自证 $verify_failed 项不一致——云端副本不可信（详见 ${CLOUD_VERIFY_REPORT}） ==="
        notify_alert "云端副本自证失败 $verify_failed 项（设备 ${DEVICE_ID}）：本地有的对象在云端缺失、尺寸不符，或强制补传后仍不同步。详见 ${CLOUD_VERIFY_REPORT}"
        exit 1
    fi
    # A2a：本地字节层的完整性。「云端有一致的副本」和「副本本身没腐化」是两个问题，
    # 后者只有把整仓读一遍才暴露，所以按月主动跑（窗口见 integrity_due）。
    # 它不碰网盘，所以 CI 的 SKIP_WEBDAV=1 那两 job 照样跑到——这是这条生产面的被测来源。
    run_integrity_check || warn "[integrity] 存储完整性校验流程异常退出（少一份证据，不改备份结论）"
    if [[ $integrity_failed -gt 0 ]]; then
        error "=== 存储完整性校验 $integrity_failed 项失败——仓库里有解密/校验不过的数据（详见 ${LOG}） ==="
        notify_alert "存储完整性校验失败 ${integrity_failed} 项（设备 ${DEVICE_ID}）：borg check --verify-data 在本地仓库发现坏数据。详见 ${LOG}"
        exit 1
    fi
    success "=== Backup FULLY COMPLETE ($(date '+%Y-%m-%d %H:%M:%S')) ==="
}

main "$@"
