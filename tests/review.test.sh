#!/usr/bin/env bash
set -euo pipefail
V="$(cd "$(dirname "$0")/.." && pwd)/bin/herdmaster-viewer.py"
T=$(mktemp -d)
ROOT=/private/tmp/claude-501
[[ -d $ROOT ]] || mkdir -m 700 "$ROOT"
D=$(mktemp -d "$ROOT/hm-file-test.XXXXXX")
PID=""
FILES=(shot.png UPPER.PNG note.txt big.png run.exe data.json sneaky.png dirlink)
cleanup() {
  [[ -n $PID ]] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true; }
  for f in "${FILES[@]}"; do rm -f -- "$D/$f"; done
  rmdir "$D/sub" 2>/dev/null || true
  rmdir "$D" 2>/dev/null || true
  rm -rf -- "$T"
}
trap cleanup EXIT
unset HERDMASTER_PROJECT
export HOME="$T"
mkdir -p "$T/.claude/orchestrator/demo/review/Secrets" "$T/.claude/orchestrator/demo/review/ſecrets" "$T/.claude/orchestrator/demo/review/SECRETS" "$T/.claude/orchestrator/demo/review/secrets" "$T/.claude/secrets" "$T/.claude/paste-cache" "$T/.claude/memory" "$D/sub"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
fail() { echo "FAIL: $*" >&2; exit 1; }
B="http://127.0.0.1:$PORT"
get() { curl -s --path-as-is -o /dev/null -w '%{http_code}' "$B/file?path=$1"; }
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

python3 "$V" --project demo --port "$PORT" >"$T/out" 2>&1 &
PID=$!
for _ in $(seq 50); do curl -s "$B/" >/dev/null 2>&1 && break; sleep 0.1; done

printf '\x89PNG\r\n\x1a\nfake' > "$D/shot.png"
cp "$D/shot.png" "$D/UPPER.PNG"
printf 'hello diff\n' > "$D/note.txt"
printf '{"a":1}' > "$D/data.json"
head -c 10485761 /dev/zero > "$D/big.png"
printf 'x' > "$D/run.exe"
printf 'top secret' > "$T/outside.png"
ln -s "$T/outside.png" "$D/sneaky.png"
ln -s "$T" "$D/dirlink"
O="$T/.claude/orchestrator/demo/review"
printf 'k' > "$T/.claude/secrets/gmail.txt"
printf 'k' > "$T/.claude/.hidden.txt"
printf 'ok' > "$T/.claude/plain.txt"
printf '{}' > "$T/.claude/settings.json"
printf 'p' > "$T/.claude/paste-cache/a.txt"
printf 'm' > "$T/.claude/memory/m.md"
printf '{}' > "$T/.claude/orchestrator/demo/tasks.json"
printf 'k' > "$O/secrets/a.txt"; printf 'k' > "$O/SECRETS/a.txt"; printf 'k' > "$O/Secrets/a.txt"; printf 'k' > "$O/ſecrets/a.txt"
printf 'k' > "$O/.dot.txt"
printf 'shot' > "$O/ok.png"
printf 'x' > "$T/.claude/orchestrator/demo/loose.txt"
printf 'x' > "$D/sub/.dot.txt"

hdr=$(curl -s -D - -o "$T/body" "$B/file?path=$(enc "$D/shot.png")")
grep -qi '^HTTP/1.0 200\|^HTTP/1.1 200' <<<"$hdr" || fail "png 200"
grep -qi '^content-type: image/png' <<<"$hdr" || fail "png type"
grep -qi '^x-content-type-options: nosniff' <<<"$hdr" || fail "nosniff"
grep -qi '^content-disposition: inline' <<<"$hdr" || fail "png inline"
cmp -s "$T/body" "$D/shot.png" || fail "png body"
[[ $(get "$(enc "$D/UPPER.PNG")") == 200 ]] || fail "uppercase ext"

