#!/usr/bin/env bats
# The helpers the boot test relies on. The sentinel search must fail on a
# leak, name the place and never print the value, and a check on output
# must also fail when its command does.

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
  [[ ! -f $dir/sockets.list ]] || xargs kill <"$dir/sockets.list" 2>/dev/null || true
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

@test "an empty directory fails, because nothing was collected" {
  mkdir "$dir/empty"
  run sentinel_absent "$secret" "${places[@]}" "the rendered source copy=$dir/empty"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL the rendered source copy holds no non-empty file, so it cannot be searched" ]
}

@test "a directory of empty files fails, because nothing was collected" {
  mkdir "$dir/hollow"
  : >"$dir/hollow/a"
  : >"$dir/hollow/b"
  run sentinel_absent "$secret" "${places[@]}" "the rendered source copy=$dir/hollow"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL the rendered source copy holds no non-empty file, so it cannot be searched" ]
}

@test "a directory that cannot be listed fails as unsearchable" {
  [ "$(id -u)" -ne 0 ] || skip "root lists any directory"
  mkdir -p "$dir/locked/inner"
  echo data >"$dir/locked/inner/f"
  chmod 000 "$dir/locked/inner"
  run sentinel_absent "$secret" "${places[@]}" "the rendered config=$dir/locked"
  chmod 700 "$dir/locked/inner"
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL the rendered config could not be searched" ]
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

# A docker stub for the local-engine guard. It records each call with the
# DOCKER_HOST and DOCKER_CONTEXT it saw, and answers as STUB_CONTEXT,
# STUB_ENDPOINT and STUB_INFO say.
engine_stub() {
  mkdir -p "$dir/bin"
  cat >"$dir/bin/docker" <<'STUB'
#!/bin/sh
printf '%s|%s|%s\n' "${DOCKER_HOST:-}" "${DOCKER_CONTEXT:-}" "$*" >>"$STUB_LOG"
case "$1 $2" in
"context show") echo "$STUB_CONTEXT" ;;
"context inspect") echo "$STUB_ENDPOINT" ;;
"info --format") echo "$STUB_INFO" ;;
*) echo "engine work: $*" >>"$STUB_LOG.work" ;;
esac
STUB
  chmod +x "$dir/bin/docker"
  export PATH="$dir/bin:$PATH" STUB_LOG=$dir/docker.log STUB_CONTEXT=default
  # The endpoint is a real socket on one of the daemon's own paths: under
  # a throwaway HOME on macOS, the host's own daemon socket on Linux.
  if host_is_linux; then
    STUB_INFO="$(uname -n)|Ubuntu 24.04"
    local path
    for path in /var/run/docker.sock /run/docker.sock; do
      [[ -S $path ]] || continue
      STUB_ENDPOINT=unix://$path
      break
    done
    [[ -n ${STUB_ENDPOINT:-} ]] || skip "needs a local daemon socket on Linux"
  else
    STUB_INFO="docker-desktop|Docker Desktop"
    export HOME=$dir/home
    mkdir -p "$HOME/.docker/run"
    make_socket "$HOME/.docker/run/docker.sock"
    STUB_ENDPOINT=unix://$HOME/.docker/run/docker.sock
  fi
  export STUB_INFO STUB_ENDPOINT
}

# make_socket <path>: a listening unix socket there, for as long as the
# test runs.
make_socket() {
  python3 -c 'import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); time.sleep(600)' "$1" &
  echo $! >>"$dir/sockets.list"
  local tries=0
  until [[ -S $1 ]]; do
    ((tries++ < 50)) || return 1
    sleep 0.1
  done
}

@test "the local engine guard drops an inherited remote endpoint before any call" {
  engine_stub
  DOCKER_HOST=tcp://nas.example.invalid:2376 DOCKER_CONTEXT=nas run local_engine_only
  [ "$status" -eq 0 ]
  ! grep -q 'nas' "$dir/docker.log" || false
}

@test "a remote context, a non-local socket or another engine stops before any engine work" {
  engine_stub
  STUB_CONTEXT=nas run local_engine_only
  [ "$status" -ne 0 ]
  [[ $output != *nas* ]] || false
  ! grep -q '|info ' "$dir/docker.log" || false
  STUB_ENDPOINT=ssh://admin@nas.example.invalid run local_engine_only
  [ "$status" -ne 0 ]
  ! grep -q '|info ' "$dir/docker.log" || false
  STUB_INFO="nas-node-01|Synology" run local_engine_only
  [ "$status" -ne 0 ]
  [[ $output != *nas-node-01* ]] || false
  [ ! -e "$dir/docker.log.work" ]
}

