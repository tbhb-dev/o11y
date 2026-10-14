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

# A stub docker for the component checks. Real configs pass; the invalid
# fixtures get whatever $STUB_INVALID says.
stub_docker() {
  mkdir -p "$dir/bin"
  cat >"$dir/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  version) echo 1.40 ;;
  run)
    [[ "$*" == */invalid/* ]] || exit 0
    case $STUB_INVALID in
      launch) echo "docker: Error response from daemon: failed to create task" >&2; exit 125 ;;
      signal) exit 137 ;;
      silent) exit 1 ;;
      rejects)
        echo "field not_a_loki_section not found"
        echo "field not_a_tempo_section not found"
        echo "field not_a_mimir_section not found"
        echo 'component "otelcol.exporter.otlp.missing.input" does not exist or is out of scope'
        exit 1
        ;;
    esac
    ;;
esac
STUB
  chmod +x "$dir/bin/docker"
  PATH="$dir/bin:$PATH"
}

@test "a validator that never starts on the fixture is not a rejection" {
  stub_docker
  STUB_INVALID=launch run bash "$validate"
  [ "$status" -ne 0 ]
  [ "$(grep -c 'did not run on the invalid fixture (exit 125)' <<<"$output")" -eq 4 ]
  [[ $output != *"invalid rejected"* ]]
}

@test "a validator killed by a signal is not a rejection" {
  stub_docker
  STUB_INVALID=signal run bash "$validate"
  [ "$status" -ne 0 ]
  [ "$(grep -c 'did not run on the invalid fixture (exit 137)' <<<"$output")" -eq 4 ]
}

@test "a failure that does not name the broken part is not a rejection" {
  stub_docker
  STUB_INVALID=silent run bash "$validate"
  [ "$status" -ne 0 ]
  [ "$(grep -c 'without naming what is broken' <<<"$output")" -eq 4 ]
}

@test "a rejection that names the broken part passes" {
  stub_docker
  STUB_INVALID=rejects run bash "$validate"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'valid accepted, invalid rejected' <<<"$output")" -eq 4 ]
}
