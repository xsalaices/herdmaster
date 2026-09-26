#!/usr/bin/env bash
# Reaps clearly-orphaned leftovers and reports other CPU hogs. Run every 10 minutes via launchd.
# LESSON: match processes by EXACT process name only (pgrep -x). Never match command-line text
# (pgrep -f / pkill -f): it hits unrelated processes and other agents' servers.
HERDMASTER_HOME="${HERDMASTER_HOME:-$HOME/.claude/herdmaster}"
LOG="$HERDMASTER_HOME/logs/cpu-reaper.log"
# Space-separated exact process names that are safe to kill when orphaned (parent is launchd) and old.
REAP_NAMES="${HERDMASTER_REAP_NAMES:-chrome-headless-shell}"
REAP_MIN_AGE_SECS="${HERDMASTER_REAP_MIN_AGE_SECS:-7200}"
HOG_CPU="${HERDMASTER_HOG_CPU:-90}"
HOG_MIN_AGE_SECS="${HERDMASTER_HOG_MIN_AGE_SECS:-3600}"
NOTIFY_LOAD="${HERDMASTER_NOTIFY_LOAD:-12}"
mkdir -p "$HERDMASTER_HOME/logs"
now=$(date '+%F %T')

secs() {  # macOS ps has no etimes; convert [[dd-]hh:]mm:ss
  ps -o etime= -p "$1" 2>/dev/null | awk '{ n=split($1,a,/[-:]/); s=0; m[1]=1; m[2]=60; m[3]=3600; m[4]=86400; for(i=n;i>=1;i--) s+=a[i]*m[n-i+1]; print s }'
}

for name in $REAP_NAMES; do
  for pid in $(pgrep -x "$name"); do
    t=$(secs "$pid"); pp=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n $t && $t -gt $REAP_MIN_AGE_SECS && $pp == 1 ]] || continue
    echo "$now killed orphaned $name pid=$pid age=${t}s" >> "$LOG"
    kill "$pid" 2>/dev/null
  done
done

load=$(sysctl -n vm.loadavg | awk '{print int($2)}')
hogs=$(ps -Ao pid=,pcpu=,comm= | awk -v c="$HOG_CPU" '$2>c {print $1" "$2"% "$3}' \
  | grep -viE 'WindowServer|kernel_task' \
  | while read -r pid pc cmd; do t=$(secs "$pid"); [[ -n $t && $t -gt $HOG_MIN_AGE_SECS ]] && echo "$pid $pc ${cmd##*/}"; done | head -5)
if [[ -n $hogs ]]; then
  echo "$now load=$load hogs=[${hogs//$'\n'/; }]" >> "$LOG"
  if (( load >= NOTIFY_LOAD )); then
    osascript -e "display notification \"Load ${load}. See cpu-reaper.log\" with title \"herdmaster cpu-reaper\"" 2>/dev/null
  fi
fi
exit 0
