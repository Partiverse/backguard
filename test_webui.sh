#!/usr/bin/env bash
# webui.py（A2 本地只读状态页）的 E2E：夹具 timeline + 真起进程 + curl 逐路断言。
# 判据四条：
#   ①白名单路由：/ /status.json /story /report/{integrity,cloud-verify,profile} 200；
#     其余一概 404（目录列举、快照目录、runs/、rescue-test.txt 全不在名单里）
#   ②最新快照语义：/story 只给「最新」那份（两层夹具互相当对照）
#   ③隐私红线（§1.1「呈现即泄漏」）：诱饵 token 植进 runs/*.json、rescue-test.txt、
#     preflight-latest.json、manifest.json.enc——**任何**响应里都不许出现；
#     绝对路径前缀同样不许
#   ④访问控制：拒绝非回环绑定（borg-webgui 自认无访问控制的教训，我们在启动时就挡）
# 变异台账：
#   w01 白名单 else 分支改成返回 200+空体（通配放行）  BITTEN count=N 首条=未知路径必须 404
# 不覆盖：ui.sh 的 config 读取（backup.sh 同一条路径，init/init E2E 各自覆盖）；并发（stdlib ThreadingHTTPServer）。
set -euo pipefail
V0_DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d /tmp/bg-webui.XXXXXX)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true' EXIT
fail() { echo "E2E-FAIL: $1"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 python3，未测"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "E2E-SKIP: 需要 curl，未测"; exit 0; }

TOKEN="SECRET-DO-NOT-SERVE-9f3a"
TL="$T/timeline"
# 两层快照：/story 的「最新」判据拿旧层当对照
mkdir -p "$TL/2026/10/01/0900-morning" "$TL/2026/10/03/2230-night"
echo "OLDER-STORY-v1" > "$TL/2026/10/01/0900-morning/STORY.md"
echo "LATEST-STORY-v2" > "$TL/2026/10/03/2230-night/STORY.md"
cat > "$TL/STATUS.jsonl" <<'EOF'
{"format":"backguard/status/1","ts":"2026-10-01T09:00:00+08:00","device":"e2e","engine":"borg","sha":"aaaaaaaaa","rc":0,"dur_s":10,"engine_failed":0,"cloud_push_failed":0,"cv_state":"skipped","cv_failed":0,"cv_healed":0,"cv_unknown":0,"ig_state":"pass","ig_checks":3,"ig_failed":0,"drill_pass":null,"drill_total":null,"drill_age_d":null,"snapshots":1}
this-line-is-deliberately-broken
{"format":"backguard/status/1","ts":"2026-10-03T22:30:00+08:00","device":"e2e","engine":"borg","sha":"bbbbbbbbb","rc":0,"dur_s":20,"engine_failed":0,"cloud_push_failed":0,"cv_state":"pass","cv_failed":0,"cv_healed":1,"cv_unknown":0,"ig_state":"pass","ig_checks":3,"ig_failed":0,"drill_pass":6,"drill_total":6,"drill_age_d":4,"snapshots":2}
EOF
printf '# 汇总: checks=3 FAIL=0 UNKNOWN=0\n' > "$TL/INTEGRITY.txt"
printf '# 云端副本自证 PASS\n' > "$TL/CLOUD-VERIFY.txt"
printf '{"device":"e2e-status","created":"2026-10-01"}\n' > "$TL/profile.json"
# 诱饵：四样「永不渲染」的件里各埋一个 token
printf '{"entries":["%s/秘密.txt"]}\n' "$TOKEN" > "$TL/2026/10/03/2230-night/manifest.json.enc"
printf 'rescue-test %s\n' "$TOKEN" > "$TL/rescue-test.txt"
printf '{"errors":[{"message":"/tmp/x/%s/y"}]}\n' "$TOKEN" > "$TL/preflight-latest.json"
mkdir -p "$TL/runs" && printf 'run-json %s\n' "$TOKEN" > "$TL/runs/run-20261003-223000.json"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 "$V0_DIR/webui.py" --base "$T" --port "$PORT" > "$T/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 50); do
    curl -fs -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.2
done

code_of() { curl -s -o /tmp/bg-webui-body -w '%{http_code}' "$@"; }
sweep() {  # 每个响应过两道隐私闸：token 与夹具绝对路径
    if grep -qF "$TOKEN" /tmp/bg-webui-body; then fail "隐私：响应里出现诱饵 token（$1）"; fi
    if grep -qF "$T" /tmp/bg-webui-body; then fail "隐私：响应里出现夹具绝对路径（$1）"; fi
}

# ① 白名单
[[ "$(code_of "http://127.0.0.1:$PORT/")" == "200" ]] || fail "/ 不是 200"
sweep "/"
grep -q 'LATEST-STORY-v2' /tmp/bg-webui-body || fail "首页没有渲染最新 STORY"
grep -q 'OLDER-STORY-v1' /tmp/bg-webui-body && fail "首页把旧快照的 STORY 也渲染了"
grep -q 'bbbbbbbbb' /tmp/bg-webui-body || fail "首页没渲染 STATUS 行"

[[ "$(code_of "http://127.0.0.1:$PORT/status.json")" == "200" ]] || fail "/status.json 不是 200"
grep -q '"snapshots":2' /tmp/bg-webui-body || fail "/status.json 内容不对"
sweep "/status.json"

[[ "$(code_of "http://127.0.0.1:$PORT/story")" == "200" ]] || fail "/story 不是 200"
grep -q 'LATEST-STORY-v2' /tmp/bg-webui-body || fail "/story 不是最新那份"
grep -q 'OLDER-STORY-v1' /tmp/bg-webui-body && fail "/story 拿了旧快照"
sweep "/story"

for r in integrity cloud-verify profile; do
    [[ "$(code_of "http://127.0.0.1:$PORT/report/$r")" == "200" ]] || fail "/report/$r 不是 200"
    sweep "/report/$r"
    if [[ "$r" == "integrity" ]]; then
        grep -q 'checks=3' /tmp/bg-webui-body || fail "/report/integrity 内容不对"
    fi
done

# ②②' 白名单之外一律 404——包括「看起来像在服务里」的路径
for p in "/timeline" "/2026" "/rescue-test.txt" "/runs/run-20261003-223000.json" \
         "/preflight-latest.json" "/manifest.json.enc" "/../secrets.env" \
         "/report/integrity/../../../secrets.env" "/STATUS.jsonl" "/report"; do
    [[ "$(code_of "http://127.0.0.1:$PORT$p")" == "404" ]] || fail "未知路径 $p 应 404"
    sweep "$p"
done

# POST 没有处理器（stdlib 默认 501）——只要不是 200 且不落体就满足「只读」
c="$(code_of -X POST "http://127.0.0.1:$PORT/status.json")"
[[ "$c" != "200" ]] || fail "POST 竟然 200——只读页出现了写通道"

# ③ 非回环绑定必须当场拒
if python3 "$V0_DIR/webui.py" --base "$T" --port "$PORT" --bind 0.0.0.0 >/dev/null 2>&1; then
    fail "0.0.0.0 绑定被放行——访问控制没上闸"
fi

echo "E2E-OK: webui 白名单路由 + 最新快照 + 隐私诱饵 + 只读 + 回环绑定"
