#!/usr/bin/env bash
# 只读验收：部署树追平后，次日 02:34 nightly 的产物核对（docs/HANDOVER §11 第 2 条 ③④⑤⑥）。
# 不写任何东西、不碰云端（config 哈希对比用 rclone cat，是只读子命令）。
# 用法: /opt/homebrew/bin/bash verify-nightly.sh [YYYY-MM-DD]   # 默认今天
# 为什么在仓库里而不在 /tmp：它是部署树追平的验收判据本身（§11 记的 pass=12/fail=4 就是这份），
# 重启即失的核对脚本没法在次日 08:00 还躺在同一台机器上。它只读，所以不入 CI——
# CI 里没有真机 nightly 的产物可读。
set -uo pipefail

DAY="${1:-$(date +%F)}"
B=~/PartiverseBackup
L=~/.local/share/partiverse-backup
REMOTE="Backguard:particloud-macos"
pass=0; fail=0

# 这台机器可能只有 shasum（BSD）或只有 sha256sum（GNU），而 /opt/homebrew/bin 不在
# launchd 的受限 PATH 里——按存在性找，别写死绝对路径（AGENTS §2「哈希轮流域」同一条）。
# 不带参数＝读 stdin（`rclone cat … | sha256_of`），带参数＝算某个文件。
sha256_of() {
    local bin
    if command -v sha256sum >/dev/null 2>&1; then
        bin=(sha256sum)
    elif command -v shasum >/dev/null 2>&1; then
        bin=(shasum -a 256)
    else
        return 1
    fi
    if [[ $# -eq 0 ]]; then "${bin[@]}" | awk '{print $1}'
    else "${bin[@]}" "$1" | awk '{print $1}'
    fi
}

chk() { # chk <ok|fail|warn> <label> <detail>
  printf '  [%-5s] %-46s %s\n' "$1" "$2" "$3"
  case "$1" in ok) pass=$((pass+1));; fail) fail=$((fail+1));; esac
}

# 真机布局是 timeline/YYYY/MM/DD/HHMM-标签（转录里斜杠会被显示成连字符，别照着写）
daydir="$B/timeline/$(printf '%s' "$DAY" | tr '-' '/')"
snap="$(find "$daydir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
echo "== 快照 $snap =="
[[ -n "$snap" ]] && chk ok "当晚快照存在" "$snap" || chk fail "当晚快照存在" "无 $DAY 快照（${daydir}）"

if [[ -n "$snap" ]]; then
for f in MANIFEST.txt STORY.md COVERAGE.txt restore.md; do
  [[ -s "$snap/$f" ]] && chk ok "$f" "$(wc -c <"$snap/$f" | tr -d ' ') B" || chk fail "$f" "缺失或为空"
done
[[ -f "$snap/manifest.json.enc" ]] && chk ok "manifest.json.enc" "存在" || chk fail "manifest.json.enc" "缺失"
else
# 没有快照时这几项一律记 fail：对不存在的路径 grep「没命中」会被读成通过，那是假绿
chk fail "四件套 + 密封清单" "无快照，无从核对"
fi

echo "== A4：run 边界行（当日恰好一行） =="
today_lines=$(grep -a "^\\[$DAY .*/ run 边界: sha=" "$L/backup.log" 2>/dev/null || true)
today_n=$(printf '%s' "$today_lines" | grep -ac 'run 边界' || true)
line=$(printf '%s\n' "$today_lines" | tail -1)
if [[ -n "$line" ]]; then
  [[ "$today_n" == "1" ]] && chk ok "当晚恰好一行" "$line" || chk fail "当晚恰好一行" "$today_n 行：$line"
  [[ "$line" == *"rc=0"* ]] && chk ok "rc=0" "" || chk fail "rc=0" "见上一行"
  [[ "$line" == *"sha=$(git -C ~/leisure/Codebase-Driven-by-AI/backguard/v0 rev-parse --short HEAD)"* ]] \
    && chk ok "sha=部署点 HEAD" "" \
    || chk warn "sha=部署点 HEAD" "行里的 sha 与部署树 HEAD 不一致（或 nogit）"
else
  chk fail "存在 run 边界行" "backup.log 里没有 $DAY 的边界行（部署点未追平？）"
fi
# BSD grep 不认 BRE 的 \|（按字面量找），这里三处交替一律 -E（AGENTS §2）
rot=$(grep -acE '轮转|rotat' "$L/backup.log" 2>/dev/null || true)
[[ "${rot:-0}" == "0" ]] && chk ok "日志未轮转（远小于 4 MiB 阈值）" "log=$(wc -c <"$L/backup.log" | tr -d ' ') B" \
                         || chk warn "看到轮转字样" "确认不是阈值判定写反"

