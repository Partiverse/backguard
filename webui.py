#!/usr/bin/env python3
"""A2 本地只读状态页（research/12 §5）：borgweb 的最小增量形态。

零第三方依赖（stdlib http.server），只绑 127.0.0.1，只 GET，白名单路由。
它读什么、不读什么是隐私红线的实现面（AGENTS §1.1——「呈现即泄漏」）：

  渲染：timeline/STATUS.jsonl（A1，零文件名）、INTEGRITY.txt、CLOUD-VERIFY.txt、
        profile.json、最新一份快照的 STORY.md（明文层自身已按一级目录+计数渲染）
  永不渲染：runs/*.json（全量文件名清单）、preflight-latest.json（绝对路径）、
        manifest.json.enc（密封件）、rescue-test.txt（唯一带完整文件名的产物）

旁路纪律（§1.3）：只读；本进程崩了、被杀了都不影响备份本体——备份链路上没有任何
一环经过它。绑定 127.0.0.1 是访问控制：页面渲染的是备份状态叙述，永远不要
--bind 到非回环地址对外暴露（对照 mshopf/borg-webgui README 自认无访问控制的教训）。
"""
import argparse
import html
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 2 * 1024 * 1024  # 单响应上限：报告与 STORY 都是 KB 级，防手滑把大件端出去


def latest_snapshot(timeline: Path):
    """timeline/YYYY/MM/DD/HHMM-标签 的字典序最大者＝最新。两层都不存在则 None。"""
    if not timeline.is_dir():
        return None
    days = sorted(p for p in timeline.iterdir() if len(p.name) == 4 and p.is_dir())
    for day in reversed(days):
        for month in sorted((x for x in day.iterdir() if x.is_dir()), reverse=True):
            for d in sorted((x for x in month.iterdir() if x.is_dir()), reverse=True):
                snaps = sorted((x for x in d.iterdir() if x.is_dir()), reverse=True)
                if snaps:
                    return snaps[0]
    return None


