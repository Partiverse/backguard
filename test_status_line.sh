#!/usr/bin/env bash
# STATUS.jsonl 产出器（A1 状态地基）的 E2E：真 borg 跑两轮 backup.sh，验证
#   1) 每轮追加一行、两轮两行（追加不改写——rclone 只比大小，同尺寸覆写推不上云）
#   2) 每行是合法 JSON 且 format 正确
#   3) 零文件名、零绝对路径（红线 §1.1：这份文件随 timeline 上云）
# 变异台账（驱动口径同 bash 侧：先验证落上、变异后看首条 FAIL 是不是主张的那件事）：
#   s01 摘掉 EXIT trap 里的 append_status_line 调用   BITTEN count=1  首条=第 1 轮后文件必须存在
#   s02 产出器把 $LOG 绝对路径写进字段               BITTEN count=2  首条=隐私扫描（$T 前缀）
#   s03 `>>` 改 `>`（覆写）                          BITTEN count=1  首条=第 2 轮后必须两行
#   s04 engine 字段照抄 PLATFORM                     BITTEN count=1  首条=engine 应为 borg|restic
#       ——10-04 真机首行 `"engine":"macos"` 暴露的那一刀：夹具 PLATFORM=macos，PLATFORM 漏进
#         engine 字段时本断言当场红
# 不覆盖（如实登记）：restic 分支（windows 侧）的产出器由 test_status_emit_logic.ps1 与
# windows job 的产品轮覆盖；云端自证/完整性在真云与 CI 真实备份 job 里另有判据。
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-status-line.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; tail -30 "$T/out.log" 2>/dev/null || true; exit 1; }

command -v borg >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 borg，未测"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 python3（JSON 校验），未测"; exit 0; }

SECRET_NAME="tiny-秘密文档.txt"
mkdir -p "$T/src/文档" "$T/conf/partiverse-backup" "$T/home"
echo hello > "$T/src/文档/$SECRET_NAME"
export BORG_PASSPHRASE='status-e2e-pass'
export BORG_UNKNOWN_PASSPHRASE_SEVERITY=error   # borg 1.4：口令进 stderr 的提示降级为报错，别让它糊进断言

write_config() {   # $1=BACKUP_BASE
    cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Status"
export SYSTEM_ID="e2e-status"
export BACKUP_BASE="$1"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=()
export BORG="$(command -v borg)"
export RCLONE="$(command -v rclone || echo /usr/bin/true)"
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src")
BORG_EXCLUDES_system=()
CONF
    printf "BORG_PASSPHRASE='%s'\n" "$BORG_PASSPHRASE" > "$T/conf/partiverse-backup/secrets.env"
    chmod 600 "$T/conf/partiverse-backup/secrets.env"
}

run_backup() { (
    cd "$T/home"
    env XDG_CONFIG_HOME="$T/conf" HOME="$T/home" SKIP_WEBDAV=1 SEM_PREFLIGHT=0 \
        bash "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
); }

STATUS_JSONL="$T/base/timeline/STATUS.jsonl"

# ---------- 第 1 轮：文件存在、单行、合法 JSON、零隐私 ----------
write_config "$T/base"
run_backup || fail "第 1 轮 backup.sh 没跑成（rc=$?）"
grep -q 'FULLY COMPLETE' "$T/out.log" || fail "第 1 轮没宣布 FULLY COMPLETE：$(tail -3 "$T/out.log")"
[[ -f "$STATUS_JSONL" ]] || fail "第 1 轮后 STATUS.jsonl 不存在——产出器没被调（挂 trap 了吗）"
[[ "$(wc -l < "$STATUS_JSONL" | tr -d ' ')" == "1" ]] \
    || fail "第 1 轮后应为 1 行，实得 $(wc -l < "$STATUS_JSONL") 行"
python3 - "$STATUS_JSONL" <<'PY' || fail "STATUS.jsonl 不是合法 JSONL（逐行 json.loads 失败）"
import json, sys
for i, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    row = json.loads(line)
    assert row.get("format") == "backguard/status/1", f"line {i}: format={row.get('format')}"
    for k in ("ts", "device", "engine", "sha", "rc", "dur_s", "cv_state", "ig_state", "snapshots"):
        assert k in row, f"line {i}: 缺字段 {k}"
PY
# 隐私扫描：源文件名与夹具绝对路径一个都不许出现（§1.1「呈现即泄漏」）
if grep -qF "$SECRET_NAME" "$STATUS_JSONL"; then fail "隐私：状态行里出现了源文件名"; fi
if grep -qF "$T" "$STATUS_JSONL"; then fail "隐私：状态行里出现了夹具绝对路径前缀"; fi
# 计数字段形状：SKIP_WEBDAV ⇒ cv_state=skipped；首轮完整性窗口刚开 ⇒ 跑过且 3 项
grep -q '"cv_state":"skipped"' "$STATUS_JSONL" || fail "cv_state 应为 skipped（BACKUP_TARGETS 空）：$(cat "$STATUS_JSONL")"
grep -q '"ig_state":"pass"' "$STATUS_JSONL" || fail "ig_state 应为 pass（首轮窗口刚开）：$(cat "$STATUS_JSONL")"
# engine 是引擎（borg|restic），不是部署平台——10-04 真机首行写成 "macos"（PLATFORM 漏进了
# engine 字段）才暴露：夹具 PLATFORM=macos，engine 必须是 borg。变异 s04 就是这一刀
grep -qE '"engine":"(borg|restic)"' "$STATUS_JSONL" \
    || fail "engine 应为 borg|restic（不是 PLATFORM）：$(cat "$STATUS_JSONL")"

# ---------- 第 2 轮：追加成两行（覆写会停在 1 行）----------
run_backup || fail "第 2 轮 backup.sh 没跑成（rc=$?）"
[[ "$(wc -l < "$STATUS_JSONL" | tr -d ' ')" == "2" ]] \
    || fail "第 2 轮后应为 2 行（追加），实得 $(wc -l < "$STATUS_JSONL") 行——是不是把 >> 写成了 >？"

echo "E2E-OK: STATUS.jsonl 每轮一行（追加）+ 合法 JSON + 零文件名零路径"
