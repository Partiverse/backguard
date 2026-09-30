#!/usr/bin/env bash
# 红线守卫（AGENTS.md §1.4「云端只增不减」）：云端一律 rclone copy，
# 任何脚本出现 `rclone sync` 都会让本地 prune 把云端历史一起删掉。
# 纯静态检查，不触网不建仓库——本机与 CI 都可跑。
# 用法: ./test_cloud_copy_only.sh [仓库根]
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$V0_DIR}"

fail() { echo "E2E-FAIL: $1"; exit 1; }

# 只扫真跑备份的脚本；测试与本守卫自身允许出现该字样（文档 docs/ 不在门禁内）
hits="$(grep -rn --include='*.sh' --include='*.ps1' -E 'rclone[[:space:]]+sync' \
    "$ROOT" 2>/dev/null | grep -v "$(basename "$0")" || true)"

if [[ -n "$hits" ]]; then
    echo "$hits"
    fail "发现 rclone sync（云端只增不减红线：一律用 rclone copy）"
fi

echo "E2E-OK: 全仓脚本无 rclone sync（云端只增不减）"
