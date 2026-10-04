#!/usr/bin/env bash
# webui.py（A2 本地只读状态页）的 E2E：夹具 timeline + 真起进程 + curl 逐路断言。
# 判据五条：
#   ①白名单路由：/ /status.json /story /report/{integrity,cloud-verify,profile} 200；
#     其余一概 404（目录列举、快照目录、runs/、rescue-test.txt 全不在名单里）
#   ②最新快照语义：/story 只给「最新」那份（两层夹具互相当对照）
#   ③隐私红线（§1.1「呈现即泄漏」）：诱饵 token 植进 runs/*.json、rescue-test.txt、
#     preflight-latest.json、manifest.json.enc——**任何**响应里都不许出现；
#     绝对路径前缀同样不许；timeline 外的 secrets.env 与逃逸 canary 同闸覆盖
#   ④访问控制：拒绝非回环绑定（borg-webgui 自认无访问控制的教训，我们在启动时就挡）
#   ⑤快照内容预览 /snapshot/YYYY/MM/DD/HHMM-标签/四件套：三层校验（层级正则 +
#     精确文件白名单 + resolve 落点闸[外向逃逸与内向禁区件 symlink 都拒]），
#     任一层摘掉对应断言必须红（见变异台账；层①另配 py 级 mock 断言两宿主同咬）；
#     拒绝面（坏形状/非白名单/不存在/symlink 逃逸）统一 404 无差异化消息防枚举；
#     遍历样本一律 curl --path-as-is 发（否则 curl 客户端先归一化，断言空转）
# 变异台账：
#   w01 白名单 else 分支改成返回 200+空体（通配放行）  BITTEN count=N 首条=未知路径必须 404
#   w02 层级正则整组短路（年月日/HHMM-标签不再校验）  BITTEN ⑤'py 级层①断言
#       「2230-NIGHT 应 None」——mock 层③放行、无 FS 参与，两宿主（mac/linux CI）同咬。
#       覆盖缺口登记：HTTP 面「2230-NIGHT 应 404」断言在 mac 上靠 APFS 大小写折叠咬合，
#       在大小写敏感的 linux 车道（ci.yml 只挂 linux job）此刀测不到——层①行为面以
#       py 级断言为准，HTTP 断言仅作本机（=生产宿主）旁证
#   w03 文件白名单放开（任意末段放行，只靠存在性兜底）  BITTEN 「exclusions.json 应 404」
#   w04 resolve 落点闸摘除（只查 is_file）  BITTEN 「白名单名 symlink 逃逸应 404」
#   w05 preview 无视 URL 日期恒取最新快照  BITTEN 「指定旧快照没拿旧件」
#   w06 preview 掉出 text/plain 路由族（按 text/html 出）  BITTEN 「Content-Type 应 text/plain」
#   w07 落点闸内向分支摘除（去掉 resolve 末段白名单检查，只靠 is_relative_to+is_file）
#       BITTEN 「内向 symlink …/1100-noon/{COVERAGE.txt,restore.md} 应 404」
#       （外向 canary 仍被 is_relative_to 挡住不红，内向指向根内禁区件必红）
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
# 两层快照：/story 的「最新」判据拿旧层当对照；两份都补齐 §1.1 四件套且内容可区分
# （OLDER-*/LATEST-*）——对拍「指定旧快照路由拿旧件不拿最新件」。
# 四件套内容只有标记串，不埋诱饵 token（诱饵纪律：token 只进「永不渲染」件）
mkdir -p "$TL/2026/10/01/0900-morning" "$TL/2026/10/03/2230-night"
echo "OLDER-STORY-v1" > "$TL/2026/10/01/0900-morning/STORY.md"
echo "OLDER-MANIFEST-v1" > "$TL/2026/10/01/0900-morning/MANIFEST.txt"
echo "OLDER-RESTORE-v1" > "$TL/2026/10/01/0900-morning/restore.md"
echo "LATEST-STORY-v2" > "$TL/2026/10/03/2230-night/STORY.md"
echo "LATEST-MANIFEST-v2" > "$TL/2026/10/03/2230-night/MANIFEST.txt"
echo "LATEST-COVERAGE-v2" > "$TL/2026/10/03/2230-night/COVERAGE.txt"
echo "LATEST-RESTORE-v2" > "$TL/2026/10/03/2230-night/restore.md"
# 边界件：真实快照目录里确实存在、但不在四件套白名单——白名单从紧不开口子
echo '{"exclude":["*.cache"]}' > "$TL/2026/10/03/2230-night/exclusions.json"
# 落点闸样本：旧快照的白名单名（COVERAGE.txt）做成指向 timeline 外的 symlink；
# canary 放 $T 内、timeline 外（与遍历目标同层，trap 一并清走）
echo "ESCAPE-CANARY-NOT-FOR-SERVE" > "$T/escape-canary.txt"
ln -sfn "$T/escape-canary.txt" "$TL/2026/10/01/0900-morning/COVERAGE.txt"
# 内向 symlink：白名单名指向 timeline 根内的禁区件——runs/*.json（全量文件名清单）与
# rescue-test.txt（唯一带完整文件名产物）都在「永不渲染」清单里，is_relative_to 对
# 根内目标恒真，必须靠「resolve 后末段仍是白名单名」这半闸挡（评审探针同款）
mkdir -p "$TL/2026/10/02/1100-noon"
ln -sfn ../../../../rescue-test.txt "$TL/2026/10/02/1100-noon/COVERAGE.txt"
ln -sfn ../../../../runs/run-20261003-223000.json "$TL/2026/10/02/1100-noon/restore.md"
# 遍历目标：timeline 外的 secrets.env，内容用诱饵 token 当哨兵——sweep 第一道闸直接覆盖它
echo "outside-timeline $TOKEN" > "$T/secrets.env"

