#!/usr/bin/env bats
# tools/validate.sh --model: the resolved Compose model must not depend on
# anything inherited from the environment. Needs the pinned Compose binary
# and no Docker engine.

setup() {
  dir=$(mktemp -d)
  validate="$BATS_TEST_DIRNAME/validate.sh"
  sentinel=ValidateSentinelSecretNotARealSecret0000
}

teardown() {
  rm -rf "$dir"
}

@test "published ports stay on loopback under an inherited bind address" {
  O11Y_BIND_ADDR=0.0.0.0 run bash "$validate" --model
  [ "$status" -eq 0 ]
  [ "$(jq -s -c '[.[].services[]?.ports[]?.host_ip] | unique' <<<"$output")" = '["127.0.0.1"]' ]
  [ "$(jq -s '[.[].services[]?.ports[]?] | length' <<<"$output")" -eq 3 ]
}

@test "an inherited S3 env file that does not exist is ignored" {
  O11Y_S3_ENV_FILE="$dir/missing.env" run bash "$validate" --model
  [ "$status" -eq 0 ]
  [[ $output == *dummy-not-a-secret* ]]
}

@test "an inherited S3 env file with a secret never reaches the model" {
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$sentinel" "$sentinel" >"$dir/s3.env"
  O11Y_S3_ENV_FILE="$dir/s3.env" O11Y_DATA_DIR="$dir" run bash "$validate" --model
  [ "$status" -eq 0 ]
  [[ $output != *"$sentinel"* ]]
  [[ $output == *dummy-not-a-secret* ]]
  [ ! -e "$BATS_TEST_DIRNAME/../tmp/validate" ]
}

@test "inherited ports and Compose settings do not change the model" {
  clean=$(bash "$validate" --model)
  O11Y_GRAFANA_PORT=9 COMPOSE_PROFILES=tools COMPOSE_FILE="$dir/none.yaml" run bash "$validate" --model
  [ "$status" -eq 0 ]
  [ "$output" = "$clean" ]
}
