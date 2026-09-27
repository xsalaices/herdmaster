#!/usr/bin/env bash
# Reads and writes ~/.claude/orchestrator/<project>/tasks.json (see docs/design/board.md).
# Usage: herdmaster-board.sh add <task|decision> <title> [--review auto|user] [--depends ID,ID] [--note TEXT] [--recommend TEXT]
#          decisions also take --option "A|text" (repeatable, keys A..Z), --recommend-key K and --group "<ticket name>"
#        herdmaster-board.sh set-group <id> <ticket name>
#        herdmaster-board.sh set-review <task id> [--summary S] [--diff D] [--tests T] [--preview URL] [--screenshot PATH]... [--link "label|url"]...
#        herdmaster-board.sh set-options <id> --option "A|text" [--option "B|text"] [--recommend-key K]
#        herdmaster-board.sh status <id> <state> [answer]     (answer only when settling a decision)
#        herdmaster-board.sh attempt <id> <status> [feedback] [link]
#        herdmaster-board.sh supersede <id>
#        herdmaster-board.sh release-when-done <id> [true|false]
#        herdmaster-board.sh settings get [key] | settings set <key> <value>
#          keys: release, grid_panes, worker_layout, max_panes, herdr_workspace, notify, agent, agent_planner, agent_orchestrator, agent_worker
#        herdmaster-board.sh import-legacy
#        herdmaster-board.sh archive
#        herdmaster-board.sh count | show
# Project comes from $HERDMASTER_PROJECT. Single writer (the orchestrator); no lock, so concurrent writers can lose updates.
set -euo pipefail

