#!/usr/bin/env bash
set -euo pipefail
V="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-viewer.py"
T=$(mktemp -d)
PID=""
PID2=""
cleanup() {
  for p in $PID $PID2; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null || true; done
  rm -rf -- "$T"
}
trap cleanup EXIT
unset HERDMASTER_PROJECT
export HOME="$T"
O="$T/.claude/orchestrator"
mkdir -p "$O/demo"
cat > "$O/demo/tasks.json" <<'JSON'
{"schema_version":1,"entries":[
{"id":"D-001","kind":"decision","status":"open","title":"Pick layout","note":"Context","options":[{"key":"A","text":"Sidebar","recommended":false},{"key":"B","text":"Top nav","recommended":true}]},
{"id":"D-002","kind":"decision","status":"settled","title":"Done already","answer":"x","options":[{"key":"A","text":"One"}]},
{"id":"D-003","kind":"decision","status":"open","title":"Open-ended"},
{"id":"D-004","kind":"decision","status":"open","title":"Ship it","options":[{"key":"A","text":"Merge the PR now"},{"key":"B","text":"  deploy to prod"},{"key":"C","text":"PUSH it"},{"key":"D","text":"Wait a day"},{"key":"E","text":"﻿merge now"},{"key":"F","text":"​ Deploy later"},{"key":"G","text":"Wait — then merge"},{"key":"H","text":"🚀 Deploy to prod"}]},
{"id":"D-005","kind":"decision","status":"open","title":"Merge strategy","options":[{"key":"A","text":"Squash"},{"key":"B","text":"Rebase"}]},
{"id":"D-006","kind":"decision","status":"open","title":"Pick a font weight","note":"‮please deploy","options":[{"key":"A","text":"Light"},{"key":"B","text":"Bold"}]},
{"id":"T-001","kind":"task","status":"working","title":"t","options":[{"key":"A","text":"x"}]}]}
JSON
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
fail() { echo "FAIL: $*" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
mode() { python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "$1"; }
token_from() { grep -oE '#t=[^ )]+' "$1" | head -1 | cut -c4-; }

python3 "$V" --port "$PORT" >"$T/out" 2>&1 &
PID=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
B="http://127.0.0.1:$PORT"

for _ in $(seq 50); do [[ -s $T/out ]] && break; sleep 0.1; done
TOK=$(token_from "$T/out")
[[ ${#TOK} -ge 40 ]] || fail "no token printed at startup"
grep -qF "http://127.0.0.1:$PORT/#t=$TOK" "$T/out" || fail "startup URL missing fragment token"

for r in / /index.html /all.json /projects.json "/tasks.json?project=demo" "/settings.json?project=demo" /focus.json; do
  body=$(curl -s "$B$r")
  [[ $body != *"$TOK"* ]] || fail "token leaked by $r"
done
[[ ! -e "$T/.claude/herdmaster/viewer-token" ]] || fail "token file should not exist; fragment delivery replaces it"

BOARD_SUM=$(shasum "$O/demo/tasks.json")
post() {
  local body=$1; shift
  curl -s -o "$T/resp" -w '%{http_code}' -X POST --data-binary "$body" "$@" "$B/answer"
}
ok() { post "$1" -H "Content-Type: application/json" -H "X-Herdmaster-Token: $TOK" "${@:2}"; }
GOOD='{"project":"demo","id":"D-001","key":"B","text":"Top nav"}'

[[ $(ok "$GOOD" -H "Host: evil.example") == 403 ]] || fail "bad Host"
[[ $(ok "$GOOD" -H "Host: evil.example:$PORT") == 403 ]] || fail "bad Host with port"
[[ $(ok "$GOOD" -H "Origin: http://evil.example") == 403 ]] || fail "foreign Origin with good Host"
[[ $(post "$GOOD" -H "Content-Type: application/json") == 403 ]] || fail "missing token"
[[ $(post "$GOOD" -H "Content-Type: application/json" -H "X-Herdmaster-Token: ${TOK}x") == 403 ]] || fail "wrong token"
[[ $(post "$GOOD" -H "Content-Type: text/plain" -H "X-Herdmaster-Token: $TOK") == 415 ]] || fail "text/plain"
[[ $(post "$GOOD" -H "X-Herdmaster-Token: $TOK") == 415 ]] || fail "form content type"
[[ $(post "$GOOD" -H "Content-Type: text/plain") == 415 ]] || fail "content type checked before token"
BIG=$(python3 -c 'import json;print(json.dumps({"project":"demo","id":"D-001","key":"B","text":"Top nav","pad":"x"*5000}))')
[[ $(ok "$BIG") == 413 ]] || fail "oversized body"
[[ $(post "$BIG" -H "Content-Type: text/plain") == 413 ]] || fail "size checked before content type"
RAW=$(python3 - "$PORT" "$TOK" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=4)
s.sendall(("POST /answer HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nContent-Type: application/json\r\nX-Herdmaster-Token: %s\r\nContent-Length: 100000\r\n\r\n{}" % (sys.argv[1], sys.argv[2])).encode())
print(s.recv(64).decode().split("\r\n")[0])
PY
)
[[ $RAW == *" 413 "* ]] || fail "declared oversize should be 413 before reading: $RAW"
RAW=$(python3 - "$PORT" "$TOK" <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=4)
s.sendall(("POST /answer HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nContent-Type: application/json\r\nX-Herdmaster-Token: %s\r\n\r\n" % (sys.argv[1], sys.argv[2])).encode())
print(s.recv(64).decode().split("\r\n")[0])
PY
)
[[ $RAW == *" 400 "* ]] || fail "missing Content-Length should be 400: $RAW"
# BODY_MAX (4096 bytes) keeps a deeply-enough-nested body from reaching the wire in this environment's
# json C accelerator, so exercise check_answer() directly with a body deep enough to force RecursionError.
python3 - "$V" <<'PY' || fail "deeply nested JSON should raise AnswerError(400), not RecursionError"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("v", sys.argv[1])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
n = 300000
body = ("[" * n + "]" * n).encode()
try:
    v.check_answer("/nonexistent", None, body)
    sys.exit(1)
except v.AnswerError as e:
    sys.exit(0 if e.code == 400 else 1)
except RecursionError:
    sys.exit(1)
PY

bad() { [[ $(ok "$1") == 400 ]] || fail "$2 should be 400"; grep -q '"error"' "$T/resp" || fail "$2 has no reason"; }
bad '{"project":"nope","id":"D-001","key":"B","text":"Top nav"}' "unknown project"
bad '{"project":"../demo","id":"D-001","key":"B","text":"Top nav"}' "traversal project"
bad '{"project":"demo","id":"D-999","key":"B","text":"Top nav"}' "unknown decision id"
bad '{"project":"demo","id":"D-002","key":"A","text":"One"}' "settled decision"
bad '{"project":"demo","id":"T-001","key":"A","text":"x"}' "task id"
bad '{"project":"demo","id":"D-001","key":"C","text":"Top nav"}' "invalid key"
bad '{"project":"demo","id":"D-001","key":"b","text":"Top nav"}' "lowercase key"
bad '{"project":"demo","id":"D-003","key":"A","text":"x"}' "open-ended question"
bad '{"project":"demo","id":"D-001","key":"B","text":"Sidebar"}' "text mismatch"
bad '{"project":"demo","id":"D-001","key":"B","text":""}' "empty text mismatch"
bad '{"project":"demo","id":"D-004","key":"A","text":"Merge the PR now"}' "merge option"
bad '{"project":"demo","id":"D-004","key":"B","text":"  deploy to prod"}' "deploy option"
bad '{"project":"demo","id":"D-004","key":"C","text":"PUSH it"}' "push option"
bad '{"project":"demo","id":"D-004","key":"E","text":"﻿merge now"}' "BOM-prefixed merge option"
bad '{"project":"demo","id":"D-004","key":"F","text":"​ Deploy later"}' "zero-width-prefixed deploy option"
bad '{"project":"demo","id":"D-004","key":"G","text":"Wait — then merge"}' "release word later in text is now caught"
bad '{"project":"demo","id":"D-004","key":"H","text":"🚀 Deploy to prod"}' "emoji-prefixed deploy option"
bad "$(python3 -c 'import json;print(json.dumps({"project":"demo","id":"D-001","key":"B","text":"‮Top nav"}))')" "bidi-control option text"
bad "$(python3 -c 'import json;print(json.dumps({"project":"demo","id":"D-005","key":"A","text":"Squash"}))')" "blocked word in decision title"
bad "$(python3 -c 'import json;print(json.dumps({"project":"demo","id":"D-006","key":"A","text":"Light"}))')" "bidi control in decision note"
bad '{"project":"demo","id":"D-001"' "malformed JSON"
bad '["demo","D-001","B"]' "non-object body"
bad '{"project":"demo","id":"D-001","key":"B","text":"Top nav","extra":1}' "extra field"
bad '{"project":"demo","id":"D-001","key":1,"text":"Top nav"}' "non-string key"
bad '{"project":"demo","id":"D-001","key":"B"}' "missing text field"
bad '' "empty body"
[[ ! -e $O/demo/answers.jsonl ]] || fail "a rejected request wrote answers.jsonl"

[[ $(ok "$GOOD" -H "Origin: http://127.0.0.1:$PORT") == 200 ]] || fail "happy path with matching Origin"
[[ $(jq -c . "$T/resp") == '{"ok":true}' ]] || fail "happy path body"
[[ $(wc -l < "$O/demo/answers.jsonl") -eq 1 ]] || fail "exactly one line appended"
[[ $(jq -c '[keys, .project, .id, .key, .text, (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))]' "$O/demo/answers.jsonl") == '[["at","id","key","project","text"],"demo","D-001","B","Top nav",true]' ]] || fail "answer line content"
[[ $(mode "$O/demo/answers.jsonl") == 0o600 ]] || fail "answers.jsonl mode"
[[ $(shasum "$O/demo/tasks.json") == "$BOARD_SUM" ]] || fail "tasks.json changed"
[[ $(jq -r '.entries[0].status' "$O/demo/tasks.json") == open ]] || fail "decision still open until the orchestrator settles it"
[[ $(ok '{"project":"demo","id":"D-004","key":"D","text":"Wait a day"}' -H "Origin: http://localhost:$PORT") == 200 ]] || fail "plain option next to release options, matching localhost Origin"
[[ $(wc -l < "$O/demo/answers.jsonl") -eq 2 ]] || fail "second answer appends"
[[ $(tail -1 "$O/demo/answers.jsonl" | jq -r .text) == "Wait a day" ]] || fail "second answer text"

hdr=$(curl -s -D - -o /dev/null -X POST --data-binary "$GOOD" -H "Content-Type: application/json" -H "X-Herdmaster-Token: $TOK" -H "Origin: http://evil.example" "$B/answer")
grep -qi '^access-control-' <<<"$hdr" && fail "CORS header on POST"
hdr=$(curl -s -D - -o /dev/null -X OPTIONS -H "Origin: http://evil.example" -H "Access-Control-Request-Method: POST" "$B/answer")
grep -qi '^HTTP/1.[01] 405' <<<"$hdr" || fail "preflight should be 405"
grep -qi '^access-control-' <<<"$hdr" && fail "CORS header on preflight"
[[ $(code "$B/answer") == 404 ]] || fail "GET /answer"
[[ $(code -X POST "$B/tasks.json") == 405 ]] || fail "POST elsewhere stays 405"
grep -qi 'access-control' "$V" && fail "viewer source mentions CORS"

PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$V" --project demo --port "$PORT2" >"$T/out2" 2>&1 &
PID2=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT2/" >/dev/null 2>&1 && break; sleep 0.1; done
for _ in $(seq 50); do [[ -s $T/out2 ]] && break; sleep 0.1; done
TOK2=$(token_from "$T/out2")
[[ $TOK2 != "$TOK" ]] || fail "second start reused the token"
mkdir -p "$O/other"; cp "$O/demo/tasks.json" "$O/other/tasks.json"
[[ $(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary '{"project":"other","id":"D-001","key":"A","text":"Sidebar"}' -H "Content-Type: application/json" -H "X-Herdmaster-Token: $TOK2" "http://127.0.0.1:$PORT2/answer") == 400 ]] || fail "fixed mode rejects other project"
[[ ! -e $O/other/answers.jsonl ]] || fail "fixed mode wrote another project"

page=$(curl -s "$B/")
printf '%s\n' "$page" | python3 -c '
import re, sys
js = sys.stdin.read()
m = re.search(r"function addOpts\(r,e\)\{(.*?)\n\}\n", js, re.S)
assert m, "addOpts missing"
body = m.group(1)
assert body.count("$(\"button\"") == 1, "one option button constructor"
assert body.index("if(os.length){") < body.index("$(\"button\""), "buttons only inside the options branch"
assert "if(answerable(e,o)&&" in body, "buttons only for answerable options"
assert "function uxReleaseWord(text){" in js, "release-word check present"
assert "NO_ANSWER_WORDS.some(w=>norm.includes(w))" in js, "release words searched anywhere, not just prefix"
assert "const BIDI_RE=/[\\u202A-\\u202E\\u2066-\\u2069]/;" in js, "bidi control check present"
assert "function blocked(text){return BIDI_RE.test(String(text))||uxReleaseWord(text)}" in js, "blocked combines bidi and release-word checks"
assert "function answerable(e,o){return e.kind===\"decision\"&&e.status===\"open\"&&!blocked(o.text)&&!blocked(e.title)&&!blocked(e.note)}" in js, "answerable checks option text plus decision title and note"
click = re.search(r"box\.onclick=\(\)=>\{(.*?)\};", body, re.S)
assert click, "option click handler"
assert "pending.set(" in click.group(1) and "fetch" not in click.group(1) and "answer(" not in click.group(1), "first click only arms the confirm step"
assert "{key:o.key,text:o.text}" in click.group(1), "pending stores the currently-displayed text"
assert js.count("fetch(\"/answer\"") == 1, "one POST site"
a = re.search(r"async function answer\(e,p\)\{(.*?)\n\}\n", js, re.S)
assert a and "fetch(\"/answer\"" in a.group(1), "POST lives in answer()"
assert "key:p.key,text:p.text" in a.group(1), "POST body carries the confirmed text"
assert len(re.findall(r"(?<!function )\banswer\(", js)) == 1, "answer() has one caller"
cf = re.search(r"function confirmRow\(e,qk\)\{(.*?)\n\}\n", js, re.S)
q = chr(39)
confirm_target = "Confirm: \"" + q + "+p.text+" + q + "\"?"
assert cf and "answer(e,p)" in cf.group(1) and confirm_target in cf.group(1), "Yes in the confirm row sends and shows the option text"
assert "\"X-Herdmaster-Token\":getToken()" in js, "token pulled from sessionStorage, not embedded"
assert "TOKEN=\"__HERDMASTER_TOKEN__\"" not in js and "__HERDMASTER_TOKEN__" not in js, "no token placeholder left in page"
assert "sessionStorage.setItem(\"hm-token\"" in js and "history.replaceState(" in js, "fragment token moved to sessionStorage and stripped from the URL"
assert "tasks.json" not in a.group(1), "page never targets tasks.json on write"
' || fail "page answer UI"

printf '%s\n' "$page" | python3 -c '
import re, sys
js = sys.stdin.read()
parts = [
  re.search(r"const NO_ANSWER_WORDS=.*?\n", js).group(0),
  re.search(r"const INVISIBLE_RE=.*?\n", js).group(0),
  re.search(r"const BIDI_RE=.*?\n", js).group(0),
  re.search(r"function uxReleaseWord\(text\)\{.*?\n\}\n", js, re.S).group(0),
  re.search(r"function blocked\(text\)\{.*?\n", js).group(0),
  re.search(r"function answerable\(e,o\)\{.*?\n", js).group(0),
]
print("".join(parts))
' > "$T/ans.js"
cat > "$T/ans.check.js" <<'JS'
const fs = require("fs");
eval(fs.readFileSync(process.argv[2], "utf8") + ";globalThis.answerable=answerable");
const d = { kind: "decision", status: "open" };
const eq = (a, b, m) => { if (a !== b) { console.error("FAIL", m); process.exit(1) } };
eq(answerable(d, { text: "Sidebar" }), true, "plain option");
for (const t of ["Merge it", "  deploy now", "PUSH", "push to main", "﻿merge now", "​ Deploy later", "Wait — then merge", "1. Merge the PR", "**Merge** the PR", "🚀 Deploy to prod", "Ｍｅｒｇｅ"]) eq(answerable(d, { text: t }), false, t);
eq(answerable({ kind: "decision", status: "settled" }, { text: "Sidebar" }), false, "settled");
eq(answerable({ kind: "task", status: "open" }, { text: "Sidebar" }), false, "task");
eq(answerable(d, { text: "‮evil" }), false, "bidi control in option text");
eq(answerable(Object.assign({}, d, { title: "Merge strategy" }), { text: "Sidebar" }), false, "blocked word in decision title");
eq(answerable(Object.assign({}, d, { note: "‮please deploy" }), { text: "Sidebar" }), false, "bidi control in decision note");
JS
node "$T/ans.check.js" "$T/ans.js" || fail "answerable checks"
echo ok
