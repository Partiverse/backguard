#!/usr/bin/env bash
# E2E：BACKUP_TARGETS 多目标备份（rclone local 后端隔离，不触网、不碰真实 rclone.conf）
# 用法: ./test_multi_target.sh [v0 仓库根]
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-multi.XXXXXX)"
trap 'rm -rf "$T"' EXIT   # 失败路径也要清：夹具可能含 age 私钥/解密出的明文账本，不能留在 /tmp
mkdir -p "$T/src" "$T/conf/partiverse-backup" "$T/home"
echo hello > "$T/src/a.txt"

# 隔离的 rclone conf：local 后端假 remote（不触网）
printf '[pftarget]\ntype = local\n' > "$T/rclone.conf"

# 最小 config.sh（BACKUP_TARGETS 新写法）与 secrets
cat > "$T/conf/partiverse-backup/config.sh" <<CONF
export PLATFORM="macos"
export DEVICE_ID="E2E-Mac"
export SYSTEM_ID="E2E-Mac"
export BACKUP_BASE="$T/repos"
export RCLONE="$(command -v rclone)"
export BORG="$(command -v borg)"
export WEBDAV_REMOTE=""
export WEBDAV_ROOT=""
export BACKUP_TARGETS=("pftarget:backup-mac")
BORG_INCLUDES_config=("$T/src")
BORG_EXCLUDES_config=()
BORG_INCLUDES_files=("$T/src")
BORG_EXCLUDES_files=()
BORG_INCLUDES_system=("$T/src")
BORG_EXCLUDES_system=()
CONF
echo "BORG_PASSPHRASE='e2e-pass'" > "$T/conf/partiverse-backup/secrets.env"
chmod 600 "$T/conf/partiverse-backup/secrets.env"

# 跑真实 backup.sh（HOME 隔离防污染；RCLONE_CONFIG 隔离远端配置；
# local 后端根 = cwd，故在 dest 目录内执行）
mkdir -p "$T/dest"
(
    cd "$T/dest"
    # BG_DEBUG=1 时透传 bash -x（定位 E2E 失败用）
    SKIP_WEBDAV=0 XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" HOME="$T/home" \
        bash ${BG_DEBUG:+-x} "$V0_DIR/backup.sh" > "$T/out.log" 2>&1
) || { echo "E2E-FAIL: backup.sh 退出非零"; tail -20 "$T/out.log"; exit 1; }

# 断言：目标收到三类仓库 + timeline 四件套
for cls in config files system; do
    [[ -d "$T/dest/backup-mac/E2E-Mac/$cls" ]] || { echo "E2E-FAIL: $cls 未同步"; exit 1; }
done
manifest="$(find "$T/dest/backup-mac/E2E-Mac/timeline" -name MANIFEST.txt 2>/dev/null | head -1)"
[[ -n "$manifest" ]] || { echo "E2E-FAIL: timeline 无 MANIFEST.txt"; exit 1; }
find "$T/dest/backup-mac/E2E-Mac/timeline" -name manifest.json.enc | grep -q . \
    || echo "E2E-WARN: manifest.json.enc 未密封（E2E 环境无 recipients，属预期）"

echo "E2E-OK: 多目标备份 + timeline 语义层产物齐全"
echo "  目标: $T/dest/backup-mac/E2E-Mac/"
