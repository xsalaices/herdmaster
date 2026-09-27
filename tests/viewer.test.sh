#!/usr/bin/env bash
set -euo pipefail
V="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-viewer.py"
T=$(mktemp -d)
PID=""
PID2=""
trap '[[ -n $PID ]] && kill "$PID" 2>/dev/null; [[ -n $PID2 ]] && kill "$PID2" 2>/dev/null; rm -rf -- "$T"' EXIT
unset HERDMASTER_PROJECT
export HOME="$T"
mkdir -p "$T/.claude/orchestrator/demo"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
fail() { echo "FAIL: $*" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

python3 "$V" --project demo --port "$PORT" >"$T/out" 2>&1 &
PID=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done

[[ $(code "http://127.0.0.1:$PORT/tasks.json") == 404 ]] || fail "missing board should be 404"
echo '{bad' > "$T/.claude/orchestrator/demo/tasks.json"
[[ $(code "http://127.0.0.1:$PORT/tasks.json") == 422 ]] || fail "invalid board should be 422"
echo '{"schema_version":1,"entries":[{"id":"T-001","kind":"task","title":"x","status":"in review"}]}' > "$T/.claude/orchestrator/demo/tasks.json"
page=$(curl -s "http://127.0.0.1:$PORT/")
grep -q 'Herdmaster board' <<<"$page" || fail "page"
[[ $(curl -s "http://127.0.0.1:$PORT/tasks.json" | jq -r '.entries[0].id') == T-001 ]] || fail "json"
[[ $(code -X POST "http://127.0.0.1:$PORT/tasks.json") == 405 ]] || fail "POST should be 405"
[[ $(code -X DELETE "http://127.0.0.1:$PORT/") == 405 ]] || fail "DELETE should be 405"
hget() { curl -s -H "Host: $1" -w '|%{http_code}' "$2"; }
for h in "127.0.0.1:$PORT" "localhost:$PORT"; do
  for r in / /tasks.json /projects.json; do
    [[ $(code -H "Host: $h" "http://127.0.0.1:$PORT$r") == 200 ]] || fail "Host $h $r should be 200"
  done
done
RAW=$(python3 -c 'import socket,sys;s=socket.create_connection(("127.0.0.1",int(sys.argv[1])));s.sendall(b"GET /tasks.json HTTP/1.0\r\n\r\n");d=b""
while True:
    c=s.recv(4096)
    if not c: break
    d+=c
print(d.decode().replace("\r\n","|"))' "$PORT")
[[ $RAW == 'HTTP/1.0 403 Forbidden|Server:'*'|Content-Length: 0||' ]] || fail "missing Host should be 403 empty: $RAW"
for h in evil.example 127.0.0.1 127.0.0.1:1 "evil.example:$PORT" ""; do
  for r in / /tasks.json /projects.json; do
    out=$(hget "$h" "http://127.0.0.1:$PORT$r")
    [[ $out == '|403' ]] || fail "Host '$h' $r should be 403 with empty body, got: $out"
  done
done
O="$T/.claude/orchestrator"
mkdir -p "$O/alpha" "$O/beta" "$O/empty"
echo '{"entries":[{"id":"D-001","kind":"decision","status":"open","title":"a"}]}' > "$O/alpha/tasks.json"
echo '{"entries":[{"id":"D-001","kind":"decision","status":"open","title":"a"},{"id":"D-002","kind":"decision","status":"open","title":"b"},{"id":"D-003","kind":"decision","status":"settled","title":"c"}]}' > "$O/beta/tasks.json"
echo '{"release":"ship"}' > "$O/beta/settings.json"
PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$V" --port "$PORT2" >"$T/out2" 2>&1 &
PID2=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT2/" >/dev/null 2>&1 && break; sleep 0.1; done
B="http://127.0.0.1:$PORT2"
page=$(curl -s "$B/")
[[ $(curl -s "$B/projects.json" | jq -c '[.fixed, (.projects | map("\(.name):\(.needed)"))]') == '[false,["alpha:1","beta:2","demo:0"]]' ]] || fail "project tabs and badges"
[[ $(curl -s "$B/tasks.json?project=beta" | jq '.entries | length') == 3 ]] || fail "per-project board"
[[ $(curl -s "$B/settings.json?project=beta" | jq -r .release) == ship ]] || fail "release word"
[[ $(curl -s "$B/settings.json?project=beta" | jq -c .) == '{"release":"ship"}' ]] || fail "settings body"
[[ $(curl -s "$B/settings.json?project=alpha") == '{}' ]] || fail "missing settings should be {}"
echo '[1]' > "$O/alpha/settings.json"
[[ $(curl -s "$B/settings.json?project=alpha") == '{}' ]] || fail "non-object settings should be {}"
[[ $(code -X POST "$B/settings.json?project=beta") == 405 ]] || fail "settings POST should be 405"
[[ $(code "$B/settings.json") == 400 ]] || fail "settings without project should be 400"
grep -q 'show all' <<<"$page" || fail "done show-all toggle"
grep -q 'past.slice(0,showAll?past.length:prefs.done)' <<<"$page" || fail "done limit"
echo '{"entries":[{"id":"D-001","kind":"decision","status":"open","title":"a","options":[{"key":"A","text":"one","recommended":false},{"key":"B","text":"two","recommended":true}]}]}' > "$O/alpha/tasks.json"
[[ $(curl -s "$B/tasks.json?project=alpha" | jq -c '.entries[0].options | map(.key + (.recommended | tostring))') == '["Afalse","Btrue"]' ]] || fail "options round-trip"
grep -q 'className="opts"\|"ul","opts"' <<<"$page" || fail "options list rendering"
grep -q '"Recommended"' <<<"$page" || fail "recommended tag"
grep -q 'scrollHeight>n.clientHeight' <<<"$page" || fail "note clamp measure"
grep -q 'n.classList.remove("clamp");b.remove()' <<<"$page" || fail "short note drops clamp and toggle"
grep -q 'e.note.length>120' <<<"$page" && fail "toggle must not depend on note length"
grep -q 'b.hidden=!open' <<<"$page" || fail "toggle hidden until measured"
grep -q 'section("Tickets",tickets(ds)' <<<"$page" || fail "tickets column"
grep -q 'Decisions needed' <<<"$page" && fail "old column name"
grep -q '" of "+t.qs.length+" answered"' <<<"$page" || fail "ticket header count"
grep -q 'openTk.has(key)?openTk.get(key):t.left>0' <<<"$page" || fail "ticket default expansion"
grep -q 'const OTHER="Other"' <<<"$page" || fail "ungrouped ticket name"
grep -q '"waiting on "' <<<"$page" || fail "waiting on label"
grep -q 'e.status==="settled"' <<<"$page" || fail "settled answer"
grep -q 'if(open){const body=$("div","qb")' <<<"$page" || fail "question body only when expanded"
grep -q 'id="cog"' <<<"$page" || fail "settings cog"
[[ $(code "$B/tasks.json") == 400 ]] || fail "missing project should be 400"
for bad in '..' '../x' '%2e%2e%2fx' '.hidden' 'a%2fb' '..%2f..%2fetc'; do
  [[ $(code "$B/tasks.json?project=$bad") == 400 ]] || fail "traversal '$bad' should be 400"
  [[ $(code "$B/settings.json?project=$bad") == 400 ]] || fail "settings traversal '$bad' should be 400"
done
[[ $(code "$B/tasks.json?project=empty") == 404 ]] || fail "project without board should be 404"
[[ $(curl -s "$B/projects.json" | jq '.projects | map(.name) | index("empty")') == null ]] || fail "empty dir listed"
[[ $(code -X POST "$B/tasks.json?project=beta") == 405 ]] || fail "multi POST should be 405"
[[ $(curl -s "$B/all.json" | jq -c '[.fixed, (.projects | map(.name)), (.boards | keys), (.settings | keys)]') == '[false,["alpha","beta","demo"],["alpha","beta","demo"],["alpha","beta","demo"]]' ]] || fail "all.json shape"
[[ $(curl -s "$B/all.json" | jq -c '[.projects[] | "\(.name):\(.needed)"]') == '["alpha:1","beta:2","demo:0"]' ]] || fail "all.json needed"
[[ $(curl -s "$B/all.json" | jq '.boards.beta.entries | length') == 3 ]] || fail "all.json board content"
[[ $(curl -s "$B/all.json" | jq -c '[.settings.beta.release, .settings.alpha, .boards.alpha.entries[0].options[1].key]') == '["ship",{},"B"]' ]] || fail "all.json settings"
echo '{"entries":[{"id":"D-001","kind":"decision","status":"settled","title":"a","group":"Theme","answer":"B"},{"id":"T-001","kind":"task","status":"working","title":"t","depends_on":["D-002"]},{"id":"D-002","kind":"decision","status":"open","title":"b"}]}' > "$O/alpha/tasks.json"
[[ $(curl -s "$B/all.json" | jq -c '[.boards.alpha.entries[0].group, .boards.alpha.entries[0].answer, .projects[0].needed]') == '["Theme","B",1]' ]] || fail "group and answer pass through"
cp "$O/beta/tasks.json" "$T/beta.bak"
echo '{bad' > "$O/beta/tasks.json"
[[ $(curl -s "$B/all.json" | jq -c '[.boards.beta, (.projects | map(.name))]') == '[null,["alpha","beta","demo"]]' ]] || fail "all.json invalid board is null"
cp "$T/beta.bak" "$O/beta/tasks.json"
[[ $(code "$B/all.json") == 200 ]] || fail "all.json 200"
[[ $(code -X POST "$B/all.json") == 405 ]] || fail "all.json POST should be 405"
[[ $(code -X DELETE "$B/all.json") == 405 ]] || fail "all.json DELETE should be 405"
[[ $(curl -s "http://127.0.0.1:$PORT/all.json" | jq -c '[.fixed, (.boards | keys), (.settings | keys)]') == '[true,["demo"],["demo"]]' ]] || fail "all.json fixed mode"
[[ $(curl -s "$B/all.json" | jq '.boards | has("empty")') == false ]] || fail "all.json lists only real boards"
[[ $(curl -s "$B/all.json?project=../x" | jq -c '.boards | keys') == '["alpha","beta","demo"]' ]] || fail "all.json ignores project query"
curl -s "$B/" | python3 -c '
import re, sys
js = sys.stdin.read()
m = re.search(r"function select\(name\)\{(.*?)\}\n", js, re.S)
assert m, "select handler missing"
body = m.group(1)
assert "paint()" in body and "await" not in body, "click path must be synchronous"
assert body.index("paint()") < body.index("poll()"), "paint before background refresh"
assert "onclick=()=>select(p.name)" in js, "tab click must call select"
pm = re.search(r"function paint\(\)\{(.*?)\nasync function loadProject", js, re.S)
assert pm and "await" not in pm.group(1) and "fetch(" not in pm.group(1), "paint must not await or fetch"
assert "if(txt===cacheTxt&&!was)return" in js, "unchanged poll must skip render"
assert "select(p)" in js, "follow switch must use select"
' || fail "instant tab click path"
grep -q 'Ready to ' <<<"$page" || fail "ready label"
[[ $(curl -s "http://127.0.0.1:$PORT/projects.json" | jq -c '[.fixed, (.projects | map(.name))]') == '[true,["demo"]]' ]] || fail "fixed mode projects"
echo '{"herdr_workspace":"w11"}' > "$O/beta/settings.json"
FH="$T/herdr"
cat > "$FH" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" == "workspace list" ]] || exit 3
[[ -n ${FAKE_FAIL:-} ]] && exit 1
echo "{\"result\":{\"workspaces\":[{\"focused\":false,\"workspace_id\":\"w1\"},{\"focused\":true,\"workspace_id\":\"$(cat "$(dirname "$0")/focus")\"}]}}"
FAKE
chmod +x "$FH"
PORT3=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
echo w11 > "$T/focus"
HERDR_BIN="$FH" python3 "$V" --port "$PORT3" >"$T/out3" 2>&1 &
PID3=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT3/" >/dev/null 2>&1 && break; sleep 0.1; done
F="http://127.0.0.1:$PORT3/focus.json"
[[ $(curl -s "$F" | jq -c .) == '{"project":"beta","workspace":"w11"}' ]] || fail "focus mapped"
echo w9 > "$T/focus"; sleep 0.4
[[ $(curl -s "$F" | jq -c .) == '{"project":null,"workspace":"w9"}' ]] || fail "focus unmapped"
kill "$PID3"; wait "$PID3" 2>/dev/null || true
printf '#!/bin/sh\nexit 1\n' > "$T/herdr-bad"; chmod +x "$T/herdr-bad"
HERDR_BIN="$T/herdr-bad" python3 "$V" --port "$PORT3" >"$T/out3" 2>&1 &
PID3=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT3/" >/dev/null 2>&1 && break; sleep 0.1; done
[[ $(curl -s "$F" | jq -c .) == '{"project":null,"workspace":null}' ]] || fail "focus unreachable"
kill "$PID3"; wait "$PID3" 2>/dev/null || true
HERDR_BIN="$T/none" python3 "$V" --port "$PORT3" >"$T/out3" 2>&1 &
PID3=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT3/" >/dev/null 2>&1 && break; sleep 0.1; done
[[ $(curl -s "$F" | jq -c .) == '{"project":null,"workspace":null}' ]] || fail "focus missing binary"
[[ $(code -X POST "$F") == 405 ]] || fail "focus POST should be 405"
kill "$PID3"; wait "$PID3" 2>/dev/null || true
grep -q 'Follow herdr' <<<"$page" || fail "follow toggle"
kill "$PID2"; wait "$PID2" 2>/dev/null || true; PID2=""
python3 "$V" --project ../x --port "$PORT2" >"$T/bad" 2>&1 && fail "traversal --project should exit non-zero"
grep -q "invalid project name" "$T/bad" || fail "bad --project message"
lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN | grep -q "127.0.0.1:$PORT" || fail "not bound to 127.0.0.1"
set +e
python3 "$V" --project demo --port "$PORT" >"$T/dup" 2>&1
RC=$?
set -e
[[ $RC -ne 0 ]] || fail "second viewer on busy port should exit non-zero"
[[ $(wc -l < "$T/dup") -eq 1 ]] || fail "busy port should print one line"
grep -q "port $PORT is already in use.*--port" "$T/dup" || fail "busy port message"
grep -q Traceback "$T/dup" && fail "busy port traceback"
echo ok
