#!/usr/bin/env bats
# tools/check-negated-status.sh on small scripts: a negated grep -q or
# cmp -s fails unless an allow comment with a reason is on the line before.
# cspell:ignore chdir egrep fgrep subshell quie

setup() {
  dir=$(mktemp -d)
  check="$BATS_TEST_DIRNAME/check-negated-status.sh"
}

teardown() {
  rm -rf "$dir"
}

# script <lines...>: writes the lines to $dir/t.sh.
script() {
  printf '%s\n' '#!/usr/bin/env bash' "$@" >"$dir/t.sh"
}

@test "a negated grep -q at the start of a line fails and names the line" {
  script 'x=1' '! grep -q pattern file || die "found"'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:3: a negated grep -q or cmp -s"* ]]
}

@test "a negated pipeline ending in grep with -q among other flags fails" {
  script '! tr -d x <<<"$log" | grep -iqE "a|b" || die'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a negated cmp -s fails" {
  script '! cmp -s a b || die "same"'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a negation after if, elif or a separator fails" {
  script 'if ! grep -q a f; then :; fi' 'x && ! grep -q a f'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'a negated grep' <<<"$output")" -eq 2 ]
}

@test "an allow comment with a reason on the line before passes" {
  script '# lint-negated: allow a failed search fails the check too' 'if ! grep -q a f; then exit 1; fi'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "an allow comment without a reason does not count" {
  script '# lint-negated: allow' '! grep -q a f'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "lacks, files_differ, a test negation and a comment pass" {
  script 'lacks -q a <<<"$x" || die' 'files_differ a b' '[[ ! -e f ]] || die' '# ! grep -q a f'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "the repository's own scripts pass" {
  cd "$BATS_TEST_DIRNAME/.."
  run bash "$check"
  [ "$status" -eq 0 ]
}

# The four shapes a line-based check missed.

@test "a negated pipeline split after its pipe fails" {
  script '! printf "%s\n" "$log" |' '  grep -q dump || die'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:2: a negated"* ]]
}

@test "a grep continued with a backslash before -q fails" {
  script '! grep -i \' '  -q dump file || die'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a multiline negated subshell whose last command is a quiet grep fails" {
  script '! (' '  cd /tmp' '  grep -q dump file' ') || die'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a quoted hash before the grep doesn't hide it" {
  script '! printf "%s\n" "# x" | grep -q x || die'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "long, abbreviated and clustered quiet flags, a path to grep and cmp --silent fail" {
  local line
  for line in '! grep --quiet a f' '! grep --qui a f' '! grep --sil a f' '! grep -iqE a f' '! /usr/bin/grep -q a f' '! grep a f -q' '! cmp --silent a b' '! cmp --quie a b' '! { x; cmp -s a b; }'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "a quiet grep at any pipeline stage fails, and a pattern after -- or a plain grep passes" {
  script '! grep -q a f | wc -l' '! cmp -s a b && true' '! grep -- -q f' 'grep -q a f || die'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'a negated' <<<"$output")" -eq 2 ]
  [[ $output == *"$dir/t.sh:2: a negated"* && $output == *"$dir/t.sh:3: a negated"* ]]
}

# Codex's third-round reproductions.

@test "a quiet grep behind command, builtin, exec or env fails" {
  local line
  for line in '! command grep -q x missing' '! command -p grep -q x f' '! env LC_ALL=C grep -q x missing' \
    '! env -i -u HOME LC_ALL=C grep -q x f' '! exec grep -q x f' '! builtin command cmp -s a b'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "a quiet cmp in a non-final pipeline stage fails" {
  script 'set -o pipefail' '! cmp -s missing input | cat'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:3: a negated"* ]]
}

@test "a -- that is the argument of -e doesn't end the options" {
  local line
  for line in '! grep -e -- -q missing' '! grep --regexp -- -q f' '! grep -ie -- -q f' '! grep -f -- -q f' '! cmp -i -- -s a b'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
  script '! grep -e x -- -q f'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "an allow comment covers only the first statement on the line below it" {
  script '# lint-negated: allow the first one fails safe' '! grep -q a f; ! grep -q b f'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'a negated' <<<"$output")" -eq 1 ]
}

@test "a script shfmt can't parse fails" {
  script 'if then fi ((('
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"shfmt could not parse it"* ]]
}

# Codex's fourth-round reproductions.

@test "env with an expanded assignment value still exposes the grep" {
  local line
  for line in '! env LC_ALL="$locale" grep -q x missing' '! env LANG=${lang:-C} A=1 grep -q x f'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "env long options with a separate argument, and a -- before the command" {
  local line
  for line in '! env --unset HOME grep -q x missing' '! env --chdir /tmp grep -q x f' '! env --unset=HOME grep -q x f' \
    '! env -- LC_ALL=C grep -q x f' '! env -i -- grep -q x f'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "a wrapper named by its path is still a wrapper" {
  local line
  for line in '! /usr/bin/env grep -q x missing' '! /usr/bin/env LC_ALL=C /usr/bin/grep -q x f' '! /usr/bin/command grep -q x f'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "env running something other than a quiet grep passes" {
  script '! env LC_ALL=C sort f' '! env --unset HOME true'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "an env assignment counts whether its first part is plain, single-quoted or double-quoted" {
  local line
  for line in '! env LC_ALL="$locale" grep -q x missing' "! env 'LC_ALL=C' grep -q x f" \
    '! env "LC_ALL=$locale" grep -q x missing' '! env "LC_ALL"=C grep -q x f'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

# Codex's reproductions on #15, and a case for each header claim the
# earlier cases left out.

@test "an escaped or quoted command name is still grep or cmp" {
  local line
  for line in '! \grep -q x missing' '! gr\ep -\q x f' '! "grep" -q x f' "! 'cmp' -s a b"; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "every prefix of --quiet and --silent fails, down to --q and --s" {
  local line
  for line in '! cmp --s missing input' '! grep --s x f' '! grep --q x f' '! cmp --q a b'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
  script '! grep --sx a f'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "egrep, fgrep and a clustered cmp -s fail" {
  local line
  for line in '! egrep -q x f' '! fgrep -q x f' '! cmp -bs a b'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "exec -a, and env -C, -S and --split-string with their arguments" {
  local line
  for line in '! exec -a name grep -q x f' '! exec -c grep -q x f' '! env -C /tmp grep -q x f' '! env -S x grep -q x f' \
    '! env --split-string x grep -q x f'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "the argument of grep --file and of cmp -n, --bytes and --ignore-initial is skipped" {
  local line
  for line in '! grep --file -- -q f' '! cmp -n -- -s a b' '! cmp --bytes -- -s a b' \
    '! cmp --ignore-initial -- -s a b' '! cmp -bi -- -s a b'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

@test "either side of && or || inside braces or a subshell, nested or not, fails" {
  local line
  for line in '! { true && grep -q a f; }' '! (grep -q a f || true)' '! (x; (y; cmp -s a b))'; do
    script "$line"
    run bash "$check" "$dir/t.sh"
    [ "$status" -eq 1 ]
  done
}

# Codex's third-round reproduction on #15: Bash 3.2 writes a here-string
# to a temp file, and a failure to create it passed flagged input.

@test "a flagged script still fails when TMPDIR is read-only" {
  script '! grep -q x missing'
  mkdir "$dir/ro"
  chmod 555 "$dir/ro"
  TMPDIR="$dir/ro" run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:2: a negated"* ]]
}

@test "a flagged script still fails under Bash 3.2 when no temp file can be written" {
  if ! command -v sandbox-exec >/dev/null || [[ ! -x /bin/bash ]]; then
    skip "needs the macOS sandbox-exec and /bin/bash"
  fi
  script '! grep -q x missing'
  run sandbox-exec -p '(version 1)(allow default)(deny file-write* (require-not (subpath "/dev")))' \
    /bin/bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:2: a negated"* ]]
}

@test "the check itself uses no here-string or here-document" {
  run grep -n '<<' "$check"
  [ "$status" -eq 1 ]
}
