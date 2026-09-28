#!/usr/bin/env python3
"""Localhost viewer for ~/.claude/orchestrator/<project>/tasks.json (see docs/design/board.md).
It never writes tasks.json; its one write is POST /answer, which appends a line to <project>/answers.jsonl.
Usage: herdmaster-viewer.py [--project NAME] [--port N]
Without a project (--project or $HERDMASTER_PROJECT) it shows a tab per ~/.claude/orchestrator/*/tasks.json.
Port defaults to $HERDMASTER_VIEWER_PORT or 8765. Binds 127.0.0.1 only.
$HERDR_BIN (default herdr) is asked which workspace is focused for /focus.json.
Single-threaded stdlib server: fine for one local viewer, swap in ThreadingHTTPServer if several tabs stall it."""
import argparse
import errno
import fcntl
import hmac
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
import unicodedata
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
.note.clamp{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;line-clamp:2;overflow:hidden}
.exp{flex-basis:100%;text-align:left;background:none;border:0;padding:0;font:inherit;font-size:13px;color:var(--review);cursor:pointer}
.exp:hover{text-decoration:underline}
.opts{flex-basis:100%;list-style:none;margin:6px 0 2px;padding:0;display:flex;flex-direction:column;gap:8px}
.opt{display:flex;align-items:flex-start;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px}
.opt .k{flex:none;min-width:1.7em;text-align:center;font:700 13px/1.5 ui-monospace,Menlo,monospace;border-radius:6px;padding:0 6px;color:var(--review);background:color-mix(in srgb,var(--review) 14%,transparent)}
.opt .x{flex:1;min-width:0;font-size:15px;overflow-wrap:anywhere}
button.opt{width:100%;text-align:left;font:inherit;color:inherit;background:none;cursor:pointer}
button.opt:hover{border-color:var(--review)}
.opt.best{border-color:var(--ask);background:color-mix(in srgb,var(--ask) 9%,transparent)}
.opt.best .k{color:var(--bg);background:var(--ask)}
.opt .star{flex:none;align-self:center;font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;color:var(--ask);border:1px solid var(--ask);border-radius:999px;padding:1px 8px}
@media (max-width:560px){.opt{flex-wrap:wrap}.opt .star{order:3;margin-left:calc(1.7em + 22px)}}
.row a,.qb a{color:var(--review);overflow-wrap:anywhere}
.rv{flex-basis:100%;display:flex;flex-direction:column;gap:6px;font-size:14px}
.rvs{overflow-wrap:anywhere}
.rvl{display:flex;flex-wrap:wrap;gap:4px 14px;font-weight:600}
.rvi{display:flex;flex-wrap:wrap;gap:8px}
.rvi a{display:block;line-height:0;border:1px solid var(--line);border-radius:6px;overflow:hidden}
.rvi img{width:96px;height:64px;object-fit:cover;object-position:top;background:var(--bg)}
.rvm{color:var(--mute);font-size:13px;overflow-wrap:anywhere}
.rvm b{font-weight:600}
.wait{flex-basis:100%;font-size:13px;color:var(--ask)}
.wait b{font:600 12.5px ui-monospace,Menlo,monospace}
.tk{background:var(--card);border:1px solid var(--line);border-radius:8px;margin-bottom:8px;overflow:hidden}
.tk>button{display:flex;align-items:center;gap:10px;width:100%;text-align:left;background:none;border:0;padding:11px 14px;font:inherit;color:var(--ink);cursor:pointer}
.tk>button:hover{background:color-mix(in srgb,var(--line) 45%,transparent)}
.chev{flex:none;width:7px;height:7px;margin:0 6px 0 3px;border:solid var(--mute);border-width:0 1.6px 1.6px 0;transform:rotate(-45deg);transition:transform .15s}
[aria-expanded=true]>.chev{transform:rotate(45deg)}
.tk .nm{flex:1;min-width:0;font-weight:600;overflow-wrap:anywhere}
.tk .cnt{flex:none;font-size:12.5px;font-weight:600;color:var(--ready)}
.tk.open .cnt{color:var(--ask)}
.q{border-top:1px solid var(--line)}
.q>button{display:flex;align-items:flex-start;gap:10px;width:100%;text-align:left;background:none;border:0;padding:9px 14px;font:inherit;color:var(--ink);cursor:pointer}
.q>button:hover{background:color-mix(in srgb,var(--line) 45%,transparent)}
.q .chev{margin-top:.45em}
.q .qt{flex:1;min-width:0}
.q .qt>span{display:block;overflow-wrap:anywhere}
.q .sum{font-size:14px;color:var(--ask);margin-top:2px}
.q.done .sum{color:var(--ready)}
.qb{display:flex;flex-wrap:wrap;gap:6px;padding:0 14px 12px 14px}
.qb .opts{margin:2px 0}
.cf{flex-basis:100%;display:flex;flex-wrap:wrap;align-items:center;gap:8px;font-size:14px}
.cf button{font:inherit;font-size:13px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--ink);padding:3px 12px;cursor:pointer}
.cf button.yes{border-color:var(--review);color:var(--review);font-weight:600}
.cf .err{color:var(--fail)}
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
(function(){
  const m=/(?:^|[#&])t=([^&]*)/.exec(location.hash);
  if(m){try{sessionStorage.setItem("hm-token",decodeURIComponent(m[1]))}catch(_){}
    history.replaceState(null,"",location.pathname+location.search);}
})();
function getToken(){try{return sessionStorage.getItem("hm-token")||""}catch(_){return ""}}
const $=(t,c,x)=>{const e=document.createElement(t);if(c)e.className=c;if(x!=null)e.textContent=x;return e};
const STATUS={"in review":["review","In review"],"finished":["review","In review"],"working":["working","Working"],"blocked":["working","Working"],"approved":["working","Working"],"paused":["working","Paused"],"deploy-ready":["ready",null],"failed":["failed","Failed"]};
const ORDER=["review","failed","working","ready"];
const short=id=>(id||"").replace(/-0*/,"");
const dispId=e=>e.kind==="decision"?(e.id||""):short(e.id);
const openNotes=new Set();
let clampChecks=[];
function fitNotes(){
  clampChecks=clampChecks.filter(([n,b])=>{
    if(!n.isConnected)return false;
    if(!n.clientHeight)return true;
    if(n.scrollHeight>n.clientHeight)b.hidden=false;else{n.classList.remove("clamp");b.remove()}
    return false;
  });
}
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
let waiting=new Map();
const URL_RE=/https?:\/\/[^\s<>"'`]+/g;
function safeUrl(u){
  if(typeof u!=="string")return null;
  try{const x=new URL(u);return x.protocol==="http:"||x.protocol==="https:"?x.href:null}catch(_){return null}
}
function linkParts(text){
  const out=[];let at=0;text=String(text);
  for(const m of text.matchAll(URL_RE)){
    let u=m[0];
    while(/[.,;:!?)\]}]$/.test(u)&&!(u.endsWith(")")&&u.includes("(")))u=u.slice(0,-1);
    const href=safeUrl(u);
    if(!href)continue;
    if(m.index>at)out.push({t:text.slice(at,m.index)});
    out.push({t:u,href});at=m.index+u.length;
  }
  if(at<text.length)out.push({t:text.slice(at)});
  return out;
}
function anchor(href,label){
  const a=$("a","",label);a.href=href;a.target="_blank";a.rel="noopener noreferrer";return a;
}
function linkify(el,text){
  linkParts(text).forEach(p=>el.append(p.href?anchor(p.href,p.t):document.createTextNode(p.t)));
  return el;
}
const fileUrl=p=>"/file?path="+encodeURIComponent(p);
const IMG_RE=/\.(png|jpe?g|gif|webp)$/i;
function reviewBlock(pack){
  if(!pack||typeof pack!=="object"||Array.isArray(pack))return null;
  const d=$("div","rv");
  if(typeof pack.summary==="string"&&pack.summary)d.append(linkify($("div","rvs"),pack.summary));
  const ls=$("div","rvl"),pv=safeUrl(pack.preview_url);
  if(pv)ls.append(anchor(pv,"Preview"));
  (Array.isArray(pack.links)?pack.links:[]).forEach(l=>{
    const h=l&&safeUrl(l.url);if(h)ls.append(anchor(h,typeof l.label==="string"&&l.label?l.label:h))});
  if(ls.childNodes.length)d.append(ls);
  const shots=(Array.isArray(pack.screenshots)?pack.screenshots:[]).filter(p=>typeof p==="string"&&p.startsWith("/")&&IMG_RE.test(p));
  if(shots.length){
    const g=$("div","rvi");
    shots.forEach((p,i)=>{const a=anchor(fileUrl(p),"");a.title="Screenshot "+(i+1);
      const im=$("img");im.src=fileUrl(p);im.alt="Screenshot "+(i+1);im.loading="lazy";a.append(im);g.append(a)});
    d.append(g);
  }
  const meta=[["Diff",pack.diff],["Tests",pack.tests]].filter(([,v])=>typeof v==="string"&&v);
  if(meta.length){const m=$("div","rvm");meta.forEach(([k,v])=>{const x=$("div");x.append($("b","",k+": "),v);m.append(x)});d.append(m)}
  return d.childNodes.length?d:null;
}
function addNote(r,e){
  const n=linkify($("div","note"),e.note);r.append(n);
  const open=openNotes.has(e.id);if(!open)n.classList.add("clamp");
  const b=$("button","exp",open?"Show less":"Show more");b.type="button";b.setAttribute("aria-expanded",open);b.hidden=!open;
  b.onclick=()=>{if(openNotes.has(e.id))openNotes.delete(e.id);else openNotes.add(e.id);last="";paint()};r.append(b);
  if(!open)clampChecks.push([n,b]);
}
function optsOf(e){return Array.isArray(e.options)?e.options.filter(o=>o&&typeof o.key==="string"&&typeof o.text==="string"):[]}
const NO_ANSWER_WORDS=["merge","deploy","push"];
const INVISIBLE_RE=/[\s\p{Cc}\p{Cf}\p{Mn}ㅤﾠ⠀]/gu;
const BIDI_RE=/[\u202A-\u202E\u2066-\u2069]/;
function uxReleaseWord(text){
  // Speed bump only, no security value: see roles/orchestrator.md and docs/design/board.md, which say
  // answers.jsonl never by itself authorizes merge/deploy/push -- this cannot catch paraphrases or
  // look-alikes. Keep this word list and the NFKC+casefold+strip-then-search-anywhere approach in sync
  // with herdmaster-board.sh's jq settle check. Bidirectional control characters are checked separately,
  // on the UNSTRIPPED text, and rejected outright rather than stripped and allowed through (see blocked()).
  const norm=String(text).normalize("NFKC").replace(INVISIBLE_RE,"").toLowerCase();
  return NO_ANSWER_WORDS.some(w=>norm.includes(w));
}
function blocked(text){return BIDI_RE.test(String(text))||uxReleaseWord(text)}
const pending=new Map(),sent=new Map(),failedAns=new Map();
function answerable(e,o){return e.kind==="decision"&&e.status==="open"&&!blocked(o.text)&&!blocked(e.title)&&!blocked(e.note)}
async function answer(e,p){
  const qk=cur+"\n"+e.id;
  let err="Could not send the answer.";
  try{
    const r=await fetch("/answer",{method:"POST",cache:"no-store",headers:{"Content-Type":"application/json","X-Herdmaster-Token":getToken()},body:JSON.stringify({project:cur,id:e.id,key:p.key,text:p.text})});
    if(r.ok){sent.set(qk,p.key);failedAns.delete(qk);err=""}else{try{err=(await r.json()).error||err}catch(_){}}
  }catch(_){}
  pending.delete(qk);if(err)failedAns.set(qk,err);last="";paint();
}
function confirmRow(e,qk){
  const c=$("div","cf"),p=pending.get(qk);
  if(p){
    const y=$("button","yes","Yes"),n=$("button","","Cancel");y.type=n.type="button";
    y.onclick=()=>{y.disabled=true;answer(e,p)};n.onclick=()=>{pending.delete(qk);last="";paint()};
    c.append($("span","",'Confirm: "'+p.text+'"?'),y,n);
  }else if(sent.has(qk))c.append($("span","","Sent "+sent.get(qk)+". The orchestrator will settle it."));
  else if(failedAns.has(qk))c.append($("span","err",failedAns.get(qk)));
  return c.childNodes.length?c:null;
}
function addOpts(r,e){
  const os=optsOf(e),qk=cur+"\n"+e.id;
  if(os.length){
    const ul=$("ul","opts");
    os.forEach(o=>{const cls="opt"+(o.recommended===true?" best":"");
      let li,box;
      if(answerable(e,o)&&!sent.has(qk)){li=$("li");box=$("button",cls);box.type="button";box.title="Answer "+o.key;
        box.onclick=()=>{pending.set(qk,{key:o.key,text:o.text});failedAns.delete(qk);last="";paint()};li.append(box)}
      else li=box=$("li",cls);
      box.append($("span","k",o.key),$("span","x",o.text));
      if(o.recommended===true)box.append($("span","star","Recommended"));ul.append(li)});
    r.append(ul);
    const c=e.status==="open"&&confirmRow(e,qk);if(c)r.append(c);
  }
  if(e.recommend)r.append($("div","rec",(os.length?"Why: ":"Recommended: ")+e.recommend));
}
function row(e,cls,label,past){
  const r=$("div","row "+cls+(past?" past":""));r.append($("span","tag",dispId(e)),$("span","t",e.title||"(untitled)"));
  if((e.flags||[]).length)r.append($("span","warn","a question changed"));
  if(label)r.append($("span","pill",label));
  if(e.status==="in review"&&!past){const rv=reviewBlock(e.review_pack);if(rv)r.append(rv)}
  const w=waiting.get(e.id);
  if(w){const x=$("div","wait","waiting on ");w.forEach((id,i)=>{if(i)x.append(", ");x.append($("b","",id))});r.append(x)}
  if(e.note)addNote(r,e);
  addOpts(r,e);
  return r;
}
const openTk=new Map(),openQ=new Set();
const OTHER="Other";
function ticketOf(e){return typeof e.group==="string"&&e.group.trim()?e.group.trim():OTHER}
function summary(e){
  if(e.status==="settled")return[typeof e.answer==="string"&&e.answer?"Answer: "+e.answer:"Settled",true];
  const r=optsOf(e).find(o=>o.recommended===true);
  if(r)return["Recommended: "+r.key+" \u00b7 "+r.text,false];
  return[e.recommend?"Recommended: "+e.recommend:"",false];
}
function chev(){return $("span","chev")}
function question(e){
  const key=cur+"\n"+e.id,open=openQ.has(key),[sum,done]=summary(e);
  const q=$("div","q"+(done?" done":"")),b=$("button");b.type="button";b.setAttribute("aria-expanded",open);
  const t=$("span","qt");t.append($("span","",e.title||"(untitled)"));if(sum&&!(open&&!done))t.append($("span","sum",sum));
  b.append(chev(),$("span","tag",dispId(e)),t);
  b.onclick=()=>{if(openQ.has(key))openQ.delete(key);else openQ.add(key);last="";paint()};
  q.append(b);
  if(open){const body=$("div","qb");if(e.note)addNote(body,e);addOpts(body,e);q.append(body)}
  return q;
}
function tickets(ds){
  const g=new Map();
  ds.forEach(e=>{const k=ticketOf(e);if(!g.has(k))g.set(k,[]);g.get(k).push(e)});
  const all=[...g].map(([name,qs],i)=>({name,qs,i,left:qs.filter(e=>e.status==="open").length}));
  all.sort((a,b)=>(a.name===OTHER)-(b.name===OTHER)||(b.left>0)-(a.left>0)||a.i-b.i);
  return all.map(t=>{
    const key=cur+"\n"+t.name,open=openTk.has(key)?openTk.get(key):t.left>0;
    const d=$("div","tk"+(t.left>0?" open":"")),b=$("button");b.type="button";b.setAttribute("aria-expanded",open);
    const cnt=t.left===0?"Ready to hand off ("+t.qs.length+" of "+t.qs.length+")":(t.qs.length-t.left)+" of "+t.qs.length+" answered";
    const m=t.qs[0]&&/^([A-Za-z]+)\d+$/.exec(t.qs[0].id),letter=m?m[1]:"";
    b.append(chev());if(letter)b.append($("span","tag",letter));b.append($("span","nm",t.name),$("span","cnt",cnt));
    b.onclick=()=>{openTk.set(key,!open);last="";paint()};
    d.append(b);if(open)t.qs.forEach(e=>d.append(question(e)));
    return d;
  });
}
function section(title,rows,none){
  const s=$("section"),h=$("h2","",title);h.append($("span","n",rows.length));s.append(h);
  if(!rows.length)s.append($("div","empty",none));
  rows.forEach(r=>s.append(r));return s;
}
function render(b){
  clampChecks=[];
  const es=Array.isArray(b.entries)?b.entries:[];
  const ds=es.filter(e=>e.kind==="decision"&&(e.status==="open"||e.status==="settled"));
  const openIds=new Set(ds.filter(e=>e.status==="open").map(e=>e.id));
  waiting=new Map();
  es.forEach(e=>{if(e.kind!=="decision"&&Array.isArray(e.depends_on)){const w=e.depends_on.filter(id=>openIds.has(id));if(w.length)waiting.set(e.id,w)}});
  const tasks=es.filter(e=>e.kind!=="decision"&&e.status!=="done"&&e.status!=="cancelled").map(e=>{const [c,l]=STATUS[e.status]||["working","Working"];return [c,l||"Ready to "+ctx.word,e]});
  tasks.sort((x,y)=>ORDER.indexOf(x[0])-ORDER.indexOf(y[0]));
  document.getElementById("board").replaceChildren(section("Tickets",tickets(ds),"Nothing needs you."),section("Tasks",tasks.map(([c,l,e])=>row(e,c,l)),"No tasks yet."));
  fitNotes();
  const past=es.filter(e=>e.kind!=="decision"&&(e.status==="done"||e.status==="cancelled"));
  const pe=document.getElementById("past");
  if(!past.length){pe.replaceChildren();return}
  past.sort((x,y)=>String(y.updated||"").localeCompare(String(x.updated||"")));
  const d=$("details"),s=$("summary","","Done");s.append(" ",$("span","n",past.length));d.append(s);d.open=pastOpen;
  d.ontoggle=()=>{pastOpen=d.open;fitNotes()};
  past.slice(0,showAll?past.length:prefs.done).forEach(e=>d.append(row(e,"working",e.status==="cancelled"?"cancelled":"done",true)));
  if(past.length>prefs.done){const m=$("button","more",showAll?"show fewer":"show all "+past.length);m.type="button";m.onclick=()=>{showAll=!showAll;last="";paint()};d.append(m)}
  pe.replaceChildren(d);fitNotes();
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
    setRow("Done items shown",sel([5,10,25,50].map(n=>[n,n]),String(prefs.done),v=>{setPref("done",+v);last="";paint()},"Done items shown"))];
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
    if(p.needed>0){b.append($("span","badge",p.needed));b.title=p.needed+" open question"+(p.needed>1?"s":"")}
    b.onclick=()=>select(p.name);return b;
  }));
}
let cache=null,cacheTxt="",errs={},failed=false,loading=new Set();
function paint(){
  if(!cache)return;
  const note=document.getElementById("note");
  fixed=cache.fixed;tabs=cache.projects;
  if(!tabs.some(p=>p.name===cur))picked=false;
  if(!picked)cur=tabs.find(p=>p.name===prefs.tab)?.name||tabs.reduce((m,p)=>!m||p.needed>m.needed?p:m,null)?.name||null;
  ctx.suffix=!fixed&&tabs.length>1?" ("+cur+")":"";
  renderTabs();
  if(cur===null&&!fixed){note.textContent="No boards yet.";document.getElementById("board").replaceChildren();document.getElementById("past").replaceChildren();return}
  const st=cache.settings[cur];
  ctx.settings=st&&typeof st==="object"&&!Array.isArray(st)?st:{};
  ctx.word=["merge","deploy","push","ship"].includes(ctx.settings.release)?ctx.settings.release:"deploy";
  renderPanel();
  const b=cache.boards[cur];
  if(b===undefined||(b===null&&errs[cur]===undefined)){loadProject(cur);if(b===undefined)return}
  if(b===null){note.textContent=errs[cur]||"Board unavailable";return}
  note.textContent="";
  const key=cur+"\n"+ctx.word+"\n"+ctx.suffix+"\n"+prefs.done+"\n"+showAll+"\n"+JSON.stringify(b);
  if(key!==last){last=key;render(b)}
}
async function loadProject(name){
  if(loading.has(name))return;
  loading.add(name);
  const q=fixed?"":"?project="+encodeURIComponent(name),c=cache;
  try{
    const [r,sr]=await Promise.all([fetch("/tasks.json"+q,{cache:"no-store"}),fetch("/settings.json"+q,{cache:"no-store"})]);
    const txt=await r.text();let b=null;
    if(r.ok){try{b=JSON.parse(txt);delete errs[name]}catch(_){errs[name]="Board file is not valid JSON. Showing the last good view."}}
    else{let m="Board unavailable";try{m=JSON.parse(txt).error||m}catch(_){}errs[name]=m}
    let st={};try{st=await sr.json()}catch(_){}
    if(cache===c){cache.boards[name]=b;cache.settings[name]=st;if(cur===name)paint()}
  }catch(_){}
  finally{loading.delete(name)}
}
async function poll(){
  try{
    const txt=await(await fetch("/all.json",{cache:"no-store"})).text();
    const was=failed;failed=false;
    if(txt===cacheTxt&&!was)return;
    cache=JSON.parse(txt);cacheTxt=txt;errs={};
    paint();
  }catch(_){failed=true;document.getElementById("note").textContent="Viewer server unreachable. Retrying."}
}
function select(name){cur=name;picked=true;last="";paint();poll()}
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
    if(p&&!tabs.some(t=>t.name===p))await poll();
    if(p&&tabs.some(t=>t.name===p)&&p!==cur)select(p)
  }catch(_){}
}
poll().then(follow);setInterval(poll,3000);setInterval(follow,500);
</script></body></html>
"""


PAGE_CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'; "
            "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
BODY_MAX = 4096
NO_ANSWER_WORDS = ("merge", "deploy", "push")
INVISIBLE_CATS = {"Zs", "Zl", "Zp", "Cc", "Cf", "Mn"}
INVISIBLE_CHARS = {"ㅤ", "ﾠ", "⠀"}
BIDI_CONTROLS = set("\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069")


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


def read_board(root, project):
    try:
        doc = read_json(os.path.join(root, project, "tasks.json"))
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def all_boards(fixed, root):
    if fixed:
        projects = [{"name": fixed, "needed": open_decisions(os.path.join(root, fixed, "tasks.json"))}]
    else:
        projects = list_projects(root)
    names = [p["name"] for p in projects]
    return {"fixed": bool(fixed), "projects": projects,
            "boards": {n: read_board(root, n) for n in names},
            "settings": {n: project_settings(root, n) for n in names}}


TMP_ROOT = "/private/tmp/claude-501"
ORCH_ROOT = "~/.claude/orchestrator"
FILE_MAX = 10 * 1024 * 1024
FILE_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
              "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8", "log": "text/plain; charset=utf-8",
              "diff": "text/plain; charset=utf-8", "patch": "text/plain; charset=utf-8"}
IMAGE_EXTS = {"png", "jpg", "jpeg", "gif", "webp"}
FILE_DENY = {"secrets"}


class FileError(Exception):
    def __init__(self, code, msg):
        self.code, self.msg = code, msg


def fold(name):
    return unicodedata.normalize("NFKC", name).casefold()


def check_real(real):
    """Raises FileError unless a resolved path is under an allowed root and passes the deny rules."""
    tmp = os.path.realpath(TMP_ROOT)
    orch = os.path.realpath(os.path.expanduser(ORCH_ROOT))
    if real.startswith(tmp + os.sep):
        parts = real[len(tmp) + 1:].split(os.sep)
    elif real.startswith(orch + os.sep):
        parts = real[len(orch) + 1:].split(os.sep)
        if len(parts) < 3 or not NAME_RE.fullmatch(parts[0]) or parts[1] != "review":
            raise FileError(403, "Outside the allowed folders")
    else:
        raise FileError(403, "Outside the allowed folders")
    if any(x.startswith(".") or fold(x) in FILE_DENY for x in parts):
        raise FileError(403, "Hidden or protected path")


def open_review_file(raw):
    """Validates a requested path and returns (fd, ext, size); raises FileError. Callers must close the fd.
    Ceiling: realpath and open are two steps; on macOS the fd's own path is re-checked after open (F_GETPATH), elsewhere a directory swapped for a symlink in between could escape. Roots are owner-writable only."""
    if not raw or len(raw) > 4096:
        raise FileError(400, "Missing or too long path")
    if "\0" in raw:
        raise FileError(400, "Invalid path")
    if not raw.startswith("/"):
        raise FileError(400, "Path must be absolute")
    if ".." in raw or os.path.normpath(raw) != raw:
        raise FileError(400, "Path must be normalised without '..'")
    real = os.path.realpath(raw)
    check_real(real)
    ext = os.path.splitext(real)[1][1:].lower()
    if ext not in FILE_TYPES:
        raise FileError(415, "File type not allowed")
    try:
        fd = os.open(real, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise FileError(404, "Not found")
    except OSError:
        raise FileError(403, "Cannot open")
    try:
        if hasattr(fcntl, "F_GETPATH"):
            try:
                opened = fcntl.fcntl(fd, fcntl.F_GETPATH, b"\0" * 1024).split(b"\0", 1)[0].decode()
            except (OSError, UnicodeDecodeError):
                opened = None
            if opened:
                check_real(os.path.realpath(opened))
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise FileError(400, "Not a regular file")
        if st.st_size > FILE_MAX:
            raise FileError(413, "File too large")
    except BaseException:
        os.close(fd)
        raise
    return fd, ext, st.st_size


HERDR_BIN = os.environ.get("HERDR_BIN", "herdr")
_focus = {"at": float("-inf"),"workspace": None}


def focused_workspace():
    if time.monotonic() - _focus["at"] < 0.25:
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


def host_allowed(handler):
    """DNS-rebinding guard: accept only the loopback names on the port this server is bound to."""
    port = handler.server.server_address[1]
    return handler.headers.get("Host") in ("127.0.0.1:%d" % port, "localhost:%d" % port, "[::1]:%d" % port)


def origin_allowed(handler):
    """Defense in depth alongside Host: a present Origin must be this server's own loopback origin."""
    origin = handler.headers.get("Origin")
    if origin is None:
        return True
    port = handler.server.server_address[1]
    return origin in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)