die() { echo "herdmaster-board: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
[[ -n ${HERDMASTER_PROJECT:-} ]] || die "HERDMASTER_PROJECT is not set"
case $HERDMASTER_PROJECT in */*|.*) die "invalid HERDMASTER_PROJECT" ;; esac

DIR="$HOME/.claude/orchestrator/$HERDMASTER_PROJECT"
BOARD="$DIR/tasks.json"
SHOWN="$DIR/tasks.shown"
SETTINGS="$DIR/settings.json"
ARCHIVE="$DIR/tasks-archive.json"
KEEP_FINISHED=200

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

load() {
  if [[ -f $BOARD ]]; then cat "$BOARD"; else echo '{"schema_version":1,"entries":[]}'; fi
}

save() {
  mkdir -p "$DIR"
  local tmp; tmp=$(mktemp "$DIR/.tasks.XXXXXX")
  printf '%s\n' "$1" > "$tmp" && mv "$tmp" "$BOARD"
}

need_entry() {
  load | jq -e --arg id "$1" 'any(.entries[]; .id == $id)' >/dev/null || die "no such entry: $1"
}

valid_state() {
  local kind=$1 s=$2
  case $kind in
    task) [[ $s =~ ^(working|finished|in\ review|approved|deploy-ready|blocked|failed|paused|done|cancelled)$ ]] ;;
    decision) [[ $s =~ ^(open|settled|superseded)$ ]] ;;
  esac
}

options_json() {
  local raw=$1 rkey=$2 out
  out=$(jq -cn --arg raw "$raw" --arg rkey "$rkey" '
    ($raw | split("\n") | map(select(length > 0))
      | map(index("|") as $i | if $i == null then error("bad") else {key: .[:$i], text: (.[$i + 1:] | sub("^ +| +$"; ""; "g"))} end)) as $o
    | if ($o | length) == 0 then error("none")
      elif ($o | any(.key | test("^[A-Z]$") | not)) then error("key")
      elif ($o | any(.text == "")) then error("text")
      elif ($o | map(.key) | (unique | length) != length) then error("dup")
      elif $rkey != "" and ($o | any(.key == $rkey) | not) then error("rkey")
      else $o | map(. + {recommended: (.key == $rkey)}) end' 2>&1) || case $out in
    *rkey*) die "--recommend-key must match an option key" ;;
    *bad*) die "--option must look like KEY|text" ;;
    *key*) die "--option key must be a single letter A-Z" ;;
    *text*) die "--option text must not be empty" ;;
    *dup*) die "--option keys must be unique" ;;
    *none*) die "at least one --option is required" ;;
    *) die "invalid options" ;;
  esac
  printf '%s\n' "$out"
}

group_name() {
  local g; g=$(jq -rn --arg g "$1" '$g | gsub("^\\s+|\\s+$"; "")')
  [[ -n $g ]] || die "$2: group name must not be empty"
  (( ${#g} <= 60 )) || die "$2: group name is at most 60 characters"
  [[ $g != *[[:cntrl:]]* ]] || die "$2: group name must be one line"
  printf '%s\n' "$g"
}

cmd_add() {
  local kind=${1:-} title=${2:-} review="" deps="" note="" rec="" opts="" rkey="" group="" has_group=""
  [[ $kind == task || $kind == decision ]] || die "add: kind must be task or decision"
  [[ -n $title ]] || die "add: title required"
  shift 2
  while (($#)); do
    case $1 in
      --review) review=${2:-}; shift 2 ;;
      --depends) deps=${2:-}; shift 2 ;;
      --note) note=${2:-}; shift 2 ;;
      --recommend) rec=${2:-}; shift 2 ;;
      --option) opts+=${2:-}$'\n'; shift 2 ;;
      --recommend-key) rkey=${2:-}; shift 2 ;;
      --group) group=${2:-}; has_group=1; shift 2 ;;
      *) die "add: unknown argument $1" ;;
    esac
  done
  if [[ -z $review ]]; then
    if [[ $kind == decision ]]; then review=user; else review=auto; fi
  fi
  [[ $review == auto || $review == user ]] || die "add: --review must be auto or user"
  [[ -z $opts && -z $rkey ]] || [[ $kind == decision ]] || die "add: --option only applies to decisions"
  [[ -z $rkey || -n $opts ]] || die "add: --recommend-key needs --option"
  [[ -z $has_group ]] || [[ $kind == decision ]] || die "add: --group only applies to decisions"
  [[ -z $has_group ]] || group=$(group_name "$group" add)
  local board dep_json opt_json='[]'
  [[ -z $opts ]] || opt_json=$(options_json "$opts" "$rkey")
  board=$(load)
  dep_json=$(jq -cn --arg d "$deps" '$d | split(",") | map(select(length > 0))')
  jq -e --argjson d "$dep_json" '. as $b | $d | all(. as $x | $b.entries | any(.id == $x))' <<<"$board" >/dev/null \
    || die "add: --depends names an unknown id"
  local out
  out=$(jq --arg kind "$kind" --arg title "$title" --arg review "$review" --argjson deps "$dep_json" --arg note "$note" --arg rec "$rec" --argjson opts "$opt_json" --arg group "$group" --arg ts "$(now)" '
    (if $kind == "task" then "T" else "D" end) as $p
    | ([.entries[] | select(.id | startswith($p + "-")) | .id[2:] | tonumber] | (max // 0) + 1) as $n
    | ($p + "-" + ("000" + ($n | tostring) | .[-3:])) as $id
    | .entries += [{id: $id, kind: $kind, title: $title,
        status: (if $kind == "task" then "working" else "open" end),
        review: $review, depends_on: $deps, attempts: [], created: $ts, updated: $ts}
        + (if $note != "" then {note: $note} else {} end)
        + (if $rec != "" then {recommend: $rec} else {} end)
        + (if ($opts | length) > 0 then {options: $opts} else {} end)
        + (if $group != "" then {group: $group} else {} end)]
    | {board: ., id: $id}' <<<"$board")
  save "$(jq .board <<<"$out")"
  jq -r .id <<<"$out"
}

cmd_set_options() {
  local id=${1:-} opts="" rkey=""
  [[ -n $id ]] || die "set-options: <id> required"
  shift
  while (($#)); do
    case $1 in
      --option) opts+=${2:-}$'\n'; shift 2 ;;
      --recommend-key) rkey=${2:-}; shift 2 ;;
      *) die "set-options: unknown argument $1" ;;
    esac
  done
  need_entry "$id"
  load | jq -e --arg id "$id" 'any(.entries[]; .id == $id and .kind == "decision")' >/dev/null \
    || die "set-options: $id is not a decision"
  local opt_json; opt_json=$(options_json "$opts" "$rkey")
  save "$(load | jq --arg id "$id" --argjson o "$opt_json" --arg ts "$(now)" \
    '.entries |= map(if .id == $id then .options = $o | .updated = $ts else . end)')"
}

cmd_set_group() {
  local id=${1:-} group=${2:-}
  [[ -n $id && -n $group ]] || die "set-group: <id> <ticket name> required"
  need_entry "$id"
  load | jq -e --arg id "$id" 'any(.entries[]; .id == $id and .kind == "decision")' >/dev/null \
    || die "set-group: $id is not a decision"
  group=$(group_name "$group" set-group)
  save "$(load | jq --arg id "$id" --arg g "$group" --arg ts "$(now)" \
    '.entries |= map(if .id == $id then .group = $g | .updated = $ts else . end)')"
}

flag() { if [[ -n $1 ]]; then echo true; else echo false; fi; }

cmd_set_review() {
  local id=${1:-} summary="" diff="" tests="" preview="" shots="" links="" has_s="" has_d="" has_t="" has_p=""
  [[ -n $id ]] || die "set-review: <id> required"
  shift
  while (($#)); do
    case $1 in
      --summary) summary=${2:-}; has_s=1; shift 2 ;;
      --diff) diff=${2:-}; has_d=1; shift 2 ;;
      --tests) tests=${2:-}; has_t=1; shift 2 ;;
      --preview) preview=${2:-}; has_p=1; shift 2 ;;
      --screenshot) shots+=${2:-}$'\n'; shift 2 ;;
      --link) links+=${2:-}$'\n'; shift 2 ;;
      *) die "set-review: unknown argument $1" ;;
    esac
  done
  need_entry "$id"
  load | jq -e --arg id "$id" 'any(.entries[]; .id == $id and .kind == "task")' >/dev/null \
    || die "set-review: $id is not a task"
  local url_re='^https?://[^[:space:]]+$'
  [[ -z $has_p || -z $preview || $preview =~ $url_re ]] || die "set-review: --preview must be an http(s) URL"
  local link_json shot_json
  link_json=$(jq -cn --arg raw "$links" '$raw | split("\n") | map(select(length > 0))
    | map(index("|") as $i | if $i == null then {label: "", url: .} else {label: .[:$i], url: .[$i + 1:]} end
      | .label |= sub("^ +| +$"; ""; "g") | .url |= sub("^ +| +$"; ""; "g"))')
  jq -e 'all(.[]; .label != "" and (.url | test("^https?://[^\\s]+$")))' <<<"$link_json" >/dev/null \
    || die "set-review: --link must look like \"label|http(s) url\""
  shot_json=$(jq -cn --arg raw "$shots" '$raw | split("\n") | map(select(length > 0))')
  jq -e 'all(.[]; startswith("/") and (contains("\u0000") | not))' <<<"$shot_json" >/dev/null \
    || die "set-review: --screenshot must be an absolute path"
  save "$(load | jq --arg id "$id" --arg ts "$(now)" \
    --arg s "$summary" --arg d "$diff" --arg t "$tests" --arg p "$preview" \
    --argjson hs "$(flag "$has_s")" --argjson hd "$(flag "$has_d")" \
    --argjson ht "$(flag "$has_t")" --argjson hp "$(flag "$has_p")" \
    --argjson shots "$shot_json" --argjson links "$link_json" '
    def put($k; $v; $has): if $has then (if $v == "" then del(.[$k]) else .[$k] = $v end) else . end;
    .entries |= map(if .id == $id then
      .review_pack = ((.review_pack // {})
        | put("summary"; $s; $hs) | put("diff"; $d; $hd) | put("tests"; $t; $ht) | put("preview_url"; $p; $hp)
        | if ($shots | length) > 0 then .screenshots = $shots else . end
        | if ($links | length) > 0 then .links = $links else . end)
      | .updated = $ts else . end)')"
}

cmd_status() {
  local id=${1:-} state=${2:-} answer=${3:-}
  [[ -n $id && -n $state ]] || die "status: <id> <state> required"
  need_entry "$id"
  local kind; kind=$(load | jq -r --arg id "$id" '.entries[] | select(.id == $id) | .kind')
  valid_state "$kind" "$state" || die "status: '$state' is not a valid $kind state"
  [[ -z $answer ]] || [[ $kind == decision && $state == settled ]] || die "status: an answer only goes with settling a decision"
  save "$(load | jq --arg id "$id" --arg s "$state" --arg a "$answer" --arg ts "$(now)" \
    '.entries |= map(if .id == $id then .status = $s | .updated = $ts
      | if $a != "" then .answer = $a else . end else . end)')"
}

cmd_attempt() {
  local id=${1:-} status=${2:-} feedback=${3:-} link=${4:-}
  [[ -n $id && -n $status ]] || die "attempt: <id> <status> required"
  need_entry "$id"
  save "$(load | jq --arg id "$id" --arg s "$status" --arg f "$feedback" --arg l "$link" --arg ts "$(now)" '
    .entries |= map(if .id == $id
      then .attempts += [{status: $s, feedback: (if $f == "" then null else $f end), link: (if $l == "" then null else $l end)}] | .updated = $ts
      else . end)')"
}

cmd_supersede() {
  local id=${1:-}
  [[ -n $id ]] || die "supersede: <id> required"
  need_entry "$id"
  load | jq -e --arg id "$id" 'any(.entries[]; .id == $id and .kind == "decision")' >/dev/null \
    || die "supersede: $id is not a decision"
  save "$(load | jq --arg id "$id" --arg ts "$(now)" '
    .entries |= map(
      if .id == $id then .status = "superseded" | .updated = $ts
      elif (.depends_on | index($id)) then
        .flags = ((.flags // []) + (["superseded:" + $id] - (.flags // []))) | .updated = $ts
      else . end)')"
}

cmd_release_when_done() {
  local id=${1:-} val=${2:-true}
  [[ -n $id ]] || die "release-when-done: <id> required"
  [[ $val == true || $val == false ]] || die "release-when-done: value must be true or false"
  need_entry "$id"
  load | jq -e --arg id "$id" 'any(.entries[]; .id == $id and .kind == "task")' >/dev/null \
    || die "release-when-done: $id is not a task"
  save "$(load | jq --arg id "$id" --argjson v "$val" --arg ts "$(now)" \
    '.entries |= map(if .id == $id then .release_when_done = $v | .updated = $ts else . end)')"
}

settings_json() { if [[ -f $SETTINGS ]]; then cat "$SETTINGS"; else echo '{}'; fi; }

cmd_settings() {
  local op=${1:-} key=${2:-} val=${3:-}
  case $op in
    get)
      if [[ -z $key ]]; then settings_json | jq -S .; return; fi
      [[ $key =~ ^(release|grid_panes|worker_layout|max_panes|herdr_workspace|notify|agent|agent_planner|agent_orchestrator|agent_worker)$ ]] || die "settings: unknown key '$key'"
      settings_json | jq -r --arg k "$key" '(.[$k] // if $k == "release" then "deploy"
        elif $k | startswith("agent") then .agent // "claude" else empty end) | tostring' ;;
    set)
      [[ -n $key && -n $val ]] || die "settings set: <key> <value> required"
      local json
      case $key in
        release) [[ $val =~ ^(merge|deploy|push|ship)$ ]] || die "settings: release must be merge, deploy, push or ship"
          json=$(jq -cn --arg v "$val" '$v') ;;
        worker_layout) [[ $val == tab || $val == main ]] || die "settings: worker_layout must be tab or main"
          json=$(jq -cn --arg v "$val" '$v') ;;
        grid_panes|max_panes) [[ $val =~ ^[1-9][0-9]*$ ]] || die "settings: $key must be a positive integer"
          json=$val ;;
        herdr_workspace) [[ $val =~ ^[A-Za-z0-9._:-]+$ ]] || die "settings: herdr_workspace must be a herdr workspace id"
          json=$(jq -cn --arg v "$val" '$v') ;;
        notify) [[ $val == on || $val == off ]] || die "settings: notify must be on or off"
          json=$(jq -cn --arg v "$val" '$v') ;;
        agent|agent_planner|agent_orchestrator|agent_worker)
          [[ $val =~ ^[a-z0-9-]+$ && -f $(dirname "$0")/../adapters/$val.sh ]] || die "settings: $key must name an adapter in adapters/"
          json=$(jq -cn --arg v "$val" '$v') ;;
        *) die "settings: unknown key '$key'" ;;
      esac
      mkdir -p "$DIR"
      local tmp; tmp=$(mktemp "$DIR/.settings.XXXXXX")
      settings_json | jq --arg k "$key" --argjson v "$json" '.[$k] = $v' > "$tmp" && mv "$tmp" "$SETTINGS" ;;
    *) die "settings: expected get or set" ;;
  esac
}

# Ceiling: archive is one JSON file read and rewritten whole per run; if it grows large, switch to one file per month.
cmd_archive() {
  [[ -f $BOARD ]] || return 0
  local split moved
  split=$(load | jq -c --argjson keep "$KEEP_FINISHED" '
    [.entries[] | select(.kind == "task" and (.status == "done" or .status == "cancelled"))
      | {id, updated}] | sort_by(.updated) | reverse | .[$keep:] | map(.id)')
  moved=$(jq length <<<"$split")
  (( moved > 0 )) || return 0
  local arch; if [[ -f $ARCHIVE ]]; then arch=$(cat "$ARCHIVE"); else arch='{"schema_version":1,"entries":[]}'; fi
  local tmp; tmp=$(mktemp "$DIR/.archive.XXXXXX")
  jq --argjson ids "$split" '.entries += [$b.entries[] | select(.id as $i | $ids | index($i))]' \
    --argjson b "$(load)" <<<"$arch" > "$tmp" && mv "$tmp" "$ARCHIVE"
  save "$(load | jq --argjson ids "$split" '.entries |= map(select(.id as $i | $ids | index($i) | not))')"
  echo "archived $moved"
}

count_line() {
  load | jq -r '
    def age: if . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    .entries as $e
    | [$e[] | select(.kind == "task" and .status == "in review")] as $rev
    | [ (if ($rev | length) > 0 then
          "\($rev | length) in review (oldest \(now - ([$rev[] | .updated | fromdateiso8601] | min) | age))" else empty end),
        (([$e[] | select(.kind == "task" and .status == "deploy-ready")] | length) as $n
          | if $n > 0 then "\($n) deploy-ready" else empty end),
        (([$e[] | select(.kind == "decision" and .status == "open")] | length) as $n
          | if $n > 0 then "\($n) decision open" else empty end),
        (([$e[] | select((.flags // []) | length > 0)] | length) as $n
          | if $n > 0 then "\($n) flagged" else empty end) ]
    | if length == 0 then "" else "Board: " + join(", ") end'
}

cmd_count() {
  [[ -f $BOARD ]] || return 0
  local sum line
  sum=$(shasum "$BOARD" | cut -d' ' -f1)
  [[ -f $SHOWN && $(cat "$SHOWN") == "$sum" ]] && return 0
  line=$(count_line)
  printf '%s\n' "$sum" > "$SHOWN.tmp" && mv "$SHOWN.tmp" "$SHOWN"
  [[ -n $line ]] && printf '%s\n' "$line"
  return 0
}

cmd_show() {
  load | jq -r '.entries[] | "\(.id)\t\(.status)\t\(.review)\t\(.title)"
    + (if (.depends_on | length) > 0 then "\t<- " + (.depends_on | join(",")) else "" end)
    + (if (.flags // []) | length > 0 then "\t[" + (.flags | join(",")) + "]" else "" end)
    + (if (.group // "") != "" then "\tticket: " + .group else "" end)
    + (if (.review_pack // {}) | length > 0 then "\n    review: " + ([
        (.review_pack.summary // empty),
        ((.review_pack.screenshots // []) | length | if . > 0 then "\(.) shot" + (if . > 1 then "s" else "" end) else empty end),
        (if .review_pack.preview_url then "preview" else empty end),
        ((.review_pack.links // []) | length | if . > 0 then "\(.) link" + (if . > 1 then "s" else "" end) else empty end),
        (if .review_pack.tests then "tests: " + .review_pack.tests else empty end)] | join(" | ")) else "" end)
    + ((.options // []) | map("\n    \(.key)) \(.text)" + (if .recommended then "  (recommended)" else "" end)) | join(""))'
}

legacy_open_json() {
  awk '
    function flush() {
      if (title != "") {
        gsub(/^[ \t]+|[ \t]+$/, "", q); gsub(/^[ \t]+|[ \t]+$/, "", c)
        print title "\t" block "\t" q "\t" c "\t" opts
      }
      title = ""; q = ""; c = ""; opts = ""
    }
    /^## / {
      flush()
      t = substr($0, 4); block = "no"
      if (match(t, /, blocking: (yes|no)\)[ \t]*$/)) { block = substr(t, RSTART + 12, RLENGTH - 13); t = substr(t, 1, RSTART - 1); sub(/ \([^(]*$/, "", t) }
      else sub(/ \([^(]*\)[ \t]*$/, "", t)
      title = t; next
    }
    title == "" { next }
    /^Question:/ { sub(/^Question:[ \t]*/, ""); q = $0; next }
    /^Context:/ { sub(/^Context:[ \t]*/, ""); c = $0; next }
    /^Options:/ { sub(/^Options:[ \t]*/, ""); opts = $0; next }
    { if (opts != "" && c == "") opts = opts " " $0 }
    END { flush() }
  ' "$1" | jq -Rn '
    [inputs | split("\t") | select(.[0] != "") | {
      title: .[0], blocking: (.[1] == "yes"),
      note: ([.[2], .[3]] | map(select(length > 0)) | join(" ")),
      recommend: ((.[4] // "") | [scan("[A-Z]\\)[^()]*\\(recommended[^)]*\\)")] | (.[0] // "")
        | sub("^[A-Z]\\) *"; "") | sub(" *\\(recommended[^)]*\\)"; ""))
    }]'
}

