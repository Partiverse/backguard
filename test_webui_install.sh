#!/usr/bin/env bash
# install-webui.sh（webui 常驻 launchd agent）的 E2E——只测「渲染面」，不测注册：
# launchctl 操作的是当前用户真实的 launchd 域，测试环境（CI/容器/开发机）一律不能装。
# 注册那一步的现场判据在脚本自己身上（bootstrap 后 curl 10s 内 200），真机手工跑一次即证。
# 断言四条：
#   ①渲染产物过 plutil -lint；
#   ②键面：Label、ProgramArguments 指到仓库里的 ui.sh、RunAtLoad、KeepAlive、两个日志路径
#     落在 $HOME/.local/share/partiverse-backup（与备份日志同一棵权限树）；
#   ③凭据纪律：plist 里一个口令/密钥字样都没有（webui 不读口令，模板也不许长出）；
#   ④渲染不落真实 LaunchAgents（WEBUI_NO_REGISTER 下 PLIST 必在临时目录）。
# 变异台账：
#   wi01 摘掉 KeepAlive 键        BITTEN count=1  首条=键面断言 KeepAlive
#   wi02 摘掉 RunAtLoad 键        BITTEN count=1  首条=键面断言 RunAtLoad
#   wi03 ProgramArguments 改指 /bin/echo
#                                BITTEN count=1  首条=键面断言 ui.sh 路径
#   另有一发**渲染面咬不到**（10-04 首装当场踩）：plist 写死 /bin/bash（3.2），ui.sh 一 source
#   config.sh（关联数组＝bash 4+）就 unbound variable，KeepAlive 进 crash-loop——渲染断言全绿、
#   只有真机注册那一步红。已修（挑 homebrew bash，与 init.sh 给 backup 的同一条逻辑）并登记：
#   **launchd ProgramArguments 的解释器版本是渲染面测不到的维度**，它的判据在脚本自带的
#   「bootstrap 后 10s 内 8334 起 200」那一步，真机装的时候证。
# 不覆盖：真实注册/拉起/崩溃回收（KeepAlive 的「拉回」半边无法在 CI 里安全演练——杀进程
# 会把 runner 的 launchd 域弄脏；真机手工跑一次 install-webui.sh 即是这条的现场证明）。
set -uo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-webui-install.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "E2E-FAIL: $1"; exit 1; }

command -v plutil >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 plutil（仅 macOS），未测"; exit 0; }

# ---------- 渲染（不注册；调用一律 bash 前缀——installer 类脚本无执行位入库） ----------
out="$(WEBUI_NO_REGISTER=1 bash "$V0_DIR/install-webui.sh")" || fail "install-webui.sh 渲染失败：$out"
plist="$(printf '%s' "$out" | /usr/bin/sed -n 's/^PLIST=//p')"
[[ -n "$plist" && -f "$plist" ]] || fail "没拿到渲染产物路径：$out"
[[ "$plist" == /tmp/bg-webui-install.* ]] || fail "④ 渲染落进了真实 LaunchAgents（$plist）——测试模式必须进临时目录"

# ① lint（脚本自己 lint 过一遍，这里对盘上产物再验一次：两层缺一不可）
plutil -lint "$plist" >/dev/null || fail "① plutil -lint 不过：$plist"

# ② 键面（plutil -p 转成可 grep 的文本，按键比较不 diff 文本——AGENTS §2 同一条）
dump="$(plutil -p "$plist")"
/usr/bin/grep -q '"com.partiverse.webui"' <<<"$dump" || fail "② Label 不对：$dump"
uipath=$(/usr/bin/grep -o '"/[^"]*/ui\.sh"' <<<"$dump" | head -1 | tr -d '"')
[[ -n "$uipath" && -x "$uipath" ]] || fail "② ProgramArguments 没指到可执行的 ui.sh：$dump"
/usr/bin/grep -q '"RunAtLoad" => true' <<<"$dump" || fail "② RunAtLoad 缺失：$dump"
/usr/bin/grep -q '"KeepAlive" => true' <<<"$dump" || fail "② KeepAlive 缺失：$dump"
/usr/bin/grep -q 'partiverse-backup/webui\.out\.log' <<<"$dump" \
    || fail "② StandardOutPath 没落在备份日志同棵树：$dump"
/usr/bin/grep -q 'partiverse-backup/webui\.err\.log' <<<"$dump" \
    || fail "② StandardErrorPath 没落在备份日志同棵树：$dump"

# ③ 凭据纪律：webui 不读口令，模板里一个凭据字样都不许长出来
if /usr/bin/grep -qiE 'PASSPHRASE|PASSWORD|SECRET|identity\.txt|secrets\.env' "$plist"; then
    fail "③ 模板里出现了凭据字样（webui 不该碰任何凭据）：$(/usr/bin/grep -iE 'PASSPHRASE|PASSWORD|SECRET' "$plist" | head -1)"
fi

echo "E2E-OK: webui 安装器渲染面（lint + 键面 + 凭据纪律 + 不落真实 LaunchAgents）"