class AnswerError(Exception):
    def __init__(self, code, msg):
        self.code, self.msg = code, msg


def ux_release_word(text):
    """Speed bump only, no security value whatsoever: an answers.jsonl line never by itself authorizes
    merge, deploy or push (see roles/orchestrator.md, docs/design/board.md) -- this cannot catch
    paraphrases or convincing look-alikes. NFKC-normalizes, casefolds, strips common invisible/filler
    characters, then looks for the banned words anywhere in what remains. Keep this word list and approach
    in sync with the page's JS uxReleaseWord and herdmaster-board.sh's jq settle check."""
    norm = unicodedata.normalize("NFKC", text)
    stripped = "".join(ch for ch in norm if unicodedata.category(ch) not in INVISIBLE_CATS and ch not in INVISIBLE_CHARS)
    folded = stripped.casefold()
    return any(w in folded for w in NO_ANSWER_WORDS)


def has_bidi_control(text):
    """Bidirectional control characters are checked on the text AS GIVEN, never stripped away first --
    they are rejected outright, not stripped and allowed through, since they are exactly what would let a
    look-alike answer render safely while meaning something else. Same rationale as ux_release_word: no
    security value, just a speed bump; see blocked()."""
    return any(ch in BIDI_CONTROLS for ch in text)


def blocked(text):
    return has_bidi_control(text) or ux_release_word(text)


