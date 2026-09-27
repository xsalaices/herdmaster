#!/usr/bin/env bash
# Generates the Claude skills and the worker brief template from roles/*.md and roles/transport-claude.md.
# Usage: scripts/build-skills.sh [--out DIR]   writes under DIR (default: this repo)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$REPO
if [[ ${1:-} == --out ]]; then OUT=${2:?--out needs a directory}; fi

# Values are the lines between ~~~ fences under a "## key" heading; they are inserted verbatim, never rescanned.
build() {
  local role=$1 dest=$OUT/$2 text
  text=$(awk -v role="$role" '
    FNR == NR {
      if (fence) { if ($0 == "~~~") { fence = 0; key = "" } else v[key] = n[key]++ ? v[key] "\n" $0 : $0; next }
      if ($0 ~ /^## /) key = substr($0, 4)
      else if ($0 == "~~~" && key != "") { fence = 1; n[key] = 0; v[key] = "" }
      next
    }
    FNR == 1 && ((role ".frontmatter") in v) { print v[role ".frontmatter"]; print "" }
    {
      line = $0; out = ""
      while ((i = index(line, "{{")) > 0 && (j = index(substr(line, i + 2), "}}")) > 0) {
        k = substr(line, i + 2, j - 1)
        if (!(k in v)) { printf "build-skills: unknown placeholder {{%s}} in %s\n", k, FILENAME > "/dev/stderr"; exit 1 }
        out = out substr(line, 1, i - 1) v[k]
        line = substr(line, i + j + 3)
      }
      print out line
    }' "$REPO/roles/transport-claude.md" "$REPO/roles/$role.md")
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$text" > "$dest"
}

build planner skills/herdmaster/SKILL.md
build orchestrator skills/orchestrator/SKILL.md
build worker examples/worker-brief-template.md
