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
# It reads the syntax tree shfmt builds, not lines, so quoting, continued
# lines and a pipeline split across lines don't hide a negation. A negated
# statement fails when the command whose status it negates is a quiet grep
# or cmp: the last stage of a pipeline, either side of && or ||, and the
# last statement of a subshell or braces. A file shfmt can't parse fails
# too. It can't see a command inside a string that runs elsewhere, such as
# the remote commands tools/nas.sh builds.
# cspell:ignore egrep fgrep getopt subshell Subshell Stmts
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- tools/*.sh
fi

# The line of every negated statement whose status comes from a quiet grep
# or cmp, one per line.
negations() {
  shfmt --to-json <"$1" | jq -r '
    # A word with no expansion in it, quotes removed; null otherwise.
    def word:
      [.Parts[] |
        if .Type == "Lit" or .Type == "SglQuoted" then .Value
        elif .Type == "DblQuoted" then
          (if all(.Parts[]?; .Type == "Lit") then ([.Parts[]?.Value] | join("")) else null end)
        else null end] |
      if any(. == null) then null else join("") end;
    # Every literal word after the command name and before --. GNU grep
    # takes options after operands too, so position does not matter.
    def flags: [.[1:][] | word] | (index("--") // length) as $end | .[:$end] | map(select(. != null));
    def short($c): any(.[]; test("^-[A-Za-z]*" + $c));
    # getopt takes any unambiguous prefix of a long option.
    def quiet_long: any(.[]; test("^--(qu?i?e?t?|sil?e?n?t?)$") and (. == "--q" or test("^--(qu|si)")));
    def quiet:
      (.Args[0] | word // "" | split("/") | last) as $name |
      (.Args | flags) as $f |
      if ($name == "grep" or $name == "egrep" or $name == "fgrep") then
        ($f | short("q") or quiet_long)
      elif $name == "cmp" then
        ($f | short("s") or quiet_long)
      else false end;
    # The commands whose exit status a statement takes.
    def lasts:
      .Cmd as $c |
      if $c == null then empty
      # shfmt 3.14 names the operator; older releases number it.
      elif $c.Type == "BinaryCmd" and ($c.Op == "|" or $c.Op == "|&" or $c.Op == 13 or $c.Op == 14) then ($c.Y | lasts)
      elif $c.Type == "BinaryCmd" then (($c.X | lasts), ($c.Y | lasts))
      elif $c.Type == "Subshell" or $c.Type == "Block" then ($c.Stmts[-1] | lasts)
      else $c end;
    [.. | objects | select(.Negated == true and has("Position"))] |
      map(select(any(lasts; .Type == "CallExpr" and (.Args | length) > 0 and quiet)) | .Position.Line) |
      unique | .[]'
}

failed=0
for file; do
  lines=$(negations "$file") || {
    echo "$file: shfmt could not parse it, so its negations could not be checked"
    failed=1
    continue
  }
  [[ -n $lines ]] || continue
  while IFS= read -r line; do
    # The allow comment sits on the line right before the statement.
    if ((line > 1)) && sed -n "$((line - 1))p" "$file" | grep -Eq '^[[:space:]]*# lint-negated: allow [^[:space:]]'; then
      continue
    fi
    echo "$file:$line: a negated grep -q or cmp -s reads its own failure as an answer; use lacks or files_differ, or put # lint-negated: allow <reason> on the line before"
    failed=1
  done <<<"$lines"
done
exit "$failed"
