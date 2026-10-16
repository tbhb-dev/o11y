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
# statement fails when a command its status can come from is a quiet grep
# or cmp: every stage of a pipeline, since under pipefail any stage decides
# its status, either side of && or ||, and the last statement of a
# subshell or braces. It reads the command name past a leading command,
# builtin or exec, and past env with its options and assignments, and it
# skips the argument of grep's -e, -f, --regexp and --file and of cmp's -i
# and -n before it takes -- as the end of options. A file shfmt can't parse
# fails too. An allow comment covers only the first such statement on the
# line below it.
#
# Out of scope, so a negation behind them passes: other wrappers such as
# sudo, timeout and xargs, a function that runs grep or cmp, a command name
# held in a variable, eval, sh -c, and commands inside a string that runs
# elsewhere, such as the remote commands tools/nas.sh builds.
# cspell:ignore egrep fgrep endswith getopt subshell Subshell Stmts
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- tools/*.sh
fi

# The line and column of every negated statement whose status can come
# from a quiet grep or cmp, one "line col" pair per line.
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
    # The words from the command that runs, past command, builtin or exec
    # and past env with its options and NAME=value assignments.
    def unwrap:
      if length == 0 then .
      elif .[0] == "command" or .[0] == "builtin" then (.[1:] | until(length == 0 or ((.[0] // "") | startswith("-") | not); .[1:]) | unwrap)
      elif .[0] == "exec" then (.[1:] | until(length == 0 or ((.[0] // "") | startswith("-") | not); if .[0] == "-a" then .[2:] else .[1:] end) | unwrap)
      elif .[0] == "env" then
        (.[1:] | until(length == 0 or (((.[0] // "") | startswith("-")) or ((.[0] // "") | test("^[A-Za-z_][A-Za-z0-9_]*=")) | not);
          if .[0] == "-u" or .[0] == "-C" or .[0] == "-S" then .[2:] else .[1:] end) | unwrap)
      else . end;
    # The option words of a command, up to --, without the arguments that
    # options in $takes consume. GNU grep takes options after operands
    # too, so position does not matter.
    def flags($takes):
      reduce .[] as $w ({out: [], skip: false, done: false};
        if .done then .
        elif .skip then .skip = false
        elif $w == null then .
        elif $w == "--" then .done = true
        elif ($takes | index($w)) != null then .skip = true
        elif ($w | test("^-[A-Za-z]+$")) and ($takes | any(. as $t | ($t | length) == 2 and ($w | endswith($t[1:2])))) then .out += [$w] | .skip = true
        else .out += [$w] end) | .out;
    def short($c): any(.[]; test("^-[A-Za-z]*" + $c));
    # getopt takes any unambiguous prefix of a long option.
    def quiet_long: any(.[]; test("^--(qu?i?e?t?|sil?e?n?t?)$") and (. == "--q" or test("^--(qu|si)")));
    def quiet:
      ([.Args[] | word] | unwrap) as $w |
      (($w[0] // "") | split("/") | last) as $name |
      if ($name == "grep" or $name == "egrep" or $name == "fgrep") then
        ($w[1:] | flags(["-e", "-f", "--regexp", "--file"]) | short("q") or quiet_long)
      elif $name == "cmp" then
        ($w[1:] | flags(["-i", "-n", "--ignore-initial", "--bytes"]) | short("s") or quiet_long)
      else false end;
    # The commands whose exit status a statement can take.
    def lasts:
      .Cmd as $c |
      if $c == null then empty
      elif $c.Type == "BinaryCmd" then (($c.X | lasts), ($c.Y | lasts))
      elif $c.Type == "Subshell" or $c.Type == "Block" then ($c.Stmts[-1] | lasts)
      else $c end;
    [.. | objects | select(.Negated == true and has("Position"))] |
      map(select(any(lasts; .Type == "CallExpr" and (.Args | length) > 0 and quiet)) | [.Position.Line, .Position.Col]) |
      unique | .[] | "\(.[0]) \(.[1])"'
}

failed=0
for file; do
  lines=$(negations "$file") || {
    echo "$file: shfmt could not parse it, so its negations could not be checked"
    failed=1
    continue
  }
  [[ -n $lines ]] || continue
  # An allow comment covers only the first flagged statement on its line;
  # the list is sorted by line, then column.
  allowed=
  while read -r line _; do
    if [[ $allowed != "$line" ]] && ((line > 1)) &&
      sed -n "$((line - 1))p" "$file" | grep -Eq '^[[:space:]]*# lint-negated: allow [^[:space:]]'; then
      allowed=$line
      continue
    fi
    allowed=$line
    echo "$file:$line: a negated grep -q or cmp -s reads its own failure as an answer; use lacks or files_differ, or put # lint-negated: allow <reason> on the line before"
    failed=1
  done <<<"$lines"
done
exit "$failed"
