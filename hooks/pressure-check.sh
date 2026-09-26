#!/usr/bin/env bash
# Records system pressure once per run (schedule it every minute via launchd) so every
# Claude session can see it. Read by hooks/pressure-guard.sh.
HERDMASTER_HOME="${HERDMASTER_HOME:-$HOME/.claude/herdmaster}"
STATE="$HERDMASTER_HOME/state/pressure.json"
LOG="$HERDMASTER_HOME/logs/pressure.log"
HIGH_LOAD="${HERDMASTER_HIGH_LOAD:-16}"
CRIT_LOAD="${HERDMASTER_CRIT_LOAD:-24}"
HIGH_FREE="${HERDMASTER_HIGH_FREE_PCT:-10}"
CRIT_FREE="${HERDMASTER_CRIT_FREE_PCT:-6}"
mkdir -p "$HERDMASTER_HOME/state" "$HERDMASTER_HOME/logs"

load=$(sysctl -n vm.loadavg | awk '{printf "%.1f", $2}')
free=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ {gsub("%","",$2); print $2+0}')
top=$(ps -Ao pcpu=,comm= -r | head -1 | awk '{c=$2; sub(".*/","",c); print c" "$1"%"}')
free_n="${free:-100}"

level=ok
if (( ${load%.*} >= CRIT_LOAD || free_n <= CRIT_FREE )); then level=critical
elif (( ${load%.*} >= HIGH_LOAD || free_n <= HIGH_FREE )); then level=high; fi

prev=$(jq -r '.level // ""' "$STATE" 2>/dev/null)
printf '{"level":"%s","load":%s,"mem_free_pct":%s,"top":"%s","ts":%s}\n' \
  "$level" "$load" "${free:-null}" "$top" "$(date +%s)" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

if [[ $level != ok && $level != "$prev" ]]; then
  echo "$(date '+%F %T') $level load=$load free=${free}% top=$top" >> "$LOG"
  osascript -e "display notification \"Load $load, free mem ${free}%. Agents told to hold heavy work.\" with title \"Mac under pressure: $level\"" 2>/dev/null
fi
exit 0