@test "the fault run with a remote endpoint stops before its first engine call" {
  engine_stub
  STUB_CONTEXT=nas run bash "$BATS_TEST_DIRNAME/fault-run.sh"
  [ "$status" -ne 0 ]
  [[ $output == *"local engine:"* ]] || false
  [ ! -e "$dir/docker.log.work" ]
  ! grep -qE '\|(version|info|run|ps|rm)' "$dir/docker.log" || false
}

@test "smoke, the rehearsal, the RustFS probe and validation stop on a remote context too" {
  engine_stub
  for script in smoke.sh nas-rehearsal.sh rustfs-probe.sh validate.sh; do
    rm -f "$dir/docker.log.work"
    STUB_CONTEXT=nas run bash "$BATS_TEST_DIRNAME/$script"
    [ "$status" -ne 0 ]
    [[ $output == *"local engine:"* ]] || false
    [ ! -e "$dir/docker.log.work" ]
  done
}

@test "a socket that isn't the daemon's own, or a daemon path that isn't a socket, stops before any engine work" {
  engine_stub
  make_socket "$dir/forwarded.sock"
  STUB_ENDPOINT=unix://$dir/forwarded.sock run local_engine_only
  [ "$status" -ne 0 ]
  [[ $output == *"does not use this machine's own daemon socket"* ]] || false
  [[ $output != *forwarded* ]] || false
  ! grep -q '|info ' "$dir/docker.log" || false
  if ! host_is_linux; then
    kill "$(cat "$dir/sockets.list" | head -n 1)" 2>/dev/null || true
    rm -f "$HOME/.docker/run/docker.sock"
    : >"$HOME/.docker/run/docker.sock"
    run local_engine_only
    [ "$status" -ne 0 ]
    ! grep -q '|info ' "$dir/docker.log" || false
  fi
}

@test "docker's own error output, with the context name and socket path, never reaches the task's output" {
  engine_stub
  cat >"$dir/bin/docker" <<'STUB'
#!/bin/sh
echo "context canary-ctx-name at canary-socket-path: connection refused" >&2
case "$1 $2" in
"context show") [ -n "${STUB_FAIL_SHOW:-}" ] && exit 1; echo default ;;
"context inspect") [ -n "${STUB_FAIL_INSPECT:-}" ] && exit 1; echo "$STUB_ENDPOINT" ;;
*) exit 1 ;;
esac
STUB
  for failing in STUB_FAIL_SHOW STUB_FAIL_INSPECT STUB_FAIL_INFO; do
    run env "$failing=1" bash -c "source '$BATS_TEST_DIRNAME/lib.sh'; local_engine_only"
    [ "$status" -ne 0 ]
    [[ $output == *"local engine:"* ]] || false
    [[ $output != *canary* ]] || false
  done
}

@test "the rehearsal's inside half, started directly, stops before any engine call" {
  engine_stub
  run bash "$BATS_TEST_DIRNAME/nas-rehearsal.sh" --inside
  [ "$status" -ne 0 ]
  [[ $output == *"--inside runs only in the container the rehearsal starts"* ]] || false
  REHEARSAL_ENGINE="docker-desktop|Docker Desktop" DOCKER_HOST=tcp://nas.example.invalid:2376 \
    run bash "$BATS_TEST_DIRNAME/nas-rehearsal.sh" --inside
  [ "$status" -ne 0 ]
  [ ! -e "$dir/docker.log" ]
}

@test "output_is passes a command that succeeds with exactly the expected output" {
  stub probe
  STUB_OUT=200 run output_is 200 probe
  [ "$status" -eq 0 ]
}

@test "output_is fails a command that prints the expected output and then fails" {
  stub probe
  STUB_OUT=200 STUB_EXIT=28 run output_is 200 probe
  [ "$status" -eq 1 ]
}

@test "output_is fails a command that fails with nothing where nothing is expected" {
  stub probe
  STUB_EXIT=1 run output_is '' probe
  [ "$status" -eq 1 ]
}

@test "output_is fails a command that succeeds with other output" {
  stub probe
  STUB_OUT=503 run output_is 200 probe
  [ "$status" -eq 1 ]
}

# otlp_parse_discards reads Mimir's own /metrics.
mimir_exposition() {
  printf '%s\n' '# HELP cortex_build_info A metric with a constant 1 value.' '# TYPE cortex_build_info gauge' 'cortex_build_info{version="3.2.2"} 1' "$@"
}

