#!/usr/bin/env bash
# remote 能力探测（research/05 §1.4 已知坑的可执行化）：
# 不同云厂商的 WebDAV/S3 兼容实现在「大文件、服务端移动、分片上传、目录改名」
# 上行为不一致，且失败模式往往是 500/0-byte 而非明确报错。这里用小样本实测。
# 探测只写探针目录（.bg-caps/），跑完清理；结果供 init 写入 config 的注释与文档。
# 用法: ./test_remote_caps.sh [remote名]   默认 Universal Backups
set -uo pipefail
REMOTE="${1:-Universal Backups}"
PROBE=".bg-caps/probe-$$"
RCLONE="${RCLONE:-rclone}"

# 小样本：分别用 1MiB 与 8MiB 文件探测「大文件阈值」
mk() { dd if=/dev/zero of="$1" bs=1M count="$2" 2>/dev/null; }

cleanup() { "$RCLONE" purge "${REMOTE}:${PROBE}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ok() { printf '  %-22s %s\n' "$1" "$2"; }

echo "remote 能力探测: ${REMOTE}:"
"$RCLONE" lsd "${REMOTE}:" >/dev/null 2>&1 \
    && ok "连通性" "OK" \
    || { ok "连通性" "FAIL（无法列出根目录）"; exit 1; }

# 1. 大文件阈值（2MiB / 8MiB / 32MiB）
for mb in 2 8 32; do
    mk /tmp/.bg-probe-$mb.bin "$mb"
    if "$RCLONE" copy /tmp/.bg-probe-$mb.bin "${REMOTE}:${PROBE}/big-$mb.bin" >/dev/null 2>&1; then
        sz=$("$RCLONE" size "${REMOTE}:${PROBE}/big-$mb.bin" --json 2>/dev/null \
            | sed 's/.*"bytes":\([0-9]*\).*/\1/')
        [[ "${sz:-0}" -ge $((mb * 1024 * 1024)) ]] \
            && ok "上传 ${mb}MiB" "OK" || ok "上传 ${mb}MiB" "FAIL（大小不符 sz=${sz:-?}）"
    else
        ok "上传 ${mb}MiB" "FAIL（写入报错）"
    fi
    rm -f /tmp/.bg-probe-$mb.bin
done

# 2. 服务端目录移动（DirMove）——部分 WebDAV 500
if "$RCLONE" moveto "${REMOTE}:${PROBE}" "${REMOTE}:${PROBE}-moved" >/dev/null 2>&1; then
    ok "服务端移动" "OK"
    "$RCLONE" purge "${REMOTE}:${PROBE}-moved" >/dev/null 2>&1
else
    ok "服务端移动" "UNSUPPORTED（目录改名需逐文件 copy）"
fi

# 3. 空目录是否保留（WebDAV 常见不保留空目录——影响 timeline 骨架可见性）
"$RCLONE" mkdir "${REMOTE}:${PROBE}/emptydir" >/dev/null 2>&1
"$RCLONE" lsd "${REMOTE}:${PROBE}" 2>/dev/null | grep -q emptydir \
    && ok "空目录保留" "OK" || ok "空目录保留" "NO（不影响：产物目录恒有文件）"

# 4. 大小写敏感性（同名不同大小写是否被合并）——跨厂商行为不一致
mk /tmp/.bg-case-test.bin 1
"$RCLONE" copy /tmp/.bg-case-test.bin "${REMOTE}:${PROBE}/CaseTest.txt" >/dev/null 2>&1
"$RCLONE" copy /tmp/.bg-case-test.bin "${REMOTE}:${PROBE}/casetest.txt" >/dev/null 2>&1
n=$("$RCLONE" lsf "${REMOTE}:${PROBE}" 2>/dev/null | grep -ci "casetest.txt")
[[ "$n" -ge 2 ]] && ok "大小写敏感" "YES" || ok "大小写敏感" "NO（同名合并）"
rm -f /tmp/.bg-case-test.bin

echo "  → 结论写入 config.sh 注释与 research/05 §1.4（迁移新 remote 前先跑本探测）"
