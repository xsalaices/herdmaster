#!/usr/bin/env python3
"""Read-only localhost viewer for ~/.claude/orchestrator/<project>/tasks.json (see docs/design/board.md).
Usage: herdmaster-viewer.py [--project NAME] [--port N]
Project defaults to $HERDMASTER_PROJECT, port to $HERDMASTER_VIEWER_PORT or 8765. Binds 127.0.0.1 only.
Single-threaded stdlib server: fine for one local viewer, swap in ThreadingHTTPServer if several tabs stall it."""
import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Herdmaster board</title>
<style>
:root{--bg:#f6f5f2;--card:#fff;--ink:#1c1b19;--mute:#6f6c66;--line:#e4e1da;--review:#2d5be3;--work:#8a867d;--ready:#1f7a4d;--fail:#b3261e;--ask:#b25e09}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--card:#1d1d1b;--ink:#ecebe7;--mute:#948f86;--line:#2e2d2a;--review:#8fa8ff;--work:#948f86;--ready:#63cf98;--fail:#f28b82;--ask:#e8a558}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:1000px;margin:0 auto;padding:24px 16px 48px}
#board{display:grid;grid-template-columns:1fr 1fr;gap:24px;align-items:start}
@media (max-width:640px){#board{grid-template-columns:1fr}}
section{margin-bottom:28px}
h2{display:flex;align-items:center;gap:8px;font-size:13px;letter-spacing:.06em;text-transform:uppercase;margin:0 0 8px;font-weight:700;color:var(--mute)}
h2 .n{font-weight:600}
.row{display:flex;align-items:baseline;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 14px;margin-bottom:6px}
.row .t{flex:1;overflow-wrap:anywhere}
.tag{flex:none;font:600 13px ui-monospace,Menlo,monospace;color:var(--mute);min-width:2.2em}
.pill{flex:none;font-size:12px;font-weight:600;border-radius:999px;padding:2px 10px;color:var(--c);border:1px solid var(--c)}
.row{flex-wrap:wrap}
.note{flex-basis:100%;color:var(--mute);font-size:14px}
.rec{flex-basis:100%;font-size:14px;color:var(--ask)}
.warn{color:var(--fail);font-size:13px;margin-left:8px}
.ask{--c:var(--ask)}.review{--c:var(--review)}.working{--c:var(--work)}.ready{--c:var(--ready)}.failed{--c:var(--fail)}
.empty{color:var(--mute);padding:12px 2px}
#note{font-size:13px;color:var(--fail);margin-bottom:16px}
</style></head><body><main>
<div id="note"></div>
<div id="board"></div>
</main>
<script>
const $=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e};
const STATUS={"in review":["review","In review"],"finished":["review","In review"],"working":["working","Working"],"blocked":["working","Working"],"approved":["working","Working"],"deploy-ready":["ready","Ready to deploy"],"failed":["failed","Failed"]};
const ORDER=["review","failed","working","ready"];
function row(e,cls,label){
  const r=$("div","row "+cls);r.append($("span","tag",(e.id||"").replace(/-0*/,"")),$("span","t",e.title||"(untitled)"));
  if((e.flags||[]).length)r.append($("span","warn","a decision changed"));
  if(label)r.append($("span","pill",label));
  if(e.note)r.append($("div","note",e.note));
  if(e.recommend)r.append($("div","rec","Recommended: "+e.recommend));return r;
}
function section(title,rows,none){
  const s=$("section"),h=$("h2","",title);h.append($("span","n",rows.length));s.append(h);
  if(!rows.length)s.append($("div","empty",none));
  rows.forEach(r=>s.append(r));return s;
}
function render(b){
  const es=Array.isArray(b.entries)?b.entries:[];
  const ds=es.filter(e=>e.kind==="decision"&&e.status==="open").map(e=>row(e,"ask","Needs you"));
  const tasks=es.filter(e=>e.kind!=="decision").map(e=>{const [c,l]=STATUS[e.status]||["working","Working"];return [c,l,e]});
  tasks.sort((x,y)=>ORDER.indexOf(x[0])-ORDER.indexOf(y[0]));
  document.getElementById("board").replaceChildren(section("Decisions needed",ds,"Nothing needs you."),section("Tasks",tasks.map(([c,l,e])=>row(e,c,l)),"No tasks yet."));
}
let last="";
async function tick(){
  const note=document.getElementById("note");
  try{
    const r=await fetch("/tasks.json",{cache:"no-store"});
    const txt=await r.text();
    if(!r.ok){let m="Board unavailable";try{m=JSON.parse(txt).error||m}catch(_){}
      note.textContent=m;return}
    let b;try{b=JSON.parse(txt)}catch(_){note.textContent="Board file is not valid JSON. Showing the last good view.";return}
    note.textContent="";
    if(txt!==last){last=txt;render(b)}
  }catch(_){note.textContent="Viewer server unreachable. Retrying."}
}
tick();setInterval(tick,3000);
</script></body></html>
"""


def make_handler(project, path):
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype):
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _json_error(self, code, msg):
            self._send(code, json.dumps({"error": msg}), "application/json")

        def do_GET(self):
            route = self.path.split("?", 1)[0]
            if route in ("/", "/index.html"):
                self._send(200, PAGE, "text/html; charset=utf-8")
            elif route == "/project":
                self._send(200, project, "text/plain; charset=utf-8")
            elif route == "/tasks.json":
                try:
                    with open(path, encoding="utf-8") as f:
                        raw = f.read()
                except FileNotFoundError:
                    return self._json_error(404, "No board yet for project '%s'" % project)
                except OSError as e:
                    return self._json_error(500, "Cannot read board: %s" % e.strerror)
                try:
                    doc = json.loads(raw)
                    if not isinstance(doc, dict):
                        raise ValueError
                except ValueError:
                    return self._json_error(422, "Board file is not valid JSON")
                self._send(200, raw, "application/json")
            else:
                self._json_error(404, "Not found")

        def _deny(self):
            self.send_response(405)
            self.send_header("Allow", "GET")
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _deny

        def do_HEAD(self):
            self._deny()

        def log_message(self, *a):
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser(description="Read-only board viewer on 127.0.0.1")
    ap.add_argument("--project", default=os.environ.get("HERDMASTER_PROJECT"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("HERDMASTER_VIEWER_PORT", "8765")))
    a = ap.parse_args()
    if not a.project or "/" in a.project or a.project.startswith("."):
        sys.exit("herdmaster-viewer: set HERDMASTER_PROJECT or pass --project NAME")
    path = os.path.expanduser("~/.claude/orchestrator/%s/tasks.json" % a.project)
    srv = HTTPServer(("127.0.0.1", a.port), make_handler(a.project, path))
    print("herdmaster viewer: http://127.0.0.1:%d/ (project %s)" % (srv.server_address[1], a.project), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
