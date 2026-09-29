#!/usr/bin/env bash
# semantic.sh — 语义层生成（research/06 章 L0/L1/L2），由 backup.sh source 后调用
# 设计红线：语义层任何失败都不得影响备份本身（调用点全部非致命）。
# M0 范围：borg 引擎（Linux/macOS）；Windows restic 路径见 semantic.ps1。

# 密钥体系（research/03 §6 / 08 T1.1）：
#   age 规范要求 passphrase stanza 独占，故「口令 + 恢复码」双路径用双 X25519 recipient：
#   keys/identity.txt          主身份（600）——日常解密
#   keys/recovery-identity.enc 恢复身份，以恢复码为 passphrase 包裹——救援路径
#   keys/recipients.txt        两个公钥——日常密封 manifest.json.enc
# 初始化由 init-keys.exp 驱动（age 从 /dev/tty 读 passphrase，管道喂不进；
# expect 提供伪终端并作为恢复码的唯一事实源，包裹后立即闭环验证）。

sem_keys_dir() { echo "${SEM_KEYS_DIR:-$CONF_DIR/age}"; }

init_sem_keys() {
    local age_bin; age_bin="$(command -v age || command -v rage || true)"
    [[ -n "$age_bin" ]] || { warn "[semantic] 未安装 age（brew install age），跳过密钥初始化"; return 1; }
    local dir; dir="$(sem_keys_dir)"
    if [[ -f "$dir/recipients.txt" ]]; then
        info "[semantic] 密钥已存在: $dir（重建需手动删除并确认仍有恢复路径）"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        info "[semantic] 非交互环境，跳过密钥初始化（请在终端运行: expect $SCRIPT_DIR/semantic/init-keys.exp \"$age_bin\" \"$dir\"）"
        return 1
    fi
    command -v expect >/dev/null || { warn "[semantic] 未找到 expect，无法安全初始化密钥"; return 1; }
    expect "$SCRIPT_DIR/semantic/init-keys.exp" "$(command -v "$age_bin")" "$dir"
}

# 密封：$1 = run.json 路径，$2 = 快照目录（产物写入其中）
seal_manifest() {
    local run_file="$1" snapshot_dir="$2"
    local age_bin; age_bin="$(command -v age || command -v rage || true)"
    [[ -n "$age_bin" ]] || { info "[semantic] 未安装 age，跳过 manifest.json.enc"; return 0; }
    local rec; rec="$(sem_keys_dir)/recipients.txt"
    [[ -f "$rec" ]] || { info "[semantic] 无 recipients.txt（先 init_sem_keys），跳过密封"; return 0; }
    if semantic_bg manifest --run "$run_file" 2>>"$LOG" | \
        "$age_bin" -R "$rec" -o "$snapshot_dir/manifest.json.enc"; then
        info "[semantic] manifest.json.enc 已密封（双恢复路径）"
    else
        warn "[semantic] manifest 密封失败（不影响其余产物）"
    fi
}
# 解析并运行 bg 入口：$BG 显式指定 > 仓库内 bg.pyz / bg_semantic.py。
# 不做 PATH 查找：macOS 自带 /usr/bin/bg（job control），裸名 bg 必然撞车。
semantic_bg() {
    if [[ -n "${BG:-}" ]]; then
        "$BG" "$@"
        return
    fi
    local f
    for f in "$SCRIPT_DIR/semantic/bg.pyz" "$SCRIPT_DIR/semantic/bg_semantic.py"; do
        if [[ -f "$f" ]]; then
            python3 "$f" "$@"
            return
        fi
    done
    error "[semantic] 未找到 bg（设置 BG= 或放入 semantic/bg.pyz）；跳过语义层"
    return 127
}

# STORY 手机推送（research/08 T1.4）：ntfy 可选 sidecar，SEM_NTFY_URL 未配置即静默跳过。
# 推荐自托管 ntfy（无画像）；用公共服务时 topic 名请用高熵随机串（ntfy.sh 的 topic 即订阅密码）。
# STORY 本身已受明文层红线约束（目录名+统计，无完整文件名），推送摘要安全。
notify_story() {
    local story_file="$1"
    [[ -n "${SEM_NTFY_URL:-}" ]] || return 0
    command -v curl >/dev/null 2>&1 || { info "[semantic] 无 curl，跳过 ntfy 推送"; return 0; }
    case "$SEM_NTFY_URL" in
        https://*|http://*) : ;;  # 自托管局域网 http 亦允许（用户自行权衡）
        *) warn "[semantic] SEM_NTFY_URL 非法（需 http/https），跳过推送"; return 0 ;;
    esac
    local summary
    summary="$( { sed -n '1p' "$story_file"; grep -m2 '^- ' "$story_file"; } \
        | tr -d '\n' | cut -c1-400)"
    if curl -sS -m 10 -H "Title: backguard 备份完成" -H "Tags: floppy_disk" \
            --data-binary "$summary" "$SEM_NTFY_URL" >>"$LOG" 2>&1; then
        success "[semantic] STORY 摘要已推送"
    else
        warn "[semantic] ntfy 推送失败（不影响备份）"
    fi
}

