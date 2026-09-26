#!/usr/bin/env bash
# PreToolUse(Bash) hook. While pressure.json says high/critical (and is fresh), deny heavy
# commands with a "wait 2-5 minutes and retry" message. Fails open when the state is ok,
# missing or stale. Emergency override: HERDMASTER_IGNORE_PRESSURE=1 (use sparingly).
HERDMASTER_HOME="${HERDMASTER_HOME:-$HOME/.claude/herdmaster}"
STATE="$HERDMASTER_HOME/state/pressure.json"
[[ -n ${HERDMASTER_IGNORE_PRESSURE:-} || ! -f $STATE ]] && exit 0
input=$(cat)
python3 - "$STATE" "$input" <<'PY'
import json, os, re, sys, time
try:
    st = json.load(open(sys.argv[1]))
    cmd = json.loads(sys.argv[2]).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(0)
if st.get("level") not in ("high", "critical") or time.time() - st.get("ts", 0) > 180:
    sys.exit(0)
default = (r"(\bnpm\s+run\s+(dev|test|build|e2e)|\bnpx\s+(vite|vitest|playwright)|\bvitest\b|\bplaywright\b"
           r"|\bdocker\s+(run|compose\s+up)|\bnext\s+build|\bcargo\s+build|\bgradle|\bxcodebuild)")
heavy = os.environ.get("HERDMASTER_HEAVY_REGEX", default)
if not re.search(heavy, cmd):
    sys.exit(0)
state_path = sys.argv[1]
msg = (f"System under pressure ({st['level']}): load {st.get('load')}, free memory {st.get('mem_free_pct')}%, "
       f"top process {st.get('top')}. Do not start heavy work (dev servers, test suites, browsers, container stacks) "
       f"right now. Wait 2-5 minutes, check {state_path}, then retry. Light commands are still allowed.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                          "permissionDecision": "deny",
                                          "permissionDecisionReason": msg}}))
PY
