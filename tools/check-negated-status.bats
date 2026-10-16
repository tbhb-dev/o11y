#!/usr/bin/env bats
# tools/check-negated-status.sh on small scripts: a negated grep -q or
# cmp -s fails unless an allow comment with a reason is on the line before.
# cspell:ignore subshell quie

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