def check_answer(root, fixed, body):
    """Returns the validated {"project","id","key","text"} or raises AnswerError(400)."""
    try:
        doc = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise AnswerError(400, "Body is not valid JSON")
    if not isinstance(doc, dict) or set(doc) != {"project", "id", "key", "text"} or not all(isinstance(v, str) for v in doc.values()):
        raise AnswerError(400, "Body must be {project, id, key, text} strings")
    project, did, key, text = doc["project"], doc["id"], doc["key"], doc["text"]
    if not NAME_RE.fullmatch(project) or ".." in project or (fixed and project != fixed):
        raise AnswerError(400, "Invalid project name")
    board = read_board(root, project)
    if board is None:
        raise AnswerError(400, "Unknown project")
    entries = board.get("entries")
    # Assumes ids are unique (they come from a max+1 counter); the first match wins, as elsewhere in this file.
    entry = next((e for e in entries if isinstance(e, dict) and e.get("id") == did), None) if isinstance(entries, list) else None
    if entry is None:
        raise AnswerError(400, "Unknown decision")
    if entry.get("kind") != "decision" or entry.get("status") != "open":
        raise AnswerError(400, "Not an open decision")
    title = entry.get("title") if isinstance(entry.get("title"), str) else ""
    note = entry.get("note") if isinstance(entry.get("note"), str) else ""
    if blocked(title) or blocked(note):
        raise AnswerError(400, "This decision's title or note contains merge, deploy, push or a directional control character; answer in chat, not from the page")
    opts = entry.get("options") if isinstance(entry.get("options"), list) else []
    opt = next((o for o in opts if isinstance(o, dict) and o.get("key") == key and isinstance(o.get("text"), str)), None)
    if opt is None:
        raise AnswerError(400, "Unknown option key")
    if opt["text"] != text:
        raise AnswerError(400, "Option text has changed since you loaded the page; refresh and try again")
    if blocked(opt["text"]):
        raise AnswerError(400, "Merge, deploy, push or a directional control character are answered in chat, not from the page")
    return {"project": project, "id": did, "key": key, "text": opt["text"]}


