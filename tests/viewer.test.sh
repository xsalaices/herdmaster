#!/usr/bin/env bash
set -euo pipefail
V="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-viewer.py"
T=$(mktemp -d)
PID=""
trap '[[ -n $PID ]] && kill "$PID" 2>/dev/null; rm -rf -- "$T"' EXIT
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
