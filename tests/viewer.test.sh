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
curl -s "http://127.0.0.1:$PORT/" | grep -q 'Herdmaster board' || fail "page"
[[ $(curl -s "http://127.0.0.1:$PORT/tasks.json" | jq -r '.entries[0].id') == T-001 ]] || fail "json"
[[ $(code -X POST "http://127.0.0.1:$PORT/tasks.json") == 405 ]] || fail "POST should be 405"
[[ $(code -X DELETE "http://127.0.0.1:$PORT/") == 405 ]] || fail "DELETE should be 405"
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
[[ $(curl -s "$B/projects.json" | jq -c '[.fixed, (.projects | map("\(.name):\(.needed)"))]') == '[false,["alpha:1","beta:2","demo:0"]]' ]] || fail "project tabs and badges"
[[ $(curl -s "$B/tasks.json?project=beta" | jq '.entries | length') == 3 ]] || fail "per-project board"
[[ $(curl -s "$B/settings.json?project=beta" | jq -r .release) == ship ]] || fail "release word"
[[ $(curl -s "$B/settings.json?project=beta" | jq -c .) == '{"release":"ship"}' ]] || fail "settings body"
[[ $(curl -s "$B/settings.json?project=alpha") == '{}' ]] || fail "missing settings should be {}"
echo '[1]' > "$O/alpha/settings.json"
[[ $(curl -s "$B/settings.json?project=alpha") == '{}' ]] || fail "non-object settings should be {}"
[[ $(code -X POST "$B/settings.json?project=beta") == 405 ]] || fail "settings POST should be 405"
[[ $(code "$B/settings.json") == 400 ]] || fail "settings without project should be 400"
curl -s "$B/" | grep -q 'show all' || fail "done show-all toggle"
curl -s "$B/" | grep -q 'past.slice(0,showAll?past.length:prefs.done)' || fail "done limit"
curl -s "$B/" | grep -q 'id="cog"' || fail "settings cog"
[[ $(code "$B/tasks.json") == 400 ]] || fail "missing project should be 400"
for bad in '..' '../x' '%2e%2e%2fx' '.hidden' 'a%2fb' '..%2f..%2fetc'; do
  [[ $(code "$B/tasks.json?project=$bad") == 400 ]] || fail "traversal '$bad' should be 400"
  [[ $(code "$B/settings.json?project=$bad") == 400 ]] || fail "settings traversal '$bad' should be 400"
done
[[ $(code "$B/tasks.json?project=empty") == 404 ]] || fail "project without board should be 404"
[[ $(curl -s "$B/projects.json" | jq '.projects | map(.name) | index("empty")') == null ]] || fail "empty dir listed"
[[ $(code -X POST "$B/tasks.json?project=beta") == 405 ]] || fail "multi POST should be 405"
curl -s "$B/" | grep -q 'Ready to ' || fail "ready label"
[[ $(curl -s "http://127.0.0.1:$PORT/projects.json" | jq -c '[.fixed, (.projects | map(.name))]') == '[true,["demo"]]' ]] || fail "fixed mode projects"
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
