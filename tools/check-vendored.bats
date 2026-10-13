#!/usr/bin/env bats
# The drift gate against a copy of the staged tree, so the edits the
# tests make never reach the real checkout.

setup() {
  root=$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)
  copy=$(mktemp -d)
  git -C "$root" checkout-index -a --prefix="$copy/"
  cd "$copy" || exit 1
}

teardown() {
  rm -rf "$copy"
}

@test "an untouched payload passes" {
  run bash tools/check-vendored.sh
  [ "$status" -eq 0 ]
}

@test "an edit to a vendored file fails and survives the check" {
  echo '# local edit' >>.devtools/tasks/fix.toml
  run bash tools/check-vendored.sh
  [ "$status" -eq 1 ]
  [ "$(tail -n 1 .devtools/tasks/fix.toml)" = '# local edit' ]
}

@test "an extra file in a vendored directory fails" {
  touch .config/mise/conf.d/99-extra.toml
  run bash tools/check-vendored.sh
  [ "$status" -eq 1 ]
  [ -f .config/mise/conf.d/99-extra.toml ]
}