echo "== A6 L1：CLOUD-VERIFY.txt =="
cv="$B/timeline/CLOUD-VERIFY.txt"
if [[ -f "$cv" ]]; then
  chk ok "文件存在" "$(stat -f '%Sm' -t '%F %T' "$cv")"
  sums=$(grep -aE '^SUMMARY|^汇总|FAIL=' "$cv" | tail -3)
  printf '%s\n' "$sums" | sed 's/^/      /'
  checks=$(printf '%s' "$sums" | grep -aoE 'checks=[0-9]+' | tail -1 | tr -dc '0-9')
  [[ "${checks:-0}" -ge 7 ]] && chk ok "checks>=7（清单齐全）" "checks=$checks" \
                            || chk fail "checks>=7（清单齐全）" "checks=${checks:-未解析} —— 有一类没进清单"
  fails=$(printf '%s' "$sums" | grep -aoE 'FAIL=[0-9]+' | tail -1 | tr -dc '0-9')
  [[ "${fails:-1}" == "0" ]] && chk ok "FAIL=0" "" || chk fail "FAIL=0" "FAIL=$fails"
  healed=$(printf '%s' "$sums" | grep -aoE 'HEALED=[0-9]+' | tail -1 | tr -dc '0-9')
  [[ "${healed:-0}" == "0" ]] && chk ok "HEALED=0（首轮预期）" "" \
                             || chk warn "HEALED>0" "HEALED=${healed}，连续两晚>0 就是推送清单有问题"
  grep -aq 'rescue-test.txt' "$cv" && chk fail "自证清单未含本地-only 的 rescue-test.txt" "会每晚假报" \
                                   || chk ok "自证清单未含 rescue-test.txt" ""
else
  chk fail "文件存在" "$cv 不存在"
fi

echo "== A2a：INTEGRITY.txt（首轮应真跑一遍） =="
ig="$B/timeline/INTEGRITY.txt"
if [[ -f "$ig" ]]; then
  chk ok "文件存在" "mtime=$(stat -f '%Sm' -t '%F %T' "$ig")"
  grep -aE 'checks=|FAIL' "$ig" | tail -3 | sed 's/^/      /'
  grep -ac '\[integrity\] borg check --verify-data' "$L/backup.log" | sed 's/^/      引擎行数: /'
else
  chk fail "文件存在" "$ig 不存在（首轮窗口自然到期，应该写出）"
fi

echo "== A2b：备份期样本内容哈希（恰好一行，n>0） =="
hl=$(grep -a '演练样本内容哈希' "$L/backup.log" 2>/dev/null | tail -1)
[[ -n "$hl" ]] && printf '      %s\n' "$hl" || chk fail "stderr 有 n/N 行" "一行都没有＝密封侧没走 --hash-drill-samples"
if [[ "$hl" =~ 哈希：([0-9]+)/([0-9]+) ]]; then
  [[ "${BASH_REMATCH[1]}" -gt 0 ]] && chk ok "已记哈希 n>0" "n=${BASH_REMATCH[1]} picked=${BASH_REMATCH[2]}" \
                                   || chk fail "已记哈希 n>0" "n=0 ＝这层证据整段退化（路径形态/抽样口径漂移）"
fi
if [[ -n "$snap" ]]; then
  hex=$(grep -alE '[0-9a-f]{64}' "$snap"/MANIFEST.txt "$snap"/STORY.md "$snap"/COVERAGE.txt "$snap"/restore.md 2>/dev/null)
  [[ -z "$hex" ]] && chk ok "明文产物无 64 位十六进制串" "" || chk fail "明文产物无 64 位十六进制串" "$hex"
fi

echo "== 隐私红线抽查（明文层不含完整文件名） =="
if [[ -n "$snap" ]]; then
  if grep -qsE '\.(jpg|jpeg|png|pdf|docx|xlsx|key|pem|txt)$' "$snap"/MANIFEST.txt; then
    chk fail "MANIFEST.txt 无扩展名结尾的文件名" "命中"
  else
    chk ok "MANIFEST.txt 无扩展名结尾的文件名" ""
  fi
fi

echo "== 云端 config 与本地同哈希（只读 rclone cat） =="
for cls in config files system; do
  loc="$B/borg-$cls/config"
  [[ -f "$loc" ]] || { chk warn "本地 $cls/config" "不存在，跳过"; continue; }
  lh=$(sha256_of "$loc")
  if ! rc=$(rclone cat "$REMOTE/$cls/config" 2>/dev/null | sha256_of); then
    chk warn "borg-$cls/config 云端一致" "rclone cat 读不出（这条 remote 抖动），既没证成也没证败"
    continue
  fi
  [[ -n "$lh" && "$lh" == "$rc" ]] && chk ok "borg-$cls/config 云端一致" "${lh:0:12}…" \
                                  || chk fail "borg-$cls/config 云端一致" "local=${lh:0:12} cloud=${rc:0:12}"
done

echo "== A5：STORY 的「相比」基线（两条口径不一致时才写口径说明行） =="
a5=$(grep -aE '这次备份相比|口径说明' "$snap"/STORY.md 2>/dev/null | head -2)
printf '%s\n' "$a5" | sed 's/^/      /'
[[ -n "$a5" ]] && chk ok "基线行存在" "" || chk fail "基线行存在" "STORY 里既无「相比」也无「口径说明」"

echo
echo "结论: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] && echo "VEROK" || echo "VER-FAIL"
