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
:root{--bg:#f6f5f2;--card:#fff;--ink:#1c1b19;--mute:#6f6c66;--line:#e4e1da;--accent:#2d5be3;--accent-bg:#e9eefc;--ok:#1f7a4d;--ok-bg:#e3f4ea;--warn:#b25e09;--warn-bg:#fdf0dc;--bad:#b3261e;--bad-bg:#fbe7e5}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--card:#1d1d1b;--ink:#ecebe7;--mute:#948f86;--line:#2e2d2a;--accent:#8fa8ff;--accent-bg:#20263f;--ok:#63cf98;--ok-bg:#16291f;--warn:#e8a558;--warn-bg:#2d2213;--bad:#f28b82;--bad-bg:#301a18}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:760px;margin:0 auto;padding:20px 16px 48px}
header{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px;margin-bottom:24px}
h1{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--mute);margin:0;font-weight:600}
#count{font-size:20px;font-weight:600;flex-basis:100%;order:2}
#note{font-size:13px;color:var(--mute);order:3;flex-basis:100%}
#note.err{color:var(--bad)}
section{margin-bottom:28px}
h2{display:flex;align-items:center;gap:8px;font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--mute);margin:0 0 8px;font-weight:600}
h2 .n{background:var(--line);color:var(--ink);border-radius:9px;padding:0 7px;font-size:12px}
section.hot h2{font-size:14px;color:var(--ink)}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin-bottom:8px}
.hot .card{border-left:4px solid var(--accent);padding:14px 16px}
.hot.ready .card{border-left-color:var(--ok)}
.decisions .card{border-left:4px solid var(--warn)}
.top{display:flex;gap:10px;align-items:baseline}
.id{font:12px ui-monospace,Menlo,monospace;color:var(--mute);flex:none}
.title{font-weight:600;flex:1;overflow-wrap:anywhere}
.hot .title{font-size:17px}
.meta{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px;font-size:12px;color:var(--mute)}
.tag{border-radius:4px;padding:1px 7px;background:var(--line);color:var(--ink)}
.tag.user{background:var(--accent-bg);color:var(--accent)}
.tag.flag{background:var(--bad-bg);color:var(--bad);font-weight:600}
.tag.ok{background:var(--ok-bg);color:var(--ok)}
details{margin-top:8px;font-size:13px}
summary{cursor:pointer;color:var(--mute)}
ol{margin:6px 0 0;padding-left:20px}
li{margin:3px 0}
li .fb{color:var(--mute)}
.quiet .card{padding:8px 12px}
.empty{color:var(--mute);text-align:center;padding:48px 0}
.fold>summary{font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:600;margin-bottom:8px}
</style></head><body><main>
<header><h1>Herdmaster board <span id="proj"></span></h1><div id="count">Loading</div><div id="note"></div></header>
<div id="board"></div>
</main>
<script>
const $=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e};
const age=s=>s<3600?Math.floor(s/60)+"m":s<172800?Math.floor(s/3600)+"h":Math.floor(s/86400)+"d";
function countLine(es){
  const rev=es.filter(e=>e.kind==="task"&&e.status==="in review");
  const p=[];
  if(rev.length){const t=Math.min(...rev.map(e=>Date.parse(e.updated)||Date.now()));p.push(rev.length+" in review (oldest "+age(Math.max(0,(Date.now()-t)/1000))+")")}
  const dr=es.filter(e=>e.kind==="task"&&e.status==="deploy-ready").length;if(dr)p.push(dr+" deploy-ready");
  const od=es.filter(e=>e.kind==="decision"&&e.status==="open").length;if(od)p.push(od+" decision open");
  const fl=es.filter(e=>(e.flags||[]).length).length;if(fl)p.push(fl+" flagged");
  return p.length?"Board: "+p.join(", "):"Board: nothing waiting on you";
}
function card(e){
  const c=$("div","card"),top=$("div","top");
  top.append($("span","id",e.id||"?"),$("span","title",e.title||"(untitled)"));c.append(top);
  const m=$("div","meta");
  if(e.review==="user")m.append($("span","tag user","your review"));
  (e.flags||[]).forEach(f=>m.append($("span","tag flag",f.startsWith("superseded:")?"superseded decision "+f.slice(11):f)));
  if((e.depends_on||[]).length)m.append($("span","",""+"needs "+e.depends_on.join(", ")));
  if(e.updated)m.append($("span","","updated "+e.updated.replace("T"," ").replace(/:\d\dZ$/,"Z")));
  if(m.childNodes.length)c.append(m);
  const at=e.attempts||[];
  if(at.length){
    const d=$("details"),s=$("summary","",at.length+(at.length>1?" attempts":" attempt")),ol=$("ol");
    at.forEach(a=>{const li=$("li","",a.status||"?");
      if(a.feedback)li.append($("span","fb"," — "+a.feedback));
      if(a.link)li.append($("span","fb"," ("+a.link+")"));ol.append(li)});
    d.append(s,ol);c.append(d);
  }
  return c;
}
function group(title,list,cls){
  if(!list.length)return null;
  const s=$("section",cls),h=$("h2","",title);h.append($("span","n",list.length));s.append(h);
  list.forEach(e=>s.append(card(e)));return s;
}
function fold(title,list){
  if(!list.length)return null;
  const s=$("section","quiet"),d=$("details","fold"),sm=$("summary","",title+" ("+list.length+")");
  d.append(sm);list.forEach(e=>d.append(card(e)));s.append(d);return s;
}
function render(b){
  const es=Array.isArray(b.entries)?b.entries:[];
  const t=es.filter(e=>e.kind!=="decision"),d=es.filter(e=>e.kind==="decision"),st=(l,s)=>l.filter(e=>e.status===s);
  const known=["in review","deploy-ready","working","finished","approved","blocked","failed"];
  const root=$("div");
  [group("In review",st(t,"in review"),"hot"),
   group("Deploy-ready",st(t,"deploy-ready"),"hot ready"),
   group("Open decisions",st(d,"open"),"decisions"),
   group("Failed",st(t,"failed")),group("Blocked",st(t,"blocked")),
   group("Working",st(t,"working")),group("Finished",st(t,"finished")),group("Approved",st(t,"approved")),
   group("Other",t.filter(e=>!known.includes(e.status))),
   fold("Settled decisions",st(d,"settled")),fold("Superseded decisions",st(d,"superseded")),
   group("Other decisions",d.filter(e=>!["open","settled","superseded"].includes(e.status)))
  ].forEach(x=>x&&root.append(x));
  if(!root.childNodes.length)root.append($("div","empty","The board is empty."));
  document.getElementById("board").replaceChildren(root);
  document.getElementById("count").textContent=countLine(es);
}
let last="";
async function tick(){
  const note=document.getElementById("note");
  try{
    const r=await fetch("/tasks.json",{cache:"no-store"});
    const txt=await r.text();
    if(!r.ok){let m="Board unavailable";try{m=JSON.parse(txt).error||m}catch(_){}
      note.textContent=m+". Retrying every 3s.";note.className="err";return}
    let b;try{b=JSON.parse(txt)}catch(_){note.textContent="Board file is not valid JSON. Showing last good view.";note.className="err";return}
    if(b.schema_version!==1){note.textContent="Unexpected schema_version "+b.schema_version+"; showing what can be read.";note.className="err"}
    else{note.textContent="";note.className=""}
    if(txt!==last){last=txt;render(b)}
  }catch(_){note.textContent="Viewer server unreachable. Retrying every 3s.";note.className="err"}
}
fetch("/project").then(r=>r.text()).then(t=>document.getElementById("proj").textContent="· "+t).catch(()=>{});
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