hdr=$(curl -s -D - -o "$T/body" "$B/file?path=$(enc "$D/note.txt")")
grep -qi '^content-type: text/plain' <<<"$hdr" || fail "txt type"
grep -qi '^content-disposition: attachment' <<<"$hdr" || fail "txt not inline"
grep -qi '^x-content-type-options: nosniff' <<<"$hdr" || fail "txt nosniff"
[[ $(cat "$T/body") == "hello diff" ]] || fail "txt body"
hdr=$(curl -s -D - -o /dev/null "$B/file?path=$(enc "$D/data.json")")
grep -qi '^HTTP/1.[01] 415' <<<"$hdr" || fail "json not allowed"
[[ $(get "$(enc "$O/ok.png")") == 200 ]] || fail "file under orchestrator/<project>/review"
[[ $(get "$(enc "$T/.claude/plain.txt")") == 403 ]] || fail "plain ~/.claude file"
[[ $(get "$(enc "$T/.claude/settings.json")") == 403 ]] || fail "settings.json"
[[ $(get "$(enc "$T/.claude/paste-cache/a.txt")") == 403 ]] || fail "paste-cache"
[[ $(get "$(enc "$T/.claude/memory/m.md")") == 403 ]] || fail "memory"
[[ $(get "$(enc "$T/.claude/orchestrator/demo/loose.txt")") == 403 ]] || fail "project file outside review/"
for n in secrets SECRETS Secrets ſecrets; do
  [[ $(get "$(enc "$O/$n/a.txt")") == 403 ]] || fail "deny name $n"
done
[[ $(get "$(enc "$O/.dot.txt")") == 403 ]] || fail "dotfile in review"

[[ $(get "$(enc "$D/../../etc/passwd")") == 400 ]] || fail "dotdot"
[[ $(get "$(enc "$D")%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd") == 400 ]] || fail "encoded dotdot"
[[ $(get "%2e%2e%2f%2e%2e%2fetc%2fpasswd") == 400 ]] || fail "relative encoded dotdot"
[[ $(get "$(enc "$D")/%2E%2E/%2E%2E/etc/passwd") == 400 ]] || fail "encoded dotdot upper"
[[ $(get "$D/../x.png") == 400 ]] || fail "raw dotdot"
[[ $(get "$(enc "$D")%252e%252e%252fx.png") =~ ^(400|404)$ ]] || fail "double-encoded dotdot"
[[ $(get "$(enc "$D/shot.png")%00.txt") == 400 ]] || fail "NUL byte"
[[ $(get "shot.png") == 400 ]] || fail "relative path"
[[ $(get "") == 400 ]] || fail "empty path"
[[ $(curl -s -o /dev/null -w '%{http_code}' "$B/file") == 400 ]] || fail "missing path"
[[ $(curl -s -o /dev/null -w '%{http_code}' "$B/file?path=$(enc "$D/shot.png")&path=$(enc "$D/note.txt")") == 400 ]] || fail "two paths"
[[ $(get "$(enc "$D")//shot.png") == 400 ]] || fail "double slash"
[[ $(get "$(enc "$D")/./shot.png") == 400 ]] || fail "dot segment"
[[ $(get "$(enc /etc/passwd)") == 403 ]] || fail "outside roots"
[[ $(get "$(enc "$T/outside.png")") == 403 ]] || fail "temp home outside roots"
[[ $(get "$(enc /private/tmp/claude-501-evil/x.png)") == 403 ]] || fail "prefix sibling of root"
[[ $(get "$(enc "$D/sneaky.png")") == 403 ]] || fail "symlink escape"
[[ $(get "$(enc "$D/dirlink/outside.png")") == 403 ]] || fail "directory symlink escape"
[[ $(get "$(enc "$T/.claude/.hidden.txt")") == 403 ]] || fail "dotfile in root"
[[ $(get "$(enc "$D/sub/.dot.txt")") == 403 ]] || fail "dotfile in subdir"
[[ $(get "$(enc "$T/.claude/secrets/gmail.txt")") == 403 ]] || fail "secrets dir"
[[ $(get "$(enc "$D/sub")") == 415 ]] || fail "directory (no listing)"
[[ $(get "$(enc "$D")") == 415 ]] || fail "root directory"
mkdir -p "$D/sub/pic.png"
[[ $(get "$(enc "$D/sub/pic.png")") == 400 ]] || fail "directory named like an image"
rmdir "$D/sub/pic.png"
[[ $(get "$(enc "$D/run.exe")") == 415 ]] || fail "disallowed ext"
[[ $(get "$(enc "$D/big.png")") == 413 ]] || fail "oversize"
[[ $(get "$(enc "$D/missing.png")") == 404 ]] || fail "missing file"
[[ $(curl -s -X POST -o /dev/null -w '%{http_code}' "$B/file?path=$(enc "$D/shot.png")") == 405 ]] || fail "POST 405"
[[ $(curl -s -I -o /dev/null -w '%{http_code}' "$B/file?path=$(enc "$D/shot.png")") == 405 ]] || fail "HEAD 405"
[[ $(curl -s -X PUT -o /dev/null -w '%{http_code}' "$B/file?path=$(enc "$D/shot.png")") == 405 ]] || fail "PUT 405"

