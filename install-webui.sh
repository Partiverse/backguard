#!/usr/bin/env bash
# webui 常驻（launchd agent）：开机自启（RunAtLoad）+ 崩了自动拉回（KeepAlive）。
# 与 backup 的调度模板共用同一条安装纪律（AGENTS §2/init.sh）：
#   模板从本脚本 heredoc 渲染、凭据一个不写（webui 本来就不读口令）、
#   StandardOut/ErrorPath 必写——不写时 stdout 进 os_log，挂了只剩 launchctl print 一个退出码。
# 与「调度模板不写 RunAtLoad」不冲突：那条防的是「load 即多跑一发全量备份」；
# 界面服务的目的恰是常驻在线，RunAtLoad + KeepAlive 在这里是本体不是缺陷。
# 用法（无执行位入库——Hook 对 installer 类脚本一律拦 chmod，统一用 bash 调用）：
#   bash install-webui.sh                      # 渲染到 ~/Library/LaunchAgents 并注册（先停旧实例）
#   WEBUI_NO_REGISTER=1 bash install-webui.sh  # 只渲染落盘（E2E/容器；输出 PLIST=<路径>）
# 卸载：launchctl bootout gui/$(id -u)/com.partiverse.webui
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$HOME/.local/share/partiverse-backup"
NO_REGISTER="${WEBUI_NO_REGISTER:-0}"

command -v python3 >/dev/null 2>&1 || { echo "E2E-FAIL: 需要 python3（webui 是 stdlib http.server）"; exit 1; }
[[ -f "$SCRIPT_DIR/ui.sh" ]] || { echo "E2E-FAIL: 找不到 ui.sh（脚本与 webui.py/ui.sh 必须同目录）"; exit 1; }
[[ -f "$SCRIPT_DIR/webui.py" ]] || { echo "E2E-FAIL: 找不到 webui.py"; exit 1; }

mkdir -p "$LOG_DIR"
# 日志先按 600 建好：launchd 自建按默认 umask 落 0644，而这里面有本机路径与访问记录
touch "$LOG_DIR/webui.out.log" "$LOG_DIR/webui.err.log"
chmod 600 "$LOG_DIR/webui.out.log" "$LOG_DIR/webui.err.log"

PLIST_DIR="$HOME/Library/LaunchAgents"
if [[ "$NO_REGISTER" == "1" ]]; then
    PLIST_DIR="$(mktemp -d /tmp/bg-webui-install.XXXXXX)"   # 渲染进临时目录，不碰真实 LaunchAgents
fi
mkdir -p "$PLIST_DIR"
PLIST="$PLIST_DIR/com.partiverse.webui.plist"
# launchd 的 PATH 里只有系统 bash 3.2，而 ui.sh 要 source config.sh——关联数组是 bash 4+ 的
# 东西（init.sh 给 backup 挑 bash 5 的同一条教训，10-04 首装当场踩：/bin/bash 下
# `declare -A` 一行直接 unbound variable，KeepAlive 进 crash-loop）
if [[ -x /opt/homebrew/bin/bash ]]; then LAUNCH_BASH=/opt/homebrew/bin/bash
elif [[ -x /usr/local/bin/bash ]]; then LAUNCH_BASH=/usr/local/bin/bash
else
    echo "E2E-FAIL: 未找到 bash 5（config.sh 需要）——先 brew install bash 再重跑"
    exit 1
fi
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.partiverse.webui</string>
    <key>ProgramArguments</key>
    <array><string>$LAUNCH_BASH</string><string>$SCRIPT_DIR/ui.sh</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/webui.out.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/webui.err.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null || { echo "E2E-FAIL: plutil -lint 不过：$PLIST"; exit 1; }

if [[ "$NO_REGISTER" == "1" ]]; then
    echo "PLIST=$PLIST"
    echo "（WEBUI_NO_REGISTER=1：模板已渲染，未注册 launchd）"
    exit 0
fi

# 注册前先停手工实例：webui 独占 8334，两个实例并存会让 KeepAlive 撞端口进 crash-loop
if pgrep -f '[w]ebui\.py' >/dev/null 2>&1; then
    echo "停掉已在跑的 webui 实例（launchd 即将接管）"
    pkill -f '[w]ebui\.py' || true
    sleep 1
fi

UID_NUM="$(id -u)"
LABEL=com.partiverse.webui
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true   # 未装载时报错是常态，忽略
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
# RunAtLoad 会立刻拉起；等它就绪（最多 10s），确认 8334 真的在服务
ok=""
for _ in $(seq 1 10); do
    code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8334/ 2>/dev/null || true)"
    [[ "$code" == "200" ]] && { ok=1; break; }
    sleep 1
done
if [[ -z "$ok" ]]; then
    echo "E2E-FAIL: bootstrap 后 10s 内 8334 没起来（现场：$LOG_DIR/webui.err.log 与 launchctl print gui/$UID_NUM/$LABEL）"
    exit 1
fi
echo "webui 已常驻（gui/$UID_NUM/$LABEL）：http://127.0.0.1:8334/（开机自启 + 崩溃自动拉回）"
