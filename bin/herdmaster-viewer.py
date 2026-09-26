#!/usr/bin/env python3
"""Read-only localhost viewer for ~/.claude/orchestrator/<project>/tasks.json (see docs/design/board.md).
Usage: herdmaster-viewer.py [--project NAME] [--port N]
Without a project (--project or $HERDMASTER_PROJECT) it shows a tab per ~/.claude/orchestrator/*/tasks.json.
Port defaults to $HERDMASTER_VIEWER_PORT or 8765. Binds 127.0.0.1 only.
Single-threaded stdlib server: fine for one local viewer, swap in ThreadingHTTPServer if several tabs stall it."""
import argparse
import errno
import json
import os
import re
import sys
from urllib.parse import parse_qs, urlsplit
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Herdmaster board</title>
<style>
:root{color-scheme:light;--bg:#f6f5f2;--card:#fff;--ink:#1c1b19;--mute:#6f6c66;--line:#e4e1da;--review:#2d5be3;--work:#8a867d;--ready:#1f7a4d;--fail:#b3261e;--ask:#b25e09}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){color-scheme:dark;--bg:#141413;--card:#1d1d1b;--ink:#ecebe7;--mute:#948f86;--line:#2e2d2a;--review:#8fa8ff;--work:#948f86;--ready:#63cf98;--fail:#f28b82;--ask:#e8a558}}
:root[data-theme=dark]{color-scheme:dark;--bg:#141413;--card:#1d1d1b;--ink:#ecebe7;--mute:#948f86;--line:#2e2d2a;--review:#8fa8ff;--work:#948f86;--ready:#63cf98;--fail:#f28b82;--ask:#e8a558}
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
#tabs{display:flex;gap:4px;overflow-x:auto;margin:0 0 20px;border-bottom:1px solid var(--line);scrollbar-width:none}
#tabs::-webkit-scrollbar{display:none}
#tabs button{flex:none;display:flex;align-items:center;gap:6px;background:none;border:0;border-bottom:2px solid transparent;margin-bottom:-1px;padding:8px 12px;font:inherit;font-size:14px;color:var(--mute);cursor:pointer}
#tabs button:hover{color:var(--ink)}
#tabs button[aria-selected=true]{color:var(--ink);font-weight:600;border-bottom-color:var(--ink)}
.badge{font-size:11px;font-weight:700;line-height:1;border-radius:999px;padding:3px 7px;background:var(--ask);color:var(--bg)}
button:focus-visible{outline:2px solid var(--review);outline-offset:1px}
details{margin-top:4px}
summary{cursor:pointer;list-style:none;font-size:13px;letter-spacing:.06em;text-transform:uppercase;font-weight:700;color:var(--mute);padding:6px 0}
summary::-webkit-details-marker{display:none}
summary::before{content:"\25B8";display:inline-block;width:1.2em;transition:transform .15s}
details[open] summary::before{transform:rotate(90deg)}
.row.past{opacity:.75}
.more{font:13px ui-monospace,Menlo,monospace;color:var(--mute);background:none;border:1px solid var(--line);border-radius:6px;padding:4px 10px;margin-top:2px;cursor:pointer}
.more:hover{color:var(--ink);border-color:var(--mute)}
#note{font-size:13px;color:var(--fail);margin-bottom:16px}
header{display:flex;align-items:center;justify-content:space-between;margin:0 0 12px}
h1{font-size:14px;font-weight:600;letter-spacing:.02em;margin:0;color:var(--mute)}
#cog{display:flex;background:none;border:0;border-radius:6px;padding:6px;color:var(--mute);cursor:pointer}
#cog:hover,#cog[aria-expanded=true]{color:var(--ink)}
#cog svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
#panel{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:4px 14px 10px;margin:0 0 20px}
#panel h3{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--mute);margin:14px 0 6px;font-weight:700}
.set{display:flex;align-items:center;gap:10px;padding:6px 0;font-size:14px;min-height:36px}
.set>.k{flex:1;min-width:0}
.set .v{font:13px ui-monospace,Menlo,monospace;overflow-wrap:anywhere;text-align:right}
.set .v.none{color:var(--mute)}
.set select{font:inherit;font-size:14px;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:4px 6px;max-width:55%}
.hint{color:var(--mute);font-size:13px;margin:6px 0 0}
</style></head><body><main>
<header><h1>Herdmaster</h1><button id="cog" type="button" aria-label="Settings" aria-expanded="false" aria-controls="panel" title="Settings"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/></svg></button></header>
<div id="panel" hidden></div>
<nav id="tabs" role="tablist" hidden></nav>
<div id="note"></div>
<div id="board"></div>
<div id="past"></div>
</main>
<script>
const $=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e};
const STATUS={"in review":["review","In review"],"finished":["review","In review"],"working":["working","Working"],"blocked":["working","Working"],"approved":["working","Working"],"paused":["working","Paused"],"deploy-ready":["ready",null],"failed":["failed","Failed"]};
const ORDER=["review","failed","working","ready"];
const short=id=>(id||"").replace(/-0*/,"");
let ctx={suffix:"",word:"deploy",settings:{}},pastOpen=false,showAll=false;
const KEYS=["release","grid_panes","worker_layout","max_panes"];
const prefs={theme:"auto",done:10,tab:""};
try{const s=JSON.parse(localStorage.getItem("hm-prefs")||"{}");
  if(["auto","light","dark"].includes(s.theme))prefs.theme=s.theme;
  if(Number.isInteger(s.done)&&s.done>0)prefs.done=s.done;
  if(typeof s.tab==="string")prefs.tab=s.tab}catch(_){}
function setPref(k,v){prefs[k]=v;try{localStorage.setItem("hm-prefs",JSON.stringify(prefs))}catch(_){}applyTheme()}
function applyTheme(){const r=document.documentElement;if(prefs.theme==="auto")r.removeAttribute("data-theme");else r.dataset.theme=prefs.theme}
applyTheme();
function row(e,cls,label,past){
  const r=$("div","row "+cls+(past?" past":""));r.append($("span","tag",short(e.id)),$("span","t",e.title||"(untitled)"));
  if((e.flags||[]).length)r.append($("span","warn","a decision changed"));
  if(label)r.append($("span","pill",label));
  if(e.note)r.append($("div","note",e.note));
  if(e.recommend)r.append($("div","rec","Recommended: "+e.recommend));
  return r;
}
function section(title,rows,none){
  const s=$("section"),h=$("h2","",title);h.append($("span","n",rows.length));s.append(h);
  if(!rows.length)s.append($("div","empty",none));
  rows.forEach(r=>s.append(r));return s;
}
function render(b){
  const es=Array.isArray(b.entries)?b.entries:[];
  const ds=es.filter(e=>e.kind==="decision"&&e.status==="open").map(e=>row(e,"ask","Needs you"));
  const tasks=es.filter(e=>e.kind!=="decision"&&e.status!=="done"&&e.status!=="cancelled").map(e=>{const [c,l]=STATUS[e.status]||["working","Working"];return [c,l||"Ready to "+ctx.word,e]});
  tasks.sort((x,y)=>ORDER.indexOf(x[0])-ORDER.indexOf(y[0]));
  document.getElementById("board").replaceChildren(section("Decisions needed",ds,"Nothing needs you."),section("Tasks",tasks.map(([c,l,e])=>row(e,c,l)),"No tasks yet."));
  const past=es.filter(e=>e.kind!=="decision"&&(e.status==="done"||e.status==="cancelled"));
  const pe=document.getElementById("past");
  if(!past.length){pe.replaceChildren();return}
  past.sort((x,y)=>String(y.updated||"").localeCompare(String(x.updated||"")));
  const d=$("details"),s=$("summary","","Done");s.append(" ",$("span","n",past.length));d.append(s);d.open=pastOpen;
  d.ontoggle=()=>{pastOpen=d.open};
  past.slice(0,showAll?past.length:prefs.done).forEach(e=>d.append(row(e,"working",e.status==="cancelled"?"cancelled":"done",true)));
  if(past.length>prefs.done){const m=$("button","more",showAll?"show fewer":"show all "+past.length);m.type="button";m.onclick=()=>{showAll=!showAll;last="";tick()};d.append(m)}
  pe.replaceChildren(d);
}
let last="",lastPanel="",tabs=[],fixed=true,cur=null,picked=false;
function sel(opts,val,onchange){
  const s=$("select");opts.forEach(([v,l])=>{const o=$("option","",l);o.value=v;o.selected=String(v)===val;s.append(o)});
  s.onchange=()=>onchange(s.value);return s;
}
function setRow(label,ctl){const r=$("div","set");r.append($("span","k",label),ctl);return r}
function renderPanel(){
  const key=JSON.stringify([ctx.settings,tabs.map(p=>p.name),fixed,ctx.suffix]);
  if(key===lastPanel)return;lastPanel=key;
  const p=document.getElementById("panel");
  const pf=$("h3","","This browser");
  const rows=[setRow("Theme",sel([["auto","Auto"],["light","Light"],["dark","Dark"]],prefs.theme,v=>setPref("theme",v))),
    setRow("Done items shown",sel([5,10,25,50].map(n=>[n,n]),String(prefs.done),v=>{setPref("done",+v);last="";tick()}))];
  if(!fixed&&tabs.length>1)rows.push(setRow("Opens first",sel([["","Most decisions needed"],...tabs.map(t=>[t.name,t.name])],prefs.tab,v=>setPref("tab",v))));
  const sh=$("h3","","Project settings"+(ctx.suffix?" "+ctx.suffix.trim():""));
  const sr=KEYS.map(k=>{
    const v=ctx.settings[k],has=v!==undefined&&v!==null;
    const val=$("span","v"+(has?"":" none"),has?(typeof v==="object"?JSON.stringify(v):String(v)):"default");
    const r=$("div","set");r.append($("span","k",k),val);return r;
  });
  p.replaceChildren(pf,...rows,sh,...sr,$("p","hint","Read-only. Ask the planner to change these."));
}
function renderTabs(){
  const nav=document.getElementById("tabs");
  nav.hidden=fixed;if(fixed)return;
  nav.replaceChildren(...tabs.map(p=>{
    const b=$("button","",p.name);b.type="button";b.setAttribute("role","tab");b.setAttribute("aria-selected",p.name===cur);
    if(p.needed>0){b.append($("span","badge",p.needed));b.title=p.needed+" decision"+(p.needed>1?"s":"")+" needed"}
    b.onclick=()=>{cur=p.name;picked=true;last="";tick()};return b;
  }));
}
async function tick(){
  const note=document.getElementById("note");
  try{
    const pr=await fetch("/projects.json",{cache:"no-store"});
    const pj=await pr.json();
    fixed=pj.fixed;tabs=pj.projects;
    if(!tabs.some(p=>p.name===cur))picked=false;
    if(!picked)cur=tabs.find(p=>p.name===prefs.tab)?.name||tabs.reduce((m,p)=>!m||p.needed>m.needed?p:m,null)?.name||null;
    ctx.suffix=!fixed&&tabs.length>1?" ("+cur+")":"";
    renderTabs();
    if(cur===null&&!fixed){note.textContent="No boards yet.";document.getElementById("board").replaceChildren();document.getElementById("past").replaceChildren();return}
    const q=fixed?"":"?project="+encodeURIComponent(cur);
    const [r,sr]=await Promise.all([fetch("/tasks.json"+q,{cache:"no-store"}),fetch("/settings.json"+q,{cache:"no-store"})]);
    const txt=await r.text();
    if(!r.ok){let m="Board unavailable";try{m=JSON.parse(txt).error||m}catch(_){}
      note.textContent=m;return}
    let b;try{b=JSON.parse(txt)}catch(_){note.textContent="Board file is not valid JSON. Showing the last good view.";return}
    try{const st=await sr.json();ctx.settings=st&&typeof st==="object"&&!Array.isArray(st)?st:{}}catch(_){ctx.settings={}}
    ctx.word=["merge","deploy","push","ship"].includes(ctx.settings.release)?ctx.settings.release:"deploy";
    renderPanel();
    note.textContent="";
    const key=cur+"\n"+ctx.word+"\n"+ctx.suffix+"\n"+prefs.done+"\n"+showAll+"\n"+txt;
    if(key!==last){last=key;render(b)}
  }catch(_){note.textContent="Viewer server unreachable. Retrying."}
}
document.getElementById("cog").onclick=e=>{const p=document.getElementById("panel");p.hidden=!p.hidden;e.currentTarget.setAttribute("aria-expanded",!p.hidden)};
tick();setInterval(tick,3000);
</script></body></html>
"""


NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.loads(f.read())


def open_decisions(path):
    try:
        entries = read_json(path).get("entries", [])
        return sum(1 for e in entries if isinstance(e, dict) and e.get("kind") == "decision" and e.get("status") == "open")
    except (OSError, ValueError, AttributeError):
        return 0


def list_projects(root):
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    out = []
    for n in names:
        board = os.path.join(root, n, "tasks.json")
        if NAME_RE.fullmatch(n) and os.path.isfile(board):
            out.append({"name": n, "needed": open_decisions(board)})
    return out


def project_settings(root, project):
    try:
        doc = read_json(os.path.join(root, project, "settings.json"))
    except (OSError, ValueError):
        return {}
    return doc if isinstance(doc, dict) else {}


def make_handler(fixed, root):
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

        def _project(self, query):
            if fixed:
                return fixed
            name = (parse_qs(query).get("project") or [""])[0]
            if not NAME_RE.fullmatch(name) or ".." in name:
                self._json_error(400, "Invalid project name")
                return None
            return name

        def do_GET(self):
            u = urlsplit(self.path)
            route = u.path
            if route in ("/", "/index.html"):
                self._send(200, PAGE, "text/html; charset=utf-8")
            elif route == "/project" and fixed:
                self._send(200, fixed, "text/plain; charset=utf-8")
            elif route == "/projects.json":
                if fixed:
                    projects = [{"name": fixed, "needed": open_decisions(os.path.join(root, fixed, "tasks.json"))}]
                else:
                    projects = list_projects(root)
                self._send(200, json.dumps({"fixed": bool(fixed), "projects": projects}), "application/json")
            elif route == "/settings.json":
                project = self._project(u.query)
                if project:
                    self._send(200, json.dumps(project_settings(root, project)), "application/json")
            elif route == "/tasks.json":
                project = self._project(u.query)
                if not project:
                    return
                try:
                    with open(os.path.join(root, project, "tasks.json"), encoding="utf-8") as f:
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
    if a.project and (not NAME_RE.fullmatch(a.project) or ".." in a.project):
        sys.exit("herdmaster-viewer: invalid project name '%s'" % a.project)
    root = os.path.expanduser("~/.claude/orchestrator")
    try:
        srv = HTTPServer(("127.0.0.1", a.port), make_handler(a.project, root))
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        sys.exit("herdmaster-viewer: port %d is already in use; pass --port N to pick another" % a.port)
    print("herdmaster viewer: http://127.0.0.1:%d/ (%s)" % (srv.server_address[1], "project " + a.project if a.project else "all projects"), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
