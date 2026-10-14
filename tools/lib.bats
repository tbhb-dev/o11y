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

@test "a place that does not exist fails as unsearchable" {
  run sentinel_absent "$secret" "${places[@]}" "the printed Compose model=$dir/missing.log"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL the printed Compose model could not be searched" ]
}

@test "an unreadable place fails as unsearchable" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  chmod 000 "$dir/containers.log"
  run sentinel_absent "$secret" "${places[@]}"
  chmod 600 "$dir/containers.log"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL a container log could not be searched" ]
}

@test "an empty file fails, because nothing was collected" {
  : >"$dir/processes.log"
  run sentinel_absent "$secret" "${places[@]}"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL a process argument is empty, so it cannot be searched" ]
}

# Puts a stub first on PATH. The stub prints $STUB_OUT and exits $STUB_EXIT,
# and records its arguments.
stub() {
  mkdir -p "$dir/bin"
  printf '#!/bin/sh\necho "$@" >>"%s/%s.args"\nprintf %%s "$STUB_OUT"\nexit "${STUB_EXIT:-0}"\n' "$dir" "$1" >"$dir/bin/$1"
  chmod +x "$dir/bin/$1"
  PATH="$dir/bin:$PATH"
}

@test "expect_status passes on exactly the expected status" {
  stub curl
  STUB_OUT=401 run expect_status 401 http://127.0.0.1:1/
  [ "$status" -eq 0 ]
}

@test "expect_status fails when the request never completes" {
  stub curl
  STUB_OUT=000 STUB_EXIT=7 run expect_status 401 http://127.0.0.1:1/
  [ "$status" -eq 1 ]
  [[ $output == *"before any status arrived"* ]]
}

@test "expect_status fails on a server error" {
  stub curl
  STUB_OUT=500 run expect_status 401 http://127.0.0.1:1/
  [ "$status" -eq 1 ]
  [[ $output == *"got 500"* ]]
}

@test "expect_status fails on a success where a refusal is expected" {
  stub curl
  STUB_OUT=200 run expect_status 401 http://127.0.0.1:1/
  [ "$status" -eq 1 ]
}

@test "the credential copy runs with container logging off" {
  stub docker
  stub uname
  export O11Y_DATA_DIR=/var/lib/o11y-test/x
  STUB_OUT=Darwin publish_s3_env image "$dir/s3.env"
  grep -q -- '--log-driver none' "$dir/docker.args"
  [ "$O11Y_S3_ENV_FILE" = "$dir/s3.env" ]
}
