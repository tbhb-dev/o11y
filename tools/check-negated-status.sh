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
# What it handles, and nothing broader:
#
# - It reads the syntax tree shfmt builds, so quoting, continued lines and
#   a pipeline split across lines don't hide a negation. A file shfmt
#   can't parse fails.
# - A statement negated with ! fails when its status can come from a quiet
#   grep or cmp: any stage of its pipeline, and the last statement inside
#   ( ) or { }, nested or not, including either side of && or || there.
# - It reads each literal word as the shell does, with quotes and the
#   backslash escapes of unquoted text removed, so \grep is grep.
# - The command is grep, egrep, fgrep or cmp, named by a literal word or a
#   literal path to one.
# - Before the command it skips, by name or by path, a leading command or
#   builtin and the words after it that start with -, a leading exec with
#   its options and the name after -a, and a leading env with:
#   the words that start with -; the word after -u, -C, -S, --unset,
#   --chdir and --split-string; a --; and NAME=value words, with the name
#   read from the literal text before any expansion, across unquoted,
#   single-quoted and double-quoted parts.
# - Quiet means a literal option word before -- that is a short cluster
#   holding q (s for cmp), or --quiet, --silent or any prefix of either
#   down to --q and --s. It skips the word after grep's -e, -f, --regexp and --file and
#   after cmp's -i, -n, --ignore-initial and --bytes, also when the option
#   ends a short cluster.
# - A "# lint-negated: allow <reason>" comment on the line right above a
#   statement covers only the first flagged statement on that line.
#
# Out of scope, so a negation behind them passes: other wrappers such as
# sudo, timeout and xargs; env options outside the list above, including
# ones that take a separate argument; a wrapper, command name or quiet
# option that is itself an expansion; a negated if, case, while, until or
# for; a function that runs grep or cmp; eval and sh -c; and commands
# inside a string that runs elsewhere, such as the remote commands
# tools/nas.sh builds.
# cspell:ignore chdir egrep fgrep endswith getopt gsub subshell Subshell Stmts
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- tools/*.sh
fi

# The line of every negated statement whose status can come from a quiet
# grep or cmp, once per statement, sorted.
negations() {
  shfmt --to-json <"$1" | jq -r '
    # An unquoted literal with its backslash escapes removed, as the shell
    # reads it.
    def unescape: gsub("\\\\(?<c>.)"; .c);
    # A word with no expansion in it, quotes and escapes removed; null
    # otherwise.
    def word:
      [.Parts[] |
        if .Type == "Lit" then .Value | unescape
        elif .Type == "SglQuoted" then .Value
        elif .Type == "DblQuoted" then
          (if all(.Parts[]?; .Type == "Lit") then ([.Parts[]?.Value] | join("")) else null end)
        else null end] |
      if any(. == null) then null else join("") end;
    # The literal text a word starts with, up to its first expansion,
    # through plain, single-quoted and double-quoted parts alike.
    def lead:
      reduce .Parts[] as $p ({text: "", open: true};
        if (.open | not) then .
        elif $p.Type == "Lit" then .text += ($p.Value | unescape)
        elif $p.Type == "SglQuoted" then .text += $p.Value
        elif $p.Type == "DblQuoted" then
          reduce ($p.Parts // [])[] as $q (.;
            if .open and $q.Type == "Lit" then .text += $q.Value else .open = false end)
        else .open = false end) | .text;
    # A wrapper word, by its name or a path to it.
    def named($n): . != null and (split("/") | last) == $n;
    # The command that runs, as [word, lead] pairs, past command, builtin
    # and exec, and past env with its options, the arguments of -u, -C and
    # -S and their long forms, -- and NAME=value assignments, whose value
    # may hold an expansion.
    def unwrap:
      def skip_flags: until(length == 0 or ((.[0][1] // "") | startswith("-") | not); .[1:]);
      if length == 0 then .
      elif (.[0][0] | named("command")) or (.[0][0] | named("builtin")) then (.[1:] | skip_flags | unwrap)
      elif .[0][0] | named("exec") then
        (.[1:] | until(length == 0 or ((.[0][1] // "") | startswith("-") | not); if .[0][0] == "-a" then .[2:] else .[1:] end) | unwrap)
      elif .[0][0] | named("env") then
        (.[1:] | until(length == 0 or ((.[0][1] | startswith("-")) or (.[0][1] | test("^[A-Za-z_][A-Za-z0-9_]*=")) | not);
          if (.[0][0] // "") | test("^(-u|-C|-S|--unset|--chdir|--split-string)$") then .[2:]
          elif .[0][0] == "--" then .[1:] | until(length == 0 or (.[0][1] | test("^[A-Za-z_][A-Za-z0-9_]*=") | not); .[1:])
          else .[1:] end) | unwrap)
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
    # getopt takes any unambiguous prefix of a long option, and no other
    # long option of grep or cmp starts with q or s.
    def quiet_long: any(.[]; test("^--(q(u(i(e(t)?)?)?)?|s(i(l(e(n(t)?)?)?)?)?)$"));
    def quiet:
      ([.Args[] | [word, lead]] | unwrap | map(.[0])) as $w |
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
      unique | .[] | .[0]'
}

failed=0
for file; do
  lines=$(negations "$file") || {
    echo "$file: shfmt could not parse it, so its negations could not be checked"
    failed=1
    continue
  }
  [[ -n $lines ]] || continue
  # An allow comment covers only the first flagged statement on its line.
  # The loop splits the list of numbers itself: Bash 3.2 writes a
  # here-string to a temp file, and when it can't, it skips the loop and
  # the check passes.
  allowed=
  for line in $lines; do
    if [[ $allowed != "$line" ]] && ((line > 1)) &&
      sed -n "$((line - 1))p" "$file" | grep -Eq '^[[:space:]]*# lint-negated: allow [^[:space:]]'; then
      allowed=$line
      continue
    fi
    allowed=$line
    echo "$file:$line: a negated grep -q or cmp -s reads its own failure as an answer; use lacks or files_differ, or put # lint-negated: allow <reason> on the line before"
    failed=1
  done
done
exit "$failed"
