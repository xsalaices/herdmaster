#!/usr/bin/env python3
"""Read-only localhost viewer for ~/.claude/orchestrator/<project>/tasks.json (see docs/design/board.md).
Usage: herdmaster-viewer.py [--project NAME] [--port N]
Without a project (--project or $HERDMASTER_PROJECT) it shows a tab per ~/.claude/orchestrator/*/tasks.json.
Port defaults to $HERDMASTER_VIEWER_PORT or 8765. Binds 127.0.0.1 only.
$HERDR_BIN (default herdr) is asked which workspace is focused for /focus.json.
Single-threaded stdlib server: fine for one local viewer, swap in ThreadingHTTPServer if several tabs stall it."""
import argparse
import errno
import json
import os
import re
import subprocess
import sys
import time
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
main{max-width:1100px;margin:0 auto;padding:24px 16px 48px}
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
.pop{position:relative}
#cog{display:flex;background:none;border:0;border-radius:8px;padding:6px;color:var(--mute);cursor:pointer}
#cog:hover,#cog[aria-expanded=true]{color:var(--ink);background:var(--line)}
#cog:focus-visible{outline:2px solid var(--review);outline-offset:2px}
#cog svg{width:19px;height:19px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
#panel{position:absolute;right:0;top:calc(100% + 8px);z-index:10;width:min(320px,calc(100vw - 32px));background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;box-shadow:0 8px 28px rgba(0,0,0,.16),0 1px 3px rgba(0,0,0,.1)}
#panel[hidden]{display:none}
#panel .ttl{font-size:15px;font-weight:600;line-height:1.3}
#panel .sub{font-size:13px;color:var(--mute);margin:2px 0 0}
#panel h3{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--mute);margin:16px 0 4px;font-weight:600}
#panel header+h3,#panel .hd+h3{margin-top:14px}
.set{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:6px 0;font-size:14px;min-height:34px}
.set>.k{min-width:0}
.set .v{font:12.5px ui-monospace,Menlo,monospace;overflow-wrap:anywhere;text-align:right}
.set .v.none{color:var(--mute);font-family:inherit;font-size:13px}
.kv .set{padding:4px 0;min-height:28px;border-bottom:1px solid var(--line)}
.kv .set:last-child{border-bottom:0}
.kv .k{color:var(--mute);font-size:13px}
.seg{display:flex;flex:none;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:2px;gap:2px}
.seg button{font:inherit;font-size:13px;color:var(--mute);background:none;border:0;border-radius:6px;padding:3px 10px;cursor:pointer}
.seg button:hover{color:var(--ink)}
.seg button[aria-checked=true]{background:var(--card);color:var(--ink);font-weight:600;box-shadow:0 0 0 1px var(--line)}
.sel{position:relative;flex:none;min-width:0;max-width:60%}
.sel::after{content:"";position:absolute;right:10px;top:50%;width:6px;height:6px;border:solid var(--mute);border-width:0 1.5px 1.5px 0;transform:translateY(-70%) rotate(45deg);pointer-events:none}
.sel select{appearance:none;-webkit-appearance:none;width:100%;font:inherit;font-size:13px;color:var(--ink);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:5px 26px 5px 10px;cursor:pointer;text-overflow:ellipsis}
.sel select:hover{border-color:var(--mute)}
.sel select:focus-visible,.seg button:focus-visible{outline:2px solid var(--review);outline-offset:1px}
.hint{color:var(--mute);font-size:12px;margin:12px 0 0}
</style></head><body><main>
<header><h1>Herdmaster</h1><div class="pop"><button id="cog" type="button" aria-label="Settings" aria-expanded="false" aria-controls="panel" aria-haspopup="dialog" title="Settings"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg></button>
<div id="panel" role="dialog" aria-label="Settings" hidden></div></div></header>
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
const KEYS=["release","grid_panes","worker_layout","max_panes","herdr_workspace"];
const prefs={theme:"auto",done:10,tab:"",follow:true};
try{const s=JSON.parse(localStorage.getItem("hm-prefs")||"{}");
  if(["auto","light","dark"].includes(s.theme))prefs.theme=s.theme;
  if(Number.isInteger(s.done)&&s.done>0)prefs.done=s.done;
  if(typeof s.tab==="string")prefs.tab=s.tab;
  if(typeof s.follow==="boolean")prefs.follow=s.follow}catch(_){}
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
let last="",lastPanel="",tabs=[],fixed=true,cur=null,picked=false,seen;
function sel(opts,val,onchange,label){
  const w=$("span","sel"),s=$("select");s.setAttribute("aria-label",label);
  opts.forEach(([v,l])=>{const o=$("option","",l);o.value=v;o.selected=String(v)===val;s.append(o)});
  s.onchange=()=>onchange(s.value);w.append(s);return w;
}
function seg(opts,val,onchange,label){
  const g=$("div","seg");g.setAttribute("role","radiogroup");g.setAttribute("aria-label",label);
  opts.forEach(([v,l])=>{const b=$("button","",l);b.type="button";b.setAttribute("role","radio");b.setAttribute("aria-checked",v===val);
    b.onclick=()=>{g.querySelectorAll("button").forEach(x=>x.setAttribute("aria-checked",x===b));onchange(v)};g.append(b)});
  return g;
}
function setRow(label,ctl){const r=$("div","set");r.append($("span","k",label),ctl);return r}
function renderPanel(){
  const key=JSON.stringify([ctx.settings,tabs.map(p=>p.name),fixed,ctx.suffix,prefs.follow]);
  if(key===lastPanel)return;lastPanel=key;
  const hd=$("div","hd");hd.append($("div","ttl","Settings"),$("p","sub","Display options are saved in this browser."));
  const rows=[setRow("Theme",seg([["auto","Auto"],["light","Light"],["dark","Dark"]],prefs.theme,v=>setPref("theme",v),"Theme")),
    setRow("Done items shown",sel([5,10,25,50].map(n=>[n,n]),String(prefs.done),v=>{setPref("done",+v);last="";tick()},"Done items shown"))];
  if(!fixed&&tabs.length>1)rows.push(setRow("Follow herdr",seg([[true,"On"],[false,"Off"]],prefs.follow,v=>{setPref("follow",v);seen=undefined;follow()},"Follow herdr")));
  if(!fixed&&tabs.length>1)rows.push(setRow("Opens first",sel([["","Most decisions"],...tabs.map(t=>[t.name,t.name])],prefs.tab,v=>setPref("tab",v),"Opens first")));
  const sh=$("h3","","Project"+(ctx.suffix?" "+ctx.suffix.trim():""));
  const kv=$("div","kv");
  KEYS.forEach(k=>{
    const v=ctx.settings[k],has=v!==undefined&&v!==null;
    kv.append(setRow(k,$("span","v"+(has?"":" none"),has?(typeof v==="object"?JSON.stringify(v):String(v)):"not set")));
  });
  document.getElementById("panel").replaceChildren(hd,$("h3","","This browser"),...rows,sh,kv,$("p","hint","Read-only. Ask the planner to change these."));
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
const cog=document.getElementById("cog"),panel=document.getElementById("panel");
function togglePanel(open){panel.hidden=!open;cog.setAttribute("aria-expanded",open)}
cog.onclick=()=>togglePanel(panel.hidden);
document.addEventListener("click",e=>{if(!panel.hidden&&!e.target.closest(".pop"))togglePanel(false)});
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&!panel.hidden){togglePanel(false);cog.focus()}});
async function follow(){
  if(!prefs.follow||fixed)return;
  try{
    const f=await(await fetch("/focus.json",{cache:"no-store"})).json(),p=f&&f.project||null;
    if(p===seen)return;
    seen=p;
    if(p&&tabs.some(t=>t.name===p)&&p!==cur){cur=p;picked=true;last="";tick()}
  }catch(_){}
}
tick().then(follow);setInterval(tick,3000);setInterval(follow,2000);
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


HERDR_BIN = os.environ.get("HERDR_BIN", "herdr")
_focus = {"at": 0.0, "workspace": None}


def focused_workspace():
    if time.monotonic() - _focus["at"] < 1:
        return _focus["workspace"]
    ws = None
    try:
        out = subprocess.run([HERDR_BIN, "workspace", "list"], capture_output=True, text=True, timeout=2).stdout
        for w in json.loads(out)["result"]["workspaces"]:
            if w.get("focused") and isinstance(w.get("workspace_id"), str):
                ws = w["workspace_id"]
                break
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        pass
    _focus.update(at=time.monotonic(), workspace=ws)
    return ws


def focused_project(root, workspace):
    if not workspace:
        return None
    for p in list_projects(root):
        if project_settings(root, p["name"]).get("herdr_workspace") == workspace:
            return p["name"]
    return None


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
            elif route == "/focus.json":
                ws = focused_workspace()
                self._send(200, json.dumps({"project": focused_project(root, ws), "workspace": ws}), "application/json")
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