legacy_settled_json() {
  jq -Rn '
    [inputs | select(startswith("- "))
      | .[2:]
      | sub("^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{1,2}:[0-9]{2})? *"; "")
      | sub("^\\([^)]*\\): *"; "")
      | select(length > 0)
      | {title: (split(". ")[0] | split(": ")[0] | .[:80]), note: .[:240]}]' < "$1"
}

cmd_import_legacy() {
  local legacy="$HOME/.claude/orchestrator/$HERDMASTER_PROJECT"
  local marker="$DIR/.legacy-imported"
  local dq="$legacy/design-queue.md" dc="$legacy/decisions.md"
  [[ -f $dq || -f $dc ]] || { echo "imported open 0, imported settled 0, skipped 0"; return 0; }
  [[ -f $marker ]] && { echo "already imported"; return 0; }
  local open='[]' settled='[]'
  [[ -f $dq ]] && open=$(legacy_open_json "$dq")
  [[ -f $dc ]] && settled=$(legacy_settled_json "$dc")
  local out
  out=$(jq --argjson open "$open" --argjson settled "$settled" --arg ts "$(now)" '
    def mk($e; $status): {id: "", kind: "decision", title: $e.title, status: $status, review: "user",
        depends_on: [], attempts: [], created: $ts, updated: $ts}
        + (if ($e.note // "") != "" then {note: $e.note} else {} end)
        + (if ($e.recommend // "") != "" then {recommend: $e.recommend} else {} end)
        + (if $e.blocking != null then {blocking: $e.blocking} else {} end);
    reduce ((($open | map(mk(.; "open"))) + ($settled | map(mk(.; "settled"))))[]) as $x
      ({board: ., skipped: 0, open: 0, settled: 0};
        if (.board.entries | any(.title == $x.title)) then .skipped += 1
        else
          ([.board.entries[] | select(.id | startswith("D-")) | .id[2:] | tonumber] | (max // 0) + 1) as $n
          | .board.entries += [$x | .id = "D-" + ("000" + ($n | tostring) | .[-3:])]
          | if $x.status == "open" then .open += 1 else .settled += 1 end
        end)' <<<"$(load)")
  save "$(jq .board <<<"$out")"
  : > "$marker.tmp" && mv "$marker.tmp" "$marker"
  jq -r '"imported open \(.open), imported settled \(.settled), skipped \(.skipped)"' <<<"$out"
}

sub=${1:-}; shift || true
case $sub in
  add) cmd_add "$@" ;;
  set-options) cmd_set_options "$@" ;;
  set-review) cmd_set_review "$@" ;;
  set-group) cmd_set_group "$@" ;;
  status) cmd_status "$@" ;;
  attempt) cmd_attempt "$@" ;;
  supersede) cmd_supersede "$@" ;;
  release-when-done) cmd_release_when_done "$@" ;;
  settings) cmd_settings "$@" ;;
  import-legacy) cmd_import_legacy ;;
  archive) cmd_archive ;;
  count) cmd_count ;;
  show) cmd_show ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
