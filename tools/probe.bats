#!/usr/bin/env bats
# config/probe/probe.sh against a stub aws: a listing that fails must never
# read as an empty bucket.

setup() {
  dir=$(mktemp -d)
  probe="$BATS_TEST_DIRNAME/../config/probe/probe.sh"
  # The stub answers list-objects-v2 from $LISTING and fails when the file is
  # missing, the way the CLI does when the store is unreachable.
  cat >"$dir/aws" <<'STUB'
#!/bin/sh
case "$*" in
  *list-objects-v2*)
    [ -f "$LISTING" ] || {
      echo "Could not connect to the endpoint URL" >&2
      exit 255
    }
    cat "$LISTING"
    ;;
  *get-object*) [ -z "${UNREADABLE:-}" ] ;;
esac
STUB
  chmod +x "$dir/aws"
  export PATH="$dir:$PATH" LISTING="$dir/listing"
}

teardown() {
  rm -rf "$dir"
}

@test "count prints 0 for an empty bucket" {
  echo None >"$LISTING"
  run sh "$probe" count loki
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "count adds up the keys of every listing page" {
  printf 'a\tb\tc\nd\te\n' >"$LISTING"
  run sh "$probe" count loki
  [ "$status" -eq 0 ]
  [ "$output" = 5 ]
}

@test "count fails when the listing fails, and prints no number" {
  run sh "$probe" count loki
  [ "$status" -ne 0 ]
  [[ $output != 0 ]]
  [[ $output == *"listing loki failed"* ]]
}

@test "listed-keys reads every listed key" {
  printf 'crash/1\tcrash/2\n' >"$LISTING"
  run sh "$probe" listed-keys
  [ "$status" -eq 0 ]
}

@test "listed-keys fails when the listing fails" {
  run sh "$probe" listed-keys
  [ "$status" -ne 0 ]
  [[ $output == *"listing o11y-probe failed"* ]]
}

@test "listed-keys fails when a listed key is unreadable" {
  printf 'crash/1\tcrash/2\n' >"$LISTING"
  UNREADABLE=1 run sh "$probe" listed-keys
  [ "$status" -ne 0 ]
  [[ $output == *"listed key crash/1 is unreadable"* ]]
}
