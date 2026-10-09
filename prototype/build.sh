#!/usr/bin/env bash
# 构建 bg 单文件 CLI（zipapp）：先跑全量测试，再产出 dist/bg.pyz 并同步 vendor 到 v0/
# 用法: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

python3 -m unittest test_bg_semantic -q

mkdir -p dist
python3 -m zipapp bg_semantic.py -o dist/bg.pyz -p "/usr/bin/env python3"
echo "built dist/bg.pyz ($(du -h dist/bg.pyz | cut -f1 | tr -d ' '))"

# 同步到 v0（vendor 目录，backup.sh/ps1 从这里解析入口）
VENDOR="${1:-../v0/semantic}"
if [[ -d "$VENDOR" ]]; then
    cp bg_semantic.py "$VENDOR/bg_semantic.py"
    cp test_bg_semantic.py "$VENDOR/test_bg_semantic.py"
    cp dist/bg.pyz "$VENDOR/bg.pyz"
    echo "vendored -> $VENDOR"
else
    echo "skip vendor: $VENDOR 不存在"
fi