def read_text(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")[:MAX_BODY]
    except OSError:
        return ""


def status_rows(timeline: Path):
    """STATUS.jsonl → list[dict]（坏行跳过并标注）。每轮一行，最新在文件尾。"""
    p = timeline / "STATUS.jsonl"
    if not p.is_file():
        return None, []
    rows, bad = [], 0
    for line in read_text(p).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            bad += 1
    return rows, bad


class Handler(BaseHTTPRequestHandler):
    server_version = "bg-webui/1"
    timeline: Path = None  # 由 make_server 注入

    def do_GET(self):
        self.route(self.path.split("?", 1)[0].rstrip("/") or "/")

    def do_HEAD(self):
        self.do_GET()

    def route(self, path):
        tl = self.timeline
        if path == "/":
            body = render_page(tl)
        elif path == "/status.json":
            p = tl / "STATUS.jsonl"
            body = read_text(p) if p.is_file() else ""
        elif path == "/story":
            snap = latest_snapshot(tl)
            body = read_text(snap / "STORY.md") if snap else "(no snapshot yet)"
        elif path in ("/report/integrity", "/report/cloud-verify", "/report/profile"):
            name = {"/report/integrity": "INTEGRITY.txt",
                    "/report/cloud-verify": "CLOUD-VERIFY.txt",
                    "/report/profile": "profile.json"}[path]
            body = read_text(tl / name)
        else:
            self.send_error(404)
            return
        data = body.encode("utf-8")
        ctype = "application/json; charset=utf-8" if path == "/status.json" else \
                "application/json; charset=utf-8" if path == "/report/profile" else \
                "text/plain; charset=utf-8" if path.startswith(("/report", "/story")) else \
                "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):  # 静默：访问日志落 stdout 会混进 launchd 输出
        pass


def render_page(tl: Path) -> str:
    rows, bad = status_rows(tl)
    snap = latest_snapshot(tl)
    story = read_text(snap / "STORY.md") if snap else "(还没有快照)"
    integ = read_text(tl / "INTEGRITY.txt")
    cloud = read_text(tl / "CLOUD-VERIFY.txt")
    e = html.escape
    if rows is None:
        stat_html = "<p>STATUS.jsonl 不存在——下一轮备份起每轮追加一行（A1）。</p>"
    else:
        th = ("<tr><th>时间</th><th>rc</th><th>耗时</th><th>引擎</th><th>sha</th>"
              "<th>引擎失败</th><th>推送失败</th><th>云端自证</th><th>完整性</th>"
              "<th>演练</th><th>快照数</th></tr>")
        trs = []
        for r in reversed(rows):
            drill = "-"
            if r.get("drill_pass") is not None:
                drill = "{}/{} pass，{} 天前".format(r.get("drill_pass"), r.get("drill_total"), r.get("drill_age_d"))
            cv = e(str(r.get("cv_state")))
            if r.get("cv_failed"):
                cv += " fail={}".format(r["cv_failed"])
            if r.get("cv_healed"):
                cv += " healed={}".format(r["cv_healed"])
            if r.get("cv_unknown"):
                cv += " unknown={}".format(r["cv_unknown"])
            ig = e(str(r.get("ig_state")))
            if r.get("ig_checks"):
                ig += " checks={}".format(r["ig_checks"])
            trs.append(
                "<tr><td>{}</td><td>{}</td><td>{}s</td><td>{}</td><td>{}</td>"
                "<td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                    e(str(r.get("ts"))), e(str(r.get("rc"))), e(str(r.get("dur_s"))),
                    e(str(r.get("engine"))), e(str(r.get("sha"))),
                    r.get("engine_failed"), r.get("cloud_push_failed"),
                    cv, ig, e(drill), r.get("snapshots")))
        stat_html = "<table>{}{}</table>".format(th, "".join(trs))
        if bad:
            stat_html = "<p class='warn'>STATUS.jsonl 有 {} 行解析失败（只跳过，不猜）</p>".format(bad) + stat_html
    return """<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="60">
<title>backguard 状态</title><style>
body{{font-family:-apple-system,sans-serif;margin:1.5em;max-width:72em;color:#1c1c1e}}
h2{{border-bottom:1px solid #ddd;padding-bottom:.2em;margin-top:1.6em}}
table{{border-collapse:collapse;font-size:.85em}}
th,td{{border:1px solid #ddd;padding:.25em .5em;text-align:left}}
pre{{background:#f6f6f6;padding:.8em;overflow-x:auto;font-size:.8em}}
.warn{{color:#b25000}}</style></head><body>
<h1>backguard 状态（本机只读）</h1>
<p>每 60s 自动刷新；永不渲染 runs/*.json、preflight、密封件与 rescue-test（隐私红线 §1.1）。</p>
<h2>每轮一行（STATUS.jsonl，新在上）</h2>{}
<h2>最新快照的 STORY</h2><pre>{}</pre>
<h2>INTEGRITY.txt</h2><pre>{}</pre>
<h2>CLOUD-VERIFY.txt</h2><pre>{}</pre>
</body></html>""".format(stat_html, e(story), e(integ) or "(未生成)", e(cloud) or "(未生成)")


def make_server(base: Path, port: int, bind: str):
    Handler.timeline = base / "timeline"
    return ThreadingHTTPServer((bind, port), Handler)


def main():
    ap = argparse.ArgumentParser(description="backguard 本地只读状态页")
    ap.add_argument("--base", required=True, help="BACKUP_BASE（timeline 的上一级）")
    ap.add_argument("--port", type=int, default=8334)
    ap.add_argument("--bind", default="127.0.0.1")
    a = ap.parse_args()
    base = Path(a.base)
    if not (base / "timeline").is_dir():
        raise SystemExit("timeline 不存在: {}".format(base / "timeline"))
    if a.bind != "127.0.0.1":
        raise SystemExit("拒绝非回环绑定：页面渲染备份状态，只许本机看")
    print("serving http://{}:{}  (base={})".format(a.bind, a.port, base))
    make_server(base, a.port, a.bind).serve_forever()


if __name__ == "__main__":
    main()
