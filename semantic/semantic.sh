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

# 跨平台文件属性：GNU stat 的 -f 是「文件系统状态」（%m/%N/%z 对它是非法指令，
# 只打垃圾且不报错），BSD stat 则没有 -c——任何一边写死都会让另一边静默拿到错值
# （Linux 上排除规则变更检测长期失效就是这个原因）。一律走 POSIX：date -r / wc -c。
file_mtime() { [[ -e "$1" ]] && date -r "$1" +%s 2>/dev/null || echo 0; }
file_size()  { [[ -f "$1" ]] && wc -c < "$1" | tr -d '[:space:]' || echo -1; }

# age 解析：launchd 环境 PATH 无 /opt/homebrew/bin，command -v 扑空 → 密封被静默跳过
find_age() {
    local c
    command -v age && return 0
    command -v rage && return 0
    for c in /opt/homebrew/bin/age /usr/local/bin/age; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

init_sem_keys() {
    local age_bin; age_bin="$(find_age || true)"
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
    local age_bin; age_bin="$(find_age || true)"
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
# 底座一律非致命：任何失败只告警，不影响备份退出码。
notify_push() {
    local title="$1" tags="$2" body="$3"
    [[ -n "${SEM_NTFY_URL:-}" ]] || return 0
    command -v curl >/dev/null 2>&1 || { info "[semantic] 无 curl，跳过 ntfy 推送"; return 0; }
    case "$SEM_NTFY_URL" in
        https://*|http://*) : ;;  # 自托管局域网 http 亦允许（用户自行权衡）
        *) warn "[semantic] SEM_NTFY_URL 非法（需 http/https），跳过推送"; return 0 ;;
    esac
    if curl -sS -m 10 -H "Title: $title" -H "Tags: $tags" \
            --data-binary "$body" "$SEM_NTFY_URL" >>"$LOG" 2>&1; then
        success "[semantic] 已推送: $title"
    else
        warn "[semantic] ntfy 推送失败（不影响备份）"
    fi
    return 0
}

notify_story() {
    local story_file="$1" summary
    [[ -n "${SEM_NTFY_URL:-}" ]] || return 0
    # grep 无命中（「一切正常」型快照没有变更要点）rc=1，pipefail 下会让赋值语句
    # 炸掉整个备份——推送是旁路，必须 (… || true) 中和
    summary="$( { sed -n '1p' "$story_file"; grep -m2 '^- ' "$story_file" || true; } \
        | tr -d '\n' | cut -c1-400)"
    notify_push "backguard 备份完成" "floppy_disk" "$summary"
}

# 异常告警（云端推送失败等），backup.sh 编排层调用——同样是旁路，不得影响退出码
notify_alert() { notify_push "backguard 告警" "warning_sign" "$1"; }

# 本地 timeline 暂存保留（2026-09-30 云端删除事件教训：快照历史此前只在云端存一份，
# 云端被删即永久丢失）。rclone copy 只增不删、云端是全量历史；本地保留最近 N 份
# （默认 14，SEM_TIMELINE_KEEP 可调，<=0 跳过清理、非数字回落默认）供云端丢失时重建。
# 只清理 <设备>/YYYY/MM/DD/HHMM-标签 快照目录；profile.json / rescue-test.txt 不动。
prune_local_timeline() {
    local dev_dir="$1"
    local keep="${SEM_TIMELINE_KEEP:-14}"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=14
    (( keep >= 1 )) || return 0
    [[ -d "$dev_dir" ]] || return 0
    local old
    # 滑窗 awk 取「除最后 keep 份外」的全部（BSD head 不支持负数 -n，tail 方向是反的）
    old="$( { find "$dev_dir" -mindepth 4 -maxdepth 4 -type d 2>/dev/null || true; } \
        | LC_ALL=C sort | awk -v k="$keep" 'NR>k{print a[NR-k]} {a[NR]=$0}' )"
    if [[ -n "$old" ]]; then
        local s
        while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            # rm -rf 白名单守卫：只放行 basename 为 HHMM-标签 形态的快照目录，
            # dev_dir 意外解析错时宁可漏删不可误删
            [[ "${s##*/}" =~ ^[0-9]{4}-[a-z0-9-]+$ ]] || {
                warn "[semantic] 跳过非快照形态路径: $s"; continue; }
            rm -rf -- "$s" && info "[semantic] 本地暂存保留最近 $keep 份，清理: ${s#"$dev_dir"/}"
        done <<< "$old"
        # 快照清走后腾出的空日期目录一并收掉（-delete 自 deepest-first，空壳级联消除）
        { find "$dev_dir" -mindepth 1 -maxdepth 3 -type d -empty -delete 2>/dev/null || true; }
    fi
}

# run JSON 留档轮转（research/08 T0.3：默认最近 60 份，第二参可覆盖）。
# 原实现 `ls -1t … | xargs rm -f` 把 ls 输出按空白拆词喂给 rm——名字里一个空格
# 或分号就能把删除目标指到别处。这里与 prune_local_timeline 同口径：while read
# 逐行 + basename 白名单，只放行 run-YYYYMMDD-HHMMSS.json，宁可漏删不可误删。
prune_run_jsons() {
    local runs_dir="$1"
    local keep="${2:-60}"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=60
    (( keep >= 1 )) || return 0
    [[ -d "$runs_dir" ]] || return 0
    local stale f
    stale="$( { ls -1t "$runs_dir"/run-*.json 2>/dev/null || true; } | tail -n +$((keep + 1)) )"
    [[ -n "$stale" ]] || return 0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ "${f##*/}" =~ ^run-[0-9]{8}-[0-9]{6}\.json$ ]] || {
            warn "[semantic] 跳过非留档形态路径: $f"; continue; }
        rm -f -- "$f"
    done <<< "$stale"
}