sec() { curl -s -o /dev/null -w '%{http_code}' -H "Sec-Fetch-Site: $1" "$B/file?path=$(enc "$D/shot.png")"; }
[[ $(sec cross-site) == 403 ]] || fail "cross-site"
[[ $(sec same-site) == 403 ]] || fail "same-site"
[[ $(sec cross-origin) == 403 ]] || fail "unknown site value"
[[ $(sec same-origin) == 200 ]] || fail "same-origin"
[[ $(sec none) == 200 ]] || fail "none"

for r in "/" "/all.json" "/tasks.json" "/settings.json" "/projects.json" "/focus.json" "/project" "/file?path=$(enc "$D/shot.png")"; do
  [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example" "$B$r") == 421 ]] || fail "evil host $r"
  [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Host: evil.example:$PORT" "$B$r") == 421 ]] || fail "evil host with port $r"
  [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1" "$B$r") == 421 ]] || fail "portless host $r"
  [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Host: localhost:$PORT" "$B$r") != 421 ]] || fail "localhost host $r"
  [[ $(curl -s -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1:$PORT" "$B$r") != 421 ]] || fail "good host $r"
done
[[ $(curl -s -H "Host: evil.example" "$B/all.json") != *demo* ]] || fail "board leaked to evil host"

python3 - "$PORT" <<'PY' || fail "idle socket blocked the server"
import socket, sys, time, urllib.request
port = int(sys.argv[1])
idle = socket.create_connection(("127.0.0.1", port))
t = time.monotonic()
urllib.request.urlopen("http://127.0.0.1:%d/project" % port, timeout=15).read()
if time.monotonic() - t > 8:
    sys.exit(1)
idle.close()
PY

page=$(curl -s "$B/")
hdr=$(curl -s -D - -o /dev/null "$B/")
grep -qi "^content-security-policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" <<<"$hdr" || fail "page CSP"
grep -qi '^x-content-type-options: nosniff' <<<"$hdr" || fail "page nosniff"
hdr=$(curl -s -D - -o /dev/null "$B/all.json")
grep -qi '^x-content-type-options: nosniff' <<<"$hdr" || fail "json nosniff"
grep -q '<script>' <<<"$page" || fail "page script present"
grep -q 'innerHTML\|insertAdjacentHTML\|outerHTML\|document.write' <<<"$page" && fail "page must not use HTML injection APIs"
grep -q 'rel="noopener noreferrer"\|a.rel="noopener noreferrer"' <<<"$page" || fail "noopener"
grep -q 'a.target="_blank"' <<<"$page" || fail "target blank"
grep -q '"/file?path="+encodeURIComponent' <<<"$page" || fail "thumbnail url"
grep -q 'e.status==="in review"' <<<"$page" || fail "review row only for in review"

printf '%s\n' "$page" | python3 -c '
import re, sys
js = sys.stdin.read()
m = re.search(r"const URL_RE.*?\nfunction anchor", js, re.S)
open(sys.argv[1], "w").write(m.group(0).rsplit("function anchor", 1)[0])
' "$T/linkify.js"
cat > "$T/linkify.check.js" <<'JS'
const fs = require("fs");
const $ = () => { throw new Error("no DOM in linkParts") };
eval(fs.readFileSync(process.argv[2], "utf8") + ";globalThis.linkParts=linkParts;globalThis.safeUrl=safeUrl");
const eq = (a, b, m) => { if (JSON.stringify(a) !== JSON.stringify(b)) { console.error("FAIL", m, JSON.stringify(a)); process.exit(1) } };
eq(linkParts("see https://example.com/a?b=1, ok"), [{ t: "see " }, { t: "https://example.com/a?b=1", href: "https://example.com/a?b=1" }, { t: ", ok" }], "trailing comma");
eq(linkParts("(http://localhost:8000/x).").filter(p => p.href).map(p => p.t), ["http://localhost:8000/x"], "paren and dot");
eq(linkParts("javascript:alert(1) data:text/html,x file:///etc/passwd ftp://h/x").some(p => p.href), false, "only http(s)");
eq(linkParts("<script>alert(1)</script>"), [{ t: "<script>alert(1)</script>" }], "markup stays text");
eq(linkParts("x http://a.b/\"onmouseover=1").filter(p => p.href).map(p => p.href), ["http://a.b/"], "quote ends url");
eq(linkParts("no links"), [{ t: "no links" }], "plain");
eq(linkParts("").length, 0, "empty");
eq(safeUrl("javascript:alert(1)"), null, "js scheme");
eq(safeUrl("HTTPS://Example.com"), "https://example.com/", "normalised");
eq(safeUrl(5), null, "non-string");
JS
node "$T/linkify.check.js" "$T/linkify.js" || fail "linkify checks"
echo ok