# 主入口：$@ = "class:repo:archive"（本次成功备份的 borg 档案）
generate_semantic() {
    [[ $# -eq 0 ]] && { info "[semantic] 无成功档案，跳过"; return 0; }

    if ! semantic_bg --version >/dev/null 2>&1; then
        warn "[semantic] bg 不可用（python3 缺失？），跳过"
        return 0
    fi

    local stage="$BACKUP_BASE/timeline"
    local runs_dir="$LOG_DIR/runs"
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bg-sem.XXXXXX")"
    local -a class_args=() prev_args=() parent_args=()
    local item cls repo arc prev_arc cur_json prev_json

    for item in "$@"; do
        cls="${item%%:*}"
        repo="${item#*:}"; repo="${repo%%:*}"
        arc="${item##*:}"
        cur_json="$tmp/$cls.jsonl"
        if ! "$BORG" list --json-lines "$repo::$arc" \
                > "$cur_json" 2>>"$LOG"; then
            warn "[semantic] [$cls] 清单导出失败，跳过该类"
            continue
        fi
        class_args+=("--class" "$cls=$cur_json")
        # 上一代归档：同名前缀按名排序取当前的前一个（首份快照无 prev）
        prev_arc="$("$BORG" list --short "$repo" 2>/dev/null \
            | grep "^${DEVICE_ID}-${cls}-" | sort | grep -B1 -x "$arc" | head -1 || true)"
        if [[ -n "$prev_arc" && "$prev_arc" != "$arc" ]]; then
            prev_json="$tmp/$cls-prev.jsonl"
            if "$BORG" list --json-lines "$repo::$prev_arc" \
                    > "$prev_json" 2>>"$LOG"; then
                prev_args+=("--prev" "$cls=$prev_json")
                # 上一代时间取自首个发现的 prev 归档（同次运行的各类相差仅数秒）
                if [[ ${#parent_args[@]} -eq 0 ]]; then
                    local pt
                    # borg 的 start 是无后缀的 naive UTC（实测 1.4）；补 UTC 后缀转本地时区，
                    # 与 --time 的本地时间口径对齐（bg 侧 local_naive 统一显示本地）
                    pt="$("$BORG" info --json "$repo::$prev_arc" 2>/dev/null \
                        | python3 -c "import sys,json,datetime;d=json.load(sys.stdin);a=d.get('archive') or (d.get('archives') or [{}])[0];s=a.get('start','');print(datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).astimezone().isoformat() if s else '')" 2>/dev/null || true)"
                    [[ -n "$pt" ]] && parent_args+=("--parent-time" "$pt")
                fi
            fi
        fi
    done

    if [[ ${#class_args[@]} -eq 0 ]]; then
        warn "[semantic] 无可导出清单，跳过"
        rm -rf "$tmp"
        return 0
    fi

    # 语义标签：无用户输入时按时段自动生成（research/08 T1.2 的最简形态）
    local h label
    h="$(date +%H)"
    if (( 10#$h >= 23 || 10#$h < 6 )); then label=night
    elif (( 10#$h < 11 )); then label=morning
    elif (( 10#$h < 14 )); then label=noon
    elif (( 10#$h < 18 )); then label=afternoon
    else label=evening
    fi
    label="${SEM_LABEL:-$label}"

    if ! semantic_bg convert --engine borg "${class_args[@]}" "${prev_args[@]}" "${parent_args[@]}" \
            --device "$DEVICE_ID" --time "${SEM_TIME:-$(date +"%Y-%m-%dT%H:%M:%S%z")}" \
            --label "$label" --auto-strip --out "$tmp/run.json" >>"$LOG" 2>&1; then
        warn "[semantic] convert 失败（详见 $LOG），跳过"
        rm -rf "$tmp"
        return 0
    fi

    local sdir
    semantic_bg generate --run "$tmp/run.json" --out "$stage" 2>>"$LOG" \
        | sed -n 's/^已生成快照目录: //p' > "$tmp/.sdir"
    if [[ ${PIPESTATUS[0]} -ne 0 || ! -s "$tmp/.sdir" ]]; then
        warn "[semantic] generate 失败（详见 $LOG），跳过"
        rm -rf "$tmp"
        return 0
    fi
    sdir="$(cat "$tmp/.sdir")"

    # 全量清单密封（age 双恢复路径；无 age/无密钥时非致命跳过）
    seal_manifest "$tmp/run.json" "$sdir"

    # STORY 手机推送（ntfy 可选 sidecar，research/08 T1.4）
    notify_story "$sdir/STORY.md"

    # run JSON 留档（最近 60 份，research/08 T0.3）
    mkdir -p "$runs_dir"
    cp "$tmp/run.json" "$runs_dir/run-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null || true
    ls -1t "$runs_dir"/run-*.json 2>/dev/null | tail -n +61 | xargs rm -f 2>/dev/null || true
    rm -rf "$tmp"

    success "[semantic] 时间轴已生成: $stage"
}
