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
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/partiverse-backup"
LOG_DIR="$HOME/.local/share/partiverse-backup"
mkdir -p "$CONF_DIR" "$LOG_DIR"

# ---------- 加载配置 ----------
if [[ -f "$CONF_DIR/config.sh" ]]; then
    source "$CONF_DIR/config.sh"
else
    error "配置文件不存在: $CONF_DIR/config.sh"
    info "运行 ./init.sh 或参考 platform/ 目录手动配置"
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
sync_target() {
    local local_path="$1"; local dest="$2"
    # ":/" 会被子类后端解析成文件系统绝对路径——
    # 空子路径的目标（"remote:" + "/设备/..."）必须归一为 "remote:设备/..."
    dest="$(sed 's|:/*|:|g' <<< "$dest")"  # BSD sed 兼容（不支持 \+）
    info "rclone copy -> $dest"
    "$RCLONE" mkdir "$dest" 2>>"$LOG" || true
    set +e
    "$RCLONE" copy "$local_path/" "$dest/" \
        --bwlimit 10M --transfers 2 --checkers 4 \
        --log-file "$RCLONE_LOG" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    [[ $rc -eq 0 ]] && success "[rclone] $dest 同步完成" || warn "[rclone] $dest 同步失败 (rc=$rc)"
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

# ---------- 语义层（research/06：MANIFEST.txt/STORY.md/restore.md） ----------
# 非致命：语义层任何失败只告警，不影响备份结论
if [[ -f "$SCRIPT_DIR/semantic/semantic.sh" ]]; then
    source "$SCRIPT_DIR/semantic/semantic.sh"
else
    generate_semantic() { warn "semantic/semantic.sh 缺失，跳过语义层"; }
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

# ---------- 主流程 ----------
main() {
    LOG="${LOG:-$LOG_DIR/backup.log}"
    RCLONE_LOG="${RCLONE_LOG:-$LOG_DIR/rclone.log}"

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
        semantic_bg preflight "${pf_args[@]}" | tee -a "$LOG" || pf_rc=$?
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
    SEM_TIME="$(date +"%Y-%m-%dT%H:%M:%S%z")"  # 带时区，与 --parent-time 口径一致（bg 统一转本地显示）

    for cls in config files system; do
        local archive_name
        archive_name="${DEVICE_ID}-${cls}-$(date +%Y%m%d-%H%M%S)"

        if [[ "$PLATFORM" == windows ]]; then
            # restic-under-MSYS 路径：语义层由 backup.ps1（semantic.ps1）提供，M0 不在此覆盖
            local repo_path="$BACKUP_BASE/restic-$cls"
            backup_restic_class "$cls" "$repo_path" "$archive_name" || { failed=$((failed+1)); continue; }
            if [[ "${SKIP_WEBDAV:-0}" != "1" ]]; then
                local tgt
                for tgt in "${BACKUP_TARGETS[@]}"; do sync_target "$repo_path" "${tgt}/${SYSTEM_ID}/${cls}"; done
            fi
        else
            local repo="$BACKUP_BASE/borg-$cls"
            backup_borg_class "$cls" "$repo" "$archive_name" || { failed=$((failed+1)); continue; }
            sem_archives+=("$cls:$repo:$archive_name")
            if [[ "${SKIP_WEBDAV:-0}" != "1" ]]; then
                local tgt
                for tgt in "${BACKUP_TARGETS[@]}"; do sync_target "$repo" "${tgt}/${SYSTEM_ID}/${cls}"; done
            fi
        fi
    done

    generate_semantic "${sem_archives[@]}"
    if [[ ${#sem_archives[@]} -gt 0 && "${SKIP_WEBDAV:-0}" != "1" ]]; then
        local tgt
        for tgt in "${BACKUP_TARGETS[@]}"; do sync_target "$BACKUP_BASE/timeline" "${tgt}/${SYSTEM_ID}/timeline"; done
    fi

    if [[ $failed -eq 0 ]]; then
        success "=== Backup FULLY COMPLETE ($(date '+%Y-%m-%d %H:%M:%S')) ==="
    else
        error "=== Backup FINISHED WITH ERRORS ($failed 个档案失败) ==="
        exit 1
    fi
}

main "$@"
