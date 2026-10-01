#!/usr/bin/env bash
# E2E：init.sh 全流程向导（隔离 HOME/CONF/rclone，local 后端不触网）。
# 验证：config.sh 生成的 includes/excludes 是多元素索引数组、首备跑通、
# timeline 语义层产物齐全、云端（local remote）收到备份。
# 用法: ./test_init_e2e.sh [v0 仓库根]（需 bash 5 与 borg/rclone，age 可选）
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-init-e2e.XXXXXX)"
trap 'rm -rf "$T"' EXIT   # 失败路径也要清：夹具可能含 age 私钥/解密出的明文账本，不能留在 /tmp

# 隔离环境：HOME 下造「存在」的用户目录；local remote 名与真实向导可选形态一致
mkdir -p "$T/home/.config" "$T/home/.ssh" "$T/home/Documents" "$T/home/Desktop"
# 老部署留下的同机可读日志（0644）：backup.sh 的修复 glob 必须把它一起收到 600
mkdir -p "$T/home/.local/share/partiverse-backup"
: > "$T/home/.local/share/partiverse-backup/decoy.log"
chmod 644 "$T/home/.local/share/partiverse-backup/decoy.log"
mkdir -p "$T/conf/partiverse-backup" "$T/home/.local/share/partiverse-backup/system-meta"
# 老部署留下的「全量文件名清单」与转储：runs/run-*.json 单个真机 22 MB，system-meta/ 是
# mounts/crontab 转储。两者都不叫 *.log，修复 glob 漏掉它们就等于留 0644（10-01 真机实测过）
mkdir -p "$T/home/.local/share/partiverse-backup/runs"
: > "$T/home/.local/share/partiverse-backup/runs/run-20260101-000000.json"
: > "$T/home/.local/share/partiverse-backup/system-meta/decoy-mounts.txt"
chmod 644 "$T/home/.local/share/partiverse-backup/runs/run-20260101-000000.json" \
    "$T/home/.local/share/partiverse-backup/system-meta/decoy-mounts.txt"
chmod 755 "$T/home/.local/share/partiverse-backup/runs" \
    "$T/home/.local/share/partiverse-backup/system-meta"
# 深层 decoy：修复式 chmod 改成整棵扫之后，被测对象就不再是「某个文件名」而是「任何
# 深度的一项」。这两处是列举式清单注定漏的形状——$CONF_DIR/age 子目录本身（真机 10-01
# 实测：nightly 已把 $CONF_DIR 收到 700，age/ 仍 0755、recipients.txt 仍 0644，因为 glob
# 只写了 *.log），以及「已收紧目录底下第二层」的旧文件（父目录闸门会回退，见红线 §2）
mkdir -p "$T/conf/partiverse-backup/age/sub" \
    "$T/home/.local/share/partiverse-backup/system-meta/dump"
# 名字一律带 decoy-：`recipients.txt` 是生产文件名，空文件会让语义层真去解析它
# （变异跑实测 [WARN] manifest 密封失败），等于悄悄改掉夹具的既有分支
: > "$T/conf/partiverse-backup/age/decoy-recipients.txt"
: > "$T/conf/partiverse-backup/age/sub/deep-identity.txt"
: > "$T/home/.local/share/partiverse-backup/system-meta/dump/deep.txt"
chmod 755 "$T/conf/partiverse-backup/age" "$T/conf/partiverse-backup/age/sub"
chmod 644 "$T/conf/partiverse-backup/age/decoy-recipients.txt" \
    "$T/conf/partiverse-backup/age/sub/deep-identity.txt" \
    "$T/home/.local/share/partiverse-backup/system-meta/dump/deep.txt"
mkdir -p "$T/dest"
printf '[Backguard]\ntype = local\n' > "$T/rclone.conf"

# 向导交互输入：密码 / 确认 / 选择已有 remote "Backguard" / 子路径回车
# INIT_SCHED_NO_REGISTER=1：调度模板照常渲染落盘，但不注册进真实 launchd/systemd/Task
# Scheduler——渲染出来的文件正是下面断言 5 的被测对象
printf 'test-pass-123\ntest-pass-123\nBackguard\n\n' | (
    cd "$T/dest"
    HOME="$T/home" XDG_CONFIG_HOME="$T/conf" RCLONE_CONFIG="$T/rclone.conf" \
    BACKUP_BASE="$T/repos" INIT_SCHED_NO_REGISTER=1 \
        bash "$V0_DIR/init.sh"
) > "$T/out.log" 2>&1 || { echo "E2E-FAIL: init.sh 退出非零"; tail -25 "$T/out.log"; exit 1; }

