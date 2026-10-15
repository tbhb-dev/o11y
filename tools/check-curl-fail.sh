#!/usr/bin/env bash
# Fails when a curl in tools/*.sh runs without a fail option. Without one,
# an HTTP error is a successful transfer, and whatever reads the body, or
# the file it was written to, gets the error page as if it were the answer.
# Every curl needs -f, --fail or --fail-with-body as an argument of its own,
# quoted or not. A curl that has a reason to go without one, such as one
# whose -w '%{http_code}' its caller compares, takes a comment on the line
# before:
#
#   # lint-curl: allow <reason>
#
#   tools/check-curl-fail.sh [file...]   (default: tools/*.sh)
#
# It splits words the way the shell does, closely enough for this: quotes,
# backslashes, continued lines, $( ) and comments. It can't see a curl
# behind a wrapper such as receipt.sh's http, or one inside a quoted string
# that runs elsewhere, such as the remote commands tools/nas.sh builds.
# cspell:ignore hdword hdstrip hdnext incurl gsub RSTART RLENGTH
set -euo pipefail

if [[ $# -eq 0 ]]; then
  set -- tools/*.sh
fi

awk '
  function reset_depth(d) {
    q[d] = ""; tok[d] = ""; has[d] = 0; par[d] = 0
    incurl[d] = 0; fail[d] = 0; cline[d] = 0; allow[d] = 0; words[d] = 0
  }
  function end_word(    v) {
    if (!has[sp]) return
    v = tok[sp]
    tok[sp] = ""; has[sp] = 0
    words[sp]++
    if (incurl[sp]) {
      if (v == "--fail" || v == "--fail-with-body" || v ~ /^-[A-Za-z]*f[A-Za-z]*$/) fail[sp] = 1
    } else if (v == "curl") {
      incurl[sp] = 1; fail[sp] = 0; cline[sp] = FNR; allow[sp] = pending; pending = 0
    }
  }
  function end_command() {
    end_word()
    if (incurl[sp] && !fail[sp] && !allow[sp]) {
      printf "%s:%d: curl without a fail option; add -f, or put # lint-curl: allow <reason> on the line before\n", FILENAME, cline[sp]
      bad = 1
    }
    if (words[sp] > 0 && !incurl[sp]) pending = 0
    incurl[sp] = 0; fail[sp] = 0; words[sp] = 0
  }
  # arith(): the $(( )) that starts at i, whole, so its parentheses end nothing.
  function arith(    j, d, ch) {
    j = i + 3; d = 2
    while (j <= n && d > 0) {
      ch = substr(line, j, 1)
      if (ch == "(") d++
      else if (ch == ")") d--
      j++
    }
    tok[sp] = tok[sp] substr(line, i, j - i); has[sp] = 1
    i = j - 1
  }
  function push() { sp++; reset_depth(sp); has[sp - 1] = 1 }
  function pop() { end_command(); sp--; has[sp] = 1 }
  FNR == 1 { sp = 0; reset_depth(0); pending = 0; hdword = ""; hdnext = "" }
  {
    line = $0
    if (hdword != "") {
      t = line
      if (hdstrip) sub(/^\t+/, "", t)
      if (t == hdword) hdword = ""
      next
    }
    cont = 0
    n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (q[sp] == "\047") {
        if (c == "\047") q[sp] = ""; else tok[sp] = tok[sp] c
        continue
      }
      if (q[sp] == "\"") {
        if (c == "\\") { tok[sp] = tok[sp] substr(line, i + 1, 1); i++ }
        else if (c == "\"") q[sp] = ""
        else if (c == "$" && substr(line, i + 1, 2) == "((") arith()
        else if (c == "$" && substr(line, i + 1, 1) == "(") { push(); i++ }
        else tok[sp] = tok[sp] c
        continue
      }
      if (c == "\\") {
        if (i == n) cont = 1; else { tok[sp] = tok[sp] substr(line, i + 1, 1); has[sp] = 1; i++ }
        continue
      }
      if (c == "\047" || c == "\"") { q[sp] = c; has[sp] = 1; continue }
      if (c == "#" && !has[sp]) {
        if (substr(line, i) ~ /^#[ \t]*lint-curl: allow[ \t]+[^ \t]/) pending = 1
        break
      }
      if (c == " " || c == "\t") { end_word(); continue }
      if (c == "$" && substr(line, i + 1, 2) == "((") { arith(); continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") { push(); i++; continue }
      if (c == "(") { par[sp]++; end_command(); continue }
      if (c == ")") {
        if (par[sp] > 0) { par[sp]--; end_command() }
        else if (sp > 0) pop()
        else end_command()
        continue
      }
      if (c == "|" || c == ";" || c == "&") { end_command(); continue }
      if (c == "<" && substr(line, i, 3) == "<<<") { end_word(); i += 2; continue }
      if (c == "<" && substr(line, i, 2) == "<<") {
        end_word()
        rest = substr(line, i + 2)
        hdstrip = (substr(rest, 1, 1) == "-")
        if (hdstrip) rest = substr(rest, 2)
        if (match(rest, /^[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
          w = substr(rest, RSTART, RLENGTH)
          gsub(/^[ \t]*["\047]?/, "", w)
          hdnext = w
          i += 1 + hdstrip + RLENGTH
          if (substr(line, i + 1, 1) == "\"" || substr(line, i + 1, 1) == "\047") i++
        } else i++
        continue
      }
      if (c == "<" || c == ">") {
        end_word()
        if (substr(line, i + 1, 1) == "&") i++
        continue
      }
      tok[sp] = tok[sp] c; has[sp] = 1
    }
    if (q[sp] != "") tok[sp] = tok[sp] "\n"
    else if (!cont) end_command()
    if (hdnext != "") { hdword = hdnext; hdnext = "" }
  }
  END { while (sp > 0) pop(); end_command(); exit bad }
' "$@"
