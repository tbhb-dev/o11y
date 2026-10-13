#!/usr/bin/env bats
# The sentinel search the boot test ends with: it must fail on a leak, name
# the place and never print the value.

setup() {
  # shellcheck source=tools/lib.sh
  source "$BATS_TEST_DIRNAME/lib.sh"
  dir=$(mktemp -d)
  mkdir "$dir/release"
  echo "O11Y_DATA_DIR=/srv/o11y/data" >"$dir/release/.env"
  echo "level=info msg=started" >"$dir/containers.log"
  echo "root 1 0 /usr/bin/rustfs /data" >"$dir/processes.log"
  secret=SmokeSentinelSecretKeyNotARealSecret0000
  places=("the rendered release=$dir/release" "a container log=$dir/containers.log" "a process argument=$dir/processes.log")
}

teardown() {
  rm -rf "$dir"
}

@test "a clean set of places passes" {
  run sentinel_absent "$secret" "${places[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a secret in a container log fails and names the log" {
  echo "level=debug secret_key=$secret" >>"$dir/containers.log"
  run sentinel_absent "$secret" "${places[@]}"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL a sentinel secret is in a container log" ]
}

@test "a secret in a process argument fails and names it" {
  echo "root 9 1 curl --user key:$secret" >>"$dir/processes.log"
  run sentinel_absent "$secret" "${places[@]}"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL a sentinel secret is in a process argument" ]
}

@test "a secret in a rendered file fails and names the release" {
  echo "AWS_SECRET_ACCESS_KEY=$secret" >>"$dir/release/.env"
  run sentinel_absent "$secret" "${places[@]}"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL a sentinel secret is in the rendered release" ]
}

@test "a value that starts with a dash is searched as text" {
  run sentinel_absent "-rf" "${places[@]}"
  [ "$status" -eq 0 ]
}