# 上一代快照的 exclusions.json（按 mtime 最近者，不含本代）→ 变更检测数据源。
# 首备时 stage 可能不存在——find 的 rc 经 (…; true) 中和，防 pipefail 退出。
latest_prev_exclusions() {
    local stage="$1" f
    { find "$stage" -name exclusions.json 2>/dev/null || true; } | head -50 |
        while read -r f; do printf '%s %s\n' "$(file_mtime "$f")" "$f"; done |
        sort -rn | head -1 | cut -d' ' -f2-
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
                    # 从归档名后缀解析本地时间：borg 1.4 的 info start 是 naive 本地时间，
                    # 曾被误判为 naive UTC（TZ=UTC 的 CI 上两者无法区分），时区非零的机器
                    # replace(utc) 会平移整时区（本机实测 STORY 出现 8 小时后的时刻）。
                    # 归档名 YYYYMMDD-HHMMSS 由 backup.sh 用本地 date 戳，与 --time 口径一致。
                    #（注意时间戳内部也有连字符：日期段=倒数第二字段，时间段=最后字段）
                    local ts hhmmss
                    ts="${prev_arc%-*}"; ts="${ts##*-}"
                    hhmmss="${prev_arc##*-}"
                    pt="${ts:0:4}-${ts:4:2}-${ts:6:2}T${hhmmss:0:2}:${hhmmss:2:2}:${hhmmss:4:2}"
                    if [[ ${#pt} -eq 19 ]]; then
                        parent_args+=("--parent-time" "$pt")
                    fi
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
            --device "$DEVICE_ID" \
            --time "${SEM_TIME:-$(t="$(date +"%Y-%m-%dT%H:%M:%S%z")"; echo "${t%??}:${t: -2}")}" \
            --label "$label" --auto-strip --out "$tmp/run.json" >>"$LOG" 2>&1; then
        warn "[semantic] convert 失败（详见 $LOG），跳过"
        rm -rf "$tmp"
        return 0
    fi

    # 排除清单导出（research/08 T2.1）→ 覆盖报告数据源
    export_exclusions "$tmp"

    local prev_ex
    prev_ex="$(latest_prev_exclusions "$stage")"
    [[ -n "$prev_ex" ]] && cp "$prev_ex" "$tmp/prev-exclusions.json" 2>/dev/null || true

    local sdir gen_rc=0
    # || gen_rc=$? 中和 set -e/pipefail：bg 失败必须走下方降级而非炸掉整个备份
    semantic_bg generate --run "$tmp/run.json" --out "$stage" \
        --exclusions "$tmp/exclusions.json" \
        --prev-exclusions "$tmp/prev-exclusions.json" \
        ${LOG_DIR:+--preflight "$LOG_DIR/preflight-latest.json"} 2>>"$LOG" \
        | sed -n 's/^已生成快照目录: //p' > "$tmp/.sdir" || gen_rc=$?
    if [[ $gen_rc -ne 0 || ! -s "$tmp/.sdir" ]]; then
        warn "[semantic] generate 失败（详见 $LOG），跳过"
        rm -rf "$tmp"
        return 0
    fi
    sdir="$(cat "$tmp/.sdir")"
    cp "$tmp/exclusions.json" "$sdir/exclusions.json" 2>/dev/null || true

    # 全量清单密封（age 双恢复路径；无 age/无密钥时非致命跳过）
    seal_manifest "$tmp/run.json" "$sdir"

    # STORY 手机推送（ntfy 可选 sidecar，research/08 T1.4）
    notify_story "$sdir/STORY.md"

    # 恢复演练（30 天节流；从 files 仓库实取抽样文件并校验，research/08 T3.4）
    local d_item d_repo d_arc
    for d_item in "$@"; do
        [[ "$d_item" == files:* ]] || continue
        d_repo="${d_item#*:}"; d_repo="${d_repo%%:*}"
        d_arc="${d_item##*:}"
        run_drill "$sdir" "$d_repo" "$d_arc"
    done

    # run JSON 留档（最近 60 份，research/08 T0.3）
    mkdir -p "$runs_dir"
    cp "$tmp/run.json" "$runs_dir/run-$(date +%Y%m%d-%H%M%S).json" 2>/dev/null || true
    prune_run_jsons "$runs_dir"
    rm -rf "$tmp"

    prune_local_timeline "$stage/$DEVICE_ID"

    success "[semantic] 时间轴已生成: $stage"
}

# 恢复演练（research/08 T3.4）：解封 → 抽样 → 从仓库实际取回 → 校验 → rescue-test.txt。
# 主身份路径解封（救援路径需交互，留给人工季度演练）；30 天节流；非致命。
# 用法: run_drill <快照目录> <files仓库路径> <files归档名>
run_drill() {
    local sdir="$1" repo="$2" arc="$3"
    [[ "${SEM_DRILL:-1}" == "1" ]] || return 0
    # 设备级文件：sdir（…/<dev>/YYYY/MM/DD/HHMM-标签）上 4 层到 <dev>
    local rt="$sdir/../../../../rescue-test.txt"
    # 30 天节流
    if [[ -f "$rt" ]]; then
        local last now
        last="$(file_mtime "$rt")"
        now="$(date +%s)"
        (( now - last < 30 * 86400 )) && { info "[drill] 上次演练不足 30 天，跳过"; return 0; }
    fi
    local age_bin; age_bin="$(find_age || true)"
    local ident; ident="$(sem_keys_dir)/identity.txt"
    [[ -n "$age_bin" && -f "$ident" && -f "$sdir/manifest.json.enc" ]] || {
        info "[drill] 缺 age/主身份/密封清单，跳过"; return 0; }

    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/bg-drill.XXXXXX")"
    local pass=0 failn=0
    {
        echo "# 恢复演练 rescue-test — $(date -Iseconds)"
        echo "# 方式: 主身份解封 + 仓库实取 + 大小校验（救援路径季度人工演练）"
        if ! "$age_bin" -d -i "$ident" -o "$tmp/manifest.json" "$sdir/manifest.json.enc" 2>/dev/null; then
            echo "RESULT: FAIL（manifest 解封失败）"
        else
            semantic_bg sample --manifest "$tmp/manifest.json" --count 5 > "$tmp/plan.json" 2>/dev/null
            local n; n="$(python3 -c "import json,sys;print(len(json.load(open('$tmp/plan.json'))['samples']))" 2>/dev/null || echo 0)"
            local i=0
            while (( i < n )); do
                local path size got cls
                path="$(python3 -c "import json;print(json.load(open('$tmp/plan.json'))['samples'][$i]['path'])")"
                size="$(python3 -c "import json;print(json.load(open('$tmp/plan.json'))['samples'][$i]['size'])")"
                cls="$(python3 -c "import json;print(json.load(open('$tmp/plan.json'))['samples'][$i]['class'])")"
                # 实取：borg extract（归档内路径为剥掉前导 / 的绝对路径形态）
                # 必须在 tmp/out 内解包——cwd 解包会污染仓库所在目录
                mkdir -p "$tmp/out"
                if (cd "$tmp/out" && "$BORG" extract "$repo::$arc" "$path" 2>>"$LOG"); then
                    got="$(find "$tmp/out" -type f -path "*$path" 2>/dev/null | head -1)"
                fi
                if [[ -n "${got:-}" && "$(file_size "${got:-}")" == "$size" ]]; then
                    echo "PASS [$cls] $path ($size B)"; pass=$((pass+1))
                else
                    echo "FAIL [$cls] $path（取回或大小不符）"; failn=$((failn+1))
                fi
                i=$((i+1))
            done
            echo "RESULT: $pass PASS / $failn FAIL（抽样 $n）"
        fi
    } > "$rt" 2>/dev/null
    rm -rf "$tmp"
    grep -q "RESULT: .*FAIL" "$rt" && warn "[drill] 恢复演练有失败项：$rt" \
        || success "[drill] 恢复演练通过：$rt"
}

# 把三档案的 exclude 模式导出为 exclusions.json（机器可读）
export_exclusions() {
    local tmp="$1" out cls i p first
    out="$tmp/exclusions.json"   # 同语句内引用刚声明的变量会取不到值（SC2318）
    first=1
    {
        printf '{"generated":"%s","exclusions":[' "$(date -Iseconds)"
        for cls in config files system; do
            eval "declare -n e_ref=\"BORG_EXCLUDES_$cls\""  # declare -n 避开 SC2318
            # shellcheck disable=SC2154  # e_ref 经上方 eval 动态绑定
            for ((i = 0; i < ${#e_ref[@]}; i += 2)); do
                p="${e_ref[i+1]:-}"
                [[ "$p" == --exclude || -z "$p" ]] && continue
                [[ $first -eq 1 ]] || printf ','
                first=0
                printf '"%s|%s"' "$cls" "$p"
            done
        done
        printf ']}\n'
    } > "$out" 2>/dev/null || echo '{"exclusions":[]}' > "$out"
}