@test "Mimir's exposition without a discard series counts as no discards" {
  run otlp_parse_discards < <(mimir_exposition)
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "otlp_parse_error discards are summed across their series and other reasons are left out" {
  run otlp_parse_discards < <(mimir_exposition \
    'cortex_discarded_samples_total{group="",reason="otlp_parse_error",user="anonymous"} 1' \
    'cortex_discarded_samples_total{group="a",reason="otlp_parse_error",user="anonymous"} 2' \
    'cortex_discarded_samples_total{group="",reason="sample_out_of_order",user="anonymous"} 40')
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
}

@test "an error page is not Mimir's exposition and fails rather than counting as no discards" {
  run otlp_parse_discards <<<'404 page not found'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a discard series without a number fails" {
  run otlp_parse_discards < <(mimir_exposition 'cortex_discarded_samples_total{reason="otlp_parse_error"} garbage')
  [ "$status" -ne 0 ]
}

# The masked statuses these helpers replace: each "old" case shows the
# negated construction passing on input it should fail.

@test "lacks reads all of its input and tells a match, no match and a failed grep apart" {
  run bash -c 'set -o pipefail; ! { echo dump; seq 1 200000; } | grep -q -v "^[0-9]"'
  [ "$status" -eq 0 ]
  run bash -c "set -o pipefail; source '$BATS_TEST_DIRNAME/lib.sh'; { echo dump; seq 1 200000; } | lacks -v '^[0-9]'"
  [ "$status" -eq 1 ]
  run bash -c "source '$BATS_TEST_DIRNAME/lib.sh'; seq 1 10 | lacks -v '^[0-9]'"
  [ "$status" -eq 0 ]
  run bash -c "source '$BATS_TEST_DIRNAME/lib.sh'; seq 1 10 | lacks -E '('"
  [ "$status" -eq 2 ]
}

@test "json_after_start fails on a non-JSON line after the start, however long the log" {
  run bash -c 'set -o pipefail; ! { echo "Starting: /usr/bin/rustfs"; seq 1 200000; } | sed 1d | grep -q -v "^{"'
  [ "$status" -eq 0 ]
  run bash -c "source '$BATS_TEST_DIRNAME/lib.sh'; { echo 'Starting: /usr/bin/rustfs'; seq 1 200000; } | json_after_start"
  [ "$status" -eq 3 ]
  run bash -c "source '$BATS_TEST_DIRNAME/lib.sh'; printf 'Initializing\nStarting: /usr/bin/rustfs\n{\"a\":1}\r\n' | json_after_start"
  [ "$status" -eq 0 ]
  run bash -c "source '$BATS_TEST_DIRNAME/lib.sh'; echo '{\"a\":1}' | json_after_start"
  [ "$status" -eq 4 ]
}

@test "files_differ accepts only a difference, and a comparison error is neither" {
  echo a >"$dir/a"
  echo b >"$dir/b"
  echo a >"$dir/same"
  echo a >"$dir/locked"
  chmod 000 "$dir/locked"
  [[ ! -r $dir/locked ]] || skip "runs as a user who can read any file"
  run bash -c "! cmp -s '$dir/a' '$dir/locked'"
  [ "$status" -eq 0 ]
  run files_differ "$dir/a" "$dir/b"
  [ "$status" -eq 0 ]
  run files_differ "$dir/a" "$dir/same"
  [ "$status" -eq 1 ]
  run files_differ "$dir/a" "$dir/locked"
  [ "$status" -eq 2 ]
}

@test "expected_up_jobs fails when its search fails, even after printing the jobs" {
  printf '%s\n' 'prometheus.scrape "a" {' '	targets = [{"__address__" = "a:1", "job" = "o11y/a"}]' '}' 'otelcol.receiver.otlp "self" {' >"$dir/config.alloy"
  run expected_up_jobs "$dir/config.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "o11y/a
o11y/rustfs" ]
  mkdir -p "$dir/bin"
  printf '%s\n' '#!/bin/sh' 'echo "\"job\" = \"o11y/a\""' 'exit 2' >"$dir/bin/grep"
  chmod +x "$dir/bin/grep"
  run env PATH="$dir/bin:$PATH" bash -c "set -o pipefail; { grep -o x '$dir/config.alloy' | cut -d'\"' -f4; ! grep -q y '$dir/config.alloy' || echo o11y/rustfs; } | jq -Rsc 'split(\"\\n\")'"
  [ "$status" -eq 0 ]
  PATH="$dir/bin:$PATH" run expected_up_jobs "$dir/config.alloy"
  [ "$status" -ne 0 ]
}