fail() { echo "E2E-FAIL: $1"; tail -25 "$T/out.log"; exit 1; }

# 断言 1：config.sh 的 includes 是多元素索引数组（旧版 bug 是整串单元素）
CFG="$T/conf/partiverse-backup/config.sh"
# shellcheck source=/dev/null
source "$CFG"
n_config=${#BORG_INCLUDES_config[@]}
[ "$n_config" -ge 2 ] || fail "BORG_INCLUDES_config 仅 $n_config 个元素（应为多元素数组）"
[ "${BORG_EXCLUDES_config[0]}" = "--exclude" ] || fail "BORG_EXCLUDES_config 不是逐模式数组"
[ "${BORG_EXCLUDES_config[1]}" = "**/node_modules/" ] || fail "excludes 第二元素异常"

# 断言 2：备份目标解析正确（remote:子路径，设备段由 backup.sh 追加）
[ "${BACKUP_TARGETS[0]}" = "Backguard:" ] || \
    fail "BACKUP_TARGETS 生成错误: ${BACKUP_TARGETS[0]}"

# 断言 3：本地仓库与语义层四件套
for cls in config files system; do
    [ -d "$T/repos/borg-$cls" ] || fail "本地仓库 borg-$cls 未创建"
done
[ -n "$(find "$T/repos/timeline" -name STORY.md 2>/dev/null)" ] || fail "timeline 无 STORY.md"
[ -n "$(find "$T/repos/timeline" -name MANIFEST.txt 2>/dev/null)" ] || fail "timeline 无 MANIFEST.txt"
# 形状守卫（10-01 去掉设备层）：快照直接挂在 timeline 根下的日期树里，profile.json 也在根。
# 判据用层级而不是 -name：`find -name STORY.md` 在旧的 timeline/<设备>/YYYY/… 下照样 PASS，
# 而设备层一旦回来，云端就成了 <remote>/<dev>/timeline/<dev>/YYYY/…（设备名两次）
[ -n "$(find "$T/repos/timeline" -mindepth 4 -maxdepth 4 -type d 2>/dev/null)" ] \
    || fail "timeline 根下没有 YYYY/MM/DD/HHMM-标签 快照目录（层级变了？）"
[ -z "$(find "$T/repos/timeline" -mindepth 1 -maxdepth 1 -type d ! -name '[0-9][0-9][0-9][0-9]' 2>/dev/null)" ] \
    || fail "timeline 根下出现非年份目录（设备层又回来了）"
[ -f "$T/repos/timeline/profile.json" ] || fail "profile.json 未落在 timeline 根"

# 断言 4：云端收到备份与 timeline。local 后端忽略 remote 名（"Backguard:x" 即 "x"），
# 真实 WebDAV/S3 remote 才有 remote 层——断言按 local 语义写在 cwd（=向导执行时 cwd）下
DEV_ID="$DEVICE_ID"
for cls in config files system; do
    [ -d "$T/dest/$DEV_ID/$cls" ] || fail "云端未收到 $cls"
done
[ -d "$T/dest/$DEV_ID/timeline" ] || fail "云端未收到 timeline"
# 云端形状同守卫：remote 已经带设备段，timeline 下再套一层设备目录就是重复
[ -n "$(find "$T/dest/$DEV_ID/timeline" -mindepth 4 -maxdepth 4 -type d 2>/dev/null)" ] \
    || fail "云端 timeline 下没有 YYYY/MM/DD/HHMM-标签 快照（多了一层设备目录？）"

# 断言 5：调度模板渲染产物——明文口令必须只活在 secrets.env(600) 里。
# launchd 的 plist 落在 ~/Library/LaunchAgents 且没有 600 保护，一旦把口令写进去
# 就等于把凭据放进了无保护目录（真机 2026-10-01 已按此把旧 plist 的
# EnvironmentVariables 删除，backup.sh 自己 `set -a; source secrets.env`）
case "$(uname -s)" in
    Darwin)
        PL="$T/home/Library/LaunchAgents/com.partiverse.backup.plist"
        [ -f "$PL" ] || fail "plist 未生成（调度模板没渲染）"
        plutil -lint "$PL" > /dev/null || fail "plist 不是合法 plist"
        # 不写 StandardOut/ErrorPath 时 launchd 把 stdout 丢进 os_log，
        # 02:34 那次跑挂了基本读不到，只剩 launchctl print 的一个退出码
        grep -q "StandardOutPath" "$PL" || fail "plist 缺 StandardOutPath：夜间失败没有现场"
        grep -q "StandardErrorPath" "$PL" || fail "plist 缺 StandardErrorPath"
        SCHED_DIR="$T/home/Library/LaunchAgents"
        ;;
    Linux)
        SU="$T/home/.config/systemd/user/partiverse-backup.service"
        [ -f "$SU" ] || fail "systemd unit 未生成（调度模板没渲染）"
        grep -q "^EnvironmentFile=" "$SU" || fail "systemd unit 缺 EnvironmentFile"
        SCHED_DIR="$T/home/.config/systemd/user"
        ;;
