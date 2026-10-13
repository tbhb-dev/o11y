#!/usr/bin/env bats
# fix_prose_replacements.py must fail when vale cannot run or a finding
# cannot be parsed, rather than report success.

setup() {
  script="$BATS_TEST_DIRNAME/fix_prose_replacements.py"
  work=$(mktemp -d)
  mkdir "$work/bin"
  printf 'Some text.\n' >"$work/draft.md"
  PATH="$work/bin:$PATH"
}

teardown() {
  rm -rf "$work"
}

fake_vale() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$work/bin/vale"
  chmod +x "$work/bin/vale"
}

@test "a vale that fails to run makes the task fail" {
  fake_vale 'echo "config error" >&2; exit 2'
  run uv run --script "$script" "$work/draft.md"
  [ "$status" -eq 1 ]
  [[ $output == *"vale-failed"* ]]
  [[ $output == *"config error"* ]]
}

@test "a finding with unparsable quoting makes the task fail" {
  fake_vale 'printf "%s\n" "1:1-4 [error] Google.Contractions match=\"does not\" replace_with=\"\\q\""; exit 1'
  run uv run --script "$script" "$work/draft.md"
  [ "$status" -eq 1 ]
  [[ $output == *"unparsable-quoting"* ]]
}

@test "a clean vale run passes" {
  fake_vale 'exit 0'
  run uv run --script "$script" "$work/draft.md"
  [ "$status" -eq 0 ]
}