# ⑤' 层①/层②的 py 级断言：mock 掉层③碰盘（resolve/is_file 全放行），坏段/坏名若放行
# 就会拼进路径返回非 None——无 FS 参与，两宿主（含大小写敏感的 linux CI 车道）同咬，
# 不依赖 APFS 折叠；末尾正例证明 mock 环境真实放行，防断言假绿
python3 - "$V0_DIR" "$TL" <<'PYEOF' || fail "preview 层①/层② py 级断言失败（两宿主同咬）"
import sys
from pathlib import Path
from unittest import mock
sys.path.insert(0, sys.argv[1])
from webui import snapshot_file
tl = Path(sys.argv[2])
with mock.patch("pathlib.Path.resolve", return_value=Path("/mock/fine/STORY.md")), \
     mock.patch("pathlib.Path.is_file", return_value=True):
    for bad in ("/snapshot/2026/10/03/2230-NIGHT/STORY.md",
                "/snapshot/2026/10/03/230-night/STORY.md",
                "/snapshot/2026/13/03/2230-night/STORY.md",
                "/snapshot/2026/10/00/2230-night/STORY.md",
                "/snapshot//2026/10/03/2230-night/STORY.md",
                "/snapshot/2026/10/03/2230-night/story.md",
                "/snapshot/2026/10/03/2230-night/manifest.json.enc"):
        assert snapshot_file(tl, bad) is None, "应被拒: %s" % bad
    assert snapshot_file(tl, "/snapshot/2026/10/03/2230-night/STORY.md") is not None, \
        "mock 放行下合法形状应非 None（防断言假绿）"
print("PY-GATE-OK")
PYEOF
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

