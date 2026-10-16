#!/usr/bin/env bats
# tools/check-negated-status.sh on small scripts: a negated grep -q or
# cmp -s fails unless an allow comment with a reason is on the line before.

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
