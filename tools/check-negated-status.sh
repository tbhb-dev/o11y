#!/usr/bin/env bash
# Fails when a script in tools/*.sh negates grep -q or cmp -s with `!`.
# Both read their own failure as an answer once negated: a grep that can't
# read its file reports no match, and a cmp that can't compare reports a
# difference. grep -q also stops at its first match, so under pipefail a
# command feeding it gets SIGPIPE and the negation turns that into a pass.
# Use lacks or files_differ from tools/lib.sh, or capture the status and
# tell its values apart. A negation that fails safe, where any failure
# also fails the check, takes a comment on the line before:
#
#   # lint-negated: allow <reason>
#
#   tools/check-negated-status.sh [file...]   (default: tools/*.sh)
#
# It reads lines, not shell words, so it only sees a negation that starts a
# command on the line, after a keyword such as if or elif or a separator.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- tools/*.sh
fi
awk '
  FNR == 1 { allow = 0 }
  {
    code = $0
    sub(/^[ \t]*#.*/, "", code)
    if (code ~ /(^|[;&|({]|(^|[ \t])(then|do|else|if|elif|while|until))[ \t]*![ \t]+[^#]*(grep([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*q|cmp[ \t]+-s)/ && !allow) {
      printf "%s:%d: a negated grep -q or cmp -s reads its own failure as an answer; use lacks or files_differ, or put # lint-negated: allow <reason> on the line before\n", FILENAME, FNR
      bad = 1
    }
    allow = $0 ~ /^[ \t]*# lint-negated: allow [^ \t]/
  }
  END { exit bad }' "$@"