# ①' 快照内容预览：/snapshot/YYYY/MM/DD/HHMM-标签/四件套（判据⑤）
SNAP_NEW="2026/10/03/2230-night"; SNAP_OLD="2026/10/01/0900-morning"
pnames=(STORY.md MANIFEST.txt COVERAGE.txt restore.md)
pmarks=(LATEST-STORY-v2 LATEST-MANIFEST-v2 LATEST-COVERAGE-v2 LATEST-RESTORE-v2)
for i in 0 1 2 3; do
    f="${pnames[i]}"; mark="${pmarks[i]}"
    [[ "$(code_of "http://127.0.0.1:$PORT/snapshot/$SNAP_NEW/$f")" == "200" ]] || fail "preview 最新快照 $f 不是 200"
    grep -qF "$mark" /tmp/bg-webui-body || fail "preview $f 内容不对（缺 ${mark}）"
    grep -qF 'OLDER-STORY-v1' /tmp/bg-webui-body && fail "preview $f 混进了旧快照内容"
    sweep "preview-new/$f"
done
# Content-Type 口径：四件套按明文出（text/plain; charset=utf-8），带 nosniff
curl -s -I "http://127.0.0.1:$PORT/snapshot/$SNAP_NEW/STORY.md" > "$T/preview-head"
grep -qi '^content-type: text/plain; charset=utf-8' "$T/preview-head" || fail "preview Content-Type 应 text/plain; charset=utf-8"
grep -qi '^x-content-type-options: nosniff' "$T/preview-head" || fail "preview 缺 nosniff"
# HEAD 同 200
hc="$(curl -s -I -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/snapshot/$SNAP_NEW/STORY.md")"
[[ "$hc" == "200" ]] || fail "preview HEAD 不是 200（got ${hc}）"
# 指定旧快照拿旧件、不串到最新件（同 §①② 的互为对照手法）
[[ "$(code_of "http://127.0.0.1:$PORT/snapshot/$SNAP_OLD/STORY.md")" == "200" ]] || fail "preview 旧快照 STORY 不是 200"
grep -qF 'OLDER-STORY-v1' /tmp/bg-webui-body || fail "preview 指定旧快照没拿旧件"
grep -qF 'LATEST-STORY-v2' /tmp/bg-webui-body && fail "preview 指定旧快照拿了最新件"
sweep "preview-old/STORY.md"
[[ "$(code_of "http://127.0.0.1:$PORT/snapshot/$SNAP_OLD/MANIFEST.txt")" == "200" ]] || fail "preview 旧快照 MANIFEST 不是 200"
grep -qF 'OLDER-MANIFEST-v1' /tmp/bg-webui-body || fail "preview 旧快照 MANIFEST 内容不对"
sweep "preview-old/MANIFEST.txt"
# 落点闸：白名单名 symlink 逃逸——resolve 出 timeline 根就 404，canary 不得出现在响应里
[[ "$(code_of "http://127.0.0.1:$PORT/snapshot/$SNAP_OLD/COVERAGE.txt")" == "404" ]] || fail "白名单名 symlink 逃逸应 404"
sweep "symlink-escape"
grep -qF 'ESCAPE-CANARY' /tmp/bg-webui-body && fail "symlink 逃逸泄出 timeline 外内容"
# 落点闸内向分支：白名单名 symlink 指向根内禁区件同样 404——禁区件都埋了诱饵 token，sweep 兜底
for p in "/snapshot/2026/10/02/1100-noon/COVERAGE.txt" "/snapshot/2026/10/02/1100-noon/restore.md"; do
    [[ "$(code_of "http://127.0.0.1:$PORT$p")" == "404" ]] || fail "内向 symlink $p 应 404"
    sweep "inward-symlink $p"
done
# 拒绝面统一 404（坏段/非白名单/不存在快照/遍历/URL 编码），无差异化原因防枚举
# 遍历与编码样本必须 --path-as-is：否则 curl 客户端先归一化，断言空转
for p in \
    "/snapshot/$SNAP_NEW/../../../secrets.env" \
    "/snapshot/../../secrets.env" \
    "/snapshot/%2e%2e/secrets.env" \
    "/snapshot/$SNAP_NEW/..%2fmanifest.json.enc" \
    "/snapshot/$SNAP_NEW/exclusions.json" \
    "/snapshot/$SNAP_NEW/manifest.json.enc" \
    "/snapshot/$SNAP_NEW/story.md" \
    "/snapshot/$SNAP_NEW/STORY.md.bak" \
    "/snapshot/$SNAP_NEW/NOPE.txt" \
    "/snapshot/$SNAP_NEW/rescue-test.txt" \
    "/snapshot/2026/10/03/2230-NIGHT/STORY.md" \
    "/snapshot/2026/10/03/230-night/STORY.md" \
    "/snapshot/2026/13/03/2230-night/STORY.md" \
    "/snapshot/2026/10/00/2230-night/STORY.md" \
    "/snapshot//2026/10/03/2230-night/STORY.md" \
    "/snapshot/2026/10/02/1200-noon/STORY.md" \
    "/snapshot" \
    "/snapshot/" ; do
    [[ "$(code_of --path-as-is "http://127.0.0.1:$PORT$p")" == "404" ]] || fail "preview 拒绝面 $p 应 404"
    sweep "preview-404 $p"
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

echo "E2E-OK: webui 白名单路由 + 最新快照 + 快照预览三层校验 + 隐私诱饵 + 只读 + 回环绑定"