def append_answer(root, ans):
    line = json.dumps(dict(ans, at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())), separators=(",", ":")) + "\n"
    d = os.path.join(root, ans["project"])
    os.makedirs(d, exist_ok=True)
    fd = os.open(os.path.join(d, "answers.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        data = line.encode()
        written = 0
        while written < len(data):
            n = os.write(fd, data[written:])
            if n <= 0:
                raise OSError("short write to answers.jsonl")
            written += n
    finally:
        os.close(fd)


def make_handler(fixed, root, token):
    class Handler(BaseHTTPRequestHandler):
        timeout = 5

        def _send(self, code, body, ctype, headers=()):
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def _json_error(self, code, msg):
            self._send(code, json.dumps({"error": msg}), "application/json")

        def _file(self, q):
            if self.headers.get("Sec-Fetch-Site", "same-origin") not in ("same-origin", "none"):
                return self._json_error(403, "Cross-site request")
            vals = q.get("path") or []
            try:
                if len(vals) != 1:
                    raise FileError(400, "Exactly one path is required")
                fd, ext, size = open_review_file(vals[0])
            except FileError as e:
                return self._json_error(e.code, e.msg)
            with os.fdopen(fd, "rb") as f:
                data = f.read(FILE_MAX + 1)
            if len(data) > FILE_MAX:
                return self._json_error(413, "File too large")
            self.send_response(200)
            self.send_header("Content-Type", FILE_TYPES[ext])
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'; sandbox")
            self.send_header("Content-Disposition", "inline" if ext in IMAGE_EXTS else "attachment")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _project(self, query):
            if fixed:
                return fixed
            name = (parse_qs(query).get("project") or [""])[0]
            if not NAME_RE.fullmatch(name) or ".." in name:
                self._json_error(400, "Invalid project name")
                return None
            return name

        def do_GET(self):
            if not host_allowed(self):
                return self._forbidden()
            u = urlsplit(self.path)
            route = u.path
            if route in ("/", "/index.html"):
                self._send(200, PAGE, "text/html; charset=utf-8", (("Content-Security-Policy", PAGE_CSP),))
            elif route == "/project" and fixed:
                self._send(200, fixed, "text/plain; charset=utf-8")
            elif route == "/projects.json":
                if fixed:
                    projects = [{"name": fixed, "needed": open_decisions(os.path.join(root, fixed, "tasks.json"))}]
                else:
                    projects = list_projects(root)
                self._send(200, json.dumps({"fixed": bool(fixed), "projects": projects}), "application/json")
            elif route == "/all.json":
                self._send(200, json.dumps(all_boards(fixed, root)), "application/json")
            elif route == "/focus.json":
                ws = focused_workspace()
                self._send(200, json.dumps({"project": focused_project(root, ws), "workspace": ws}), "application/json")
            elif route == "/file":
                self._file(parse_qs(u.query, keep_blank_values=True))
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

        do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _deny

        def _forbidden(self):
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            if not host_allowed(self):
                return self._forbidden()
            if urlsplit(self.path).path != "/answer":
                return self._deny()
            if not origin_allowed(self):
                return self._forbidden()
            try:
                lengths = self.headers.get_all("Content-Length") or []
                length = int(lengths[0]) if len(lengths) == 1 else -1
            except ValueError:
                return self._json_error(400, "Content-Length required")
            if length < 0:
                return self._json_error(400, "Content-Length required")
            if length > BODY_MAX:
                return self._json_error(413, "Body too large")
            if (self.headers.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json":
                return self._json_error(415, "Content-Type must be application/json")
            given = self.headers.get("X-Herdmaster-Token") or ""
            if not hmac.compare_digest(given.encode("utf-8", "surrogateescape"), token.encode()):
                return self._forbidden()
            body = self.rfile.read(min(length, BODY_MAX + 1))
            if len(body) > BODY_MAX:
                return self._json_error(413, "Body too large")
            if len(body) != length:
                return self._json_error(400, "Body shorter than Content-Length")
            try:
                ans = check_answer(root, fixed, body)
                append_answer(root, ans)
            except AnswerError as e:
                return self._json_error(e.code, e.msg)
            except OSError as e:
                return self._json_error(500, "Cannot record answer: %s" % e.strerror)
            self._send(200, json.dumps({"ok": True}), "application/json")

        def do_HEAD(self):
            self._deny()

        def log_message(self, *a):
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser(description="Board viewer on 127.0.0.1")
    ap.add_argument("--project", default=os.environ.get("HERDMASTER_PROJECT"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("HERDMASTER_VIEWER_PORT", "8765")))
    a = ap.parse_args()
    if a.project and (not NAME_RE.fullmatch(a.project) or ".." in a.project):
        sys.exit("herdmaster-viewer: invalid project name '%s'" % a.project)
    root = os.path.expanduser("~/.claude/orchestrator")
    token = secrets.token_urlsafe(32)
    try:
        srv = HTTPServer(("127.0.0.1", a.port), make_handler(a.project, root, token))
    except OSError as e:
        if e.errno != errno.EADDRINUSE:
            raise
        sys.exit("herdmaster-viewer: port %d is already in use; pass --port N to pick another" % a.port)
    print("herdmaster viewer: http://127.0.0.1:%d/#t=%s (%s, one-time link -- the token moves to this "
          "browser tab's sessionStorage on load and disappears from the visible URL)" %
          (srv.server_address[1], token, "project " + a.project if a.project else "all projects"), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
