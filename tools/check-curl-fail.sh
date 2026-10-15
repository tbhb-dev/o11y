#!/usr/bin/env bash
# Fails when a curl in tools/*.sh hands its body to something that reads
# it, through a pipe or a command substitution, without --fail. Without it
# an HTTP error is a successful transfer, and the error page reaches the
# reader as if it were the answer. A curl that prints its status code
# through -w '%{http_code}' leaves the status to its caller, which compares
# it, so it passes.
#
#   tools/check-curl-fail.sh [file...]   (default: tools/*.sh)
#
# A justified exception carries `# lint-curl: allow <reason>` on the line
# before the command.
#
# It reads lines, not shell. Lines ending in a backslash or a pipe join the
# next. It sees a curl only where the word is written, so not through a
# wrapper such as receipt.sh's http, and it can't tell what a command string
# that runs elsewhere will do with a curl inside it.
# cspell:ignore RSTART
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- tools/*.sh
fi

awk '
  function check(text, line, allowed,    rest, before, seg, after, at, consumed) {
    if (allowed) return
    rest = text
    while (match(rest, /(^|[^A-Za-z0-9_.-])curl([ \t]|$)/)) {
      at = RSTART + (substr(rest, RSTART, 4) == "curl" ? 0 : 1)
      before = before substr(rest, 1, at - 1) "curl"
      rest = substr(rest, at + 4)
      seg = rest
      if (match(seg, /[|);&]/)) seg = substr(seg, 1, RSTART - 1)
      after = substr(rest, length(seg) + 1)
      consumed = (after ~ /^\|([^|]|$)/) || (before ~ /\$\([^)]*$/)
      if (!consumed) continue
      if (seg ~ /(^|[ \t])(--fail|--fail-with-body|-[A-Za-z]*f[A-Za-z]*)([ \t=]|$)/) continue
      if (seg ~ /%\{http_code\}/) continue
      printf "%s:%d: curl output is read without --fail; add -f, or check -w %%{http_code}, or mark it with # lint-curl: allow <reason>\n", FILENAME, line
      bad = 1
    }
  }
  FNR == 1 { text = ""; allow_next = 0 }
  {
    if (text == "") {
      start = FNR
      allowed = allow_next
      allow_next = 0
      if ($0 ~ /^[ \t]*#/) {
        if ($0 ~ /^[ \t]*# lint-curl: allow [^ \t]/) allow_next = 1
        next
      }
    }
    line = $0
    sub(/[ \t]+$/, "", line)
    if (line ~ /\\$/) { text = text substr(line, 1, length(line) - 1) " "; next }
    if (line ~ /[^|]\|$/) { text = text line " "; next }
    check(text line, start, allowed)
    text = ""
  }
  END { exit bad }
' "$@"