esac

# 全隔离 HOME 扫口令探针：除 secrets.env 外任何文件出现即视为泄漏
hits=$(grep -rl --exclude=secrets.env "test-pass-123" "$T/home" "$T/conf" "$T/repos" "$T/dest" 2>/dev/null || true)
[ -z "$hits" ] || fail "明文口令泄漏到调度/日志产物: $(echo "$hits" | tr '\n' ' ')"
# 注意写法：`[ -n "$(...)" ] && fail` 在未命中时返回 1，set -e 会让脚本静默中止
if [ -n "$(grep -rl "PASSPHRASE" "$SCHED_DIR" 2>/dev/null || true)" ]; then
    fail "调度文件里出现 PASSPHRASE 字样"
fi
if [ -n "$(find "$T/conf/partiverse-backup/secrets.env" ! -perm 600)" ]; then
    fail "secrets.env 不是 600"
fi

T_LOG_DIR="$T/home/.local/share/partiverse-backup"
T_CONF_DIR="$T/conf/partiverse-backup"
# 断言 6：凭据/日志/时间轴三棵「整棵都该私有」的树，逐节点验权限。
# **不点名文件**：列举式清单一晚漏过两次（先漏 runs/run-*.json 与 system-meta/，补齐后
# 又漏 $CONF_DIR/age 子目录本身——真机 nightly 收紧了 $CONF_DIR，age/ 仍是 0755）。
# 新增子目录/新深度不必再改这条断言，它自己就咬得住。
for root in "$T_CONF_DIR" "$T_LOG_DIR" "$T/repos/timeline"; do
    [ -d "$root" ] || fail "$root 未创建（权限断言失去对象）"
    # -xdev 无必要；只报前 3 项，失败信息要能一眼指认漏的是哪一层
    bad=$(find "$root" \( -type d ! -perm 700 \) -o \( -type f ! -perm 600 \) 2>/dev/null | head -3)
    if [ -n "$bad" ]; then
        fail "$root 底下仍有同机可读项（目录须 700、文件须 600）: $(echo "$bad" | tr '\n' ' ')"
    fi
done
# $BACKUP_BASE 只验目录本身：borg/restic 仓库内部文件由引擎自己建（实测 0600），
# 为几千个 chunk 每轮全扫不划算，且这条断言不该替引擎的决定负责
for d in "$T/repos"; do
    [ -d "$d" ] || fail "$d 未创建（权限断言失去对象）"
    # cut -c1-10：macOS 的 ls 会在权限串尾追加 '@'（扩展属性），完整比较会误判
    dm=$(ls -ld "$d" | awk '{print $1}' | cut -c1-10)
    [ "$dm" = "drwx------" ] || fail "目录没收到 700: $d → $dm"
done
case "$(uname -s)" in
    Darwin)
        # 预建 600：不 touch 时 launchd 按默认 umask 建出 0644，之后只追加不改权限
        for f in launchd.out.log launchd.err.log; do
            [ -f "$T_LOG_DIR/$f" ] || fail "$f 未预建：launchd 自建会落成 0644"
        done
        # RunAtLoad 让每次 launchctl load（装机、改配置后重载）都立刻多跑一发全量上传，
        # 观察期「一天几个快照」的口径会被搅浑（10-01 重载就多出一个 0241-night）。
        # 匹配 <key> 而不是裸词：说明注释一旦写进 plist，裸词 grep 会自己踩自己
        if grep -q "<key>RunAtLoad</key>" "$PL"; then
            fail "plist 仍写 RunAtLoad：重载即重跑备份"
        fi
        ;;
esac

echo "E2E-OK: init.sh 全流程（模板数组化 / 首备 / 语义层 / 云端同步 / 调度模板无明文口令 / 凭据与日志权限）通过"
