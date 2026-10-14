#!/usr/bin/env bats
# tools/nas.sh against a fake host. Nothing here contacts a real one: a stub
# ssh, first on PATH, records each remote command and runs it in a temporary
# directory that stands in for the host, where sudo, docker, docker-compose
# and tailscale are stubs too. The tests assert on the recorded commands and
# on what they did to that directory. Needs the pinned Compose binary, which
# loads the rendered models, and no Docker engine.

setup() {
  mv --version >/dev/null 2>&1 || skip "needs an mv that accepts -T, as the deploy host must"
  root="$BATS_TEST_DIRNAME/.."
  dir=$(cd "$(mktemp -d)" && pwd -P)
  repo=$dir/repo
  host=$dir/host
  remote=$host/o11y
  mkdir -p "$repo/tools" "$dir/bin" "$host/bin"
  cp -R "$root/compose.yaml" "$root/compose.init.yaml" "$root/compose.tools.yaml" "$root/config" "$repo/"
  cp "$root/tools/nas.sh" "$root/tools/lib.sh" "$root/tools/render.sh" "$repo/tools/"

  # Runs the remote command locally. STUB_CORRUPT names an upload to damage
  # after it arrives, the way a broken transfer would. STUB_SSH_DOWN makes
  # every connection fail.
  stub "$dir/bin/ssh" <<'STUB'
for command; do :; done
[ -z "${STUB_SSH_DOWN:-}" ] || exit 255
printf '%s\n' "$command" >>"$STUB/ssh.log"
sh -c "$command"
status=$?
if [ -n "${STUB_CORRUPT:-}" ]; then
  case $command in
  *"tar -xpf"*"$STUB_CORRUPT"*)
    echo damaged >>"$(find "${command##* -C }" -type f ! -name MANIFEST.sha256 | head -n 1)"
    ;;
  esac
fi
exit "$status"
STUB
  # Refuses what the host's sudoers would refuse.
  stub "$dir/bin/sudo" <<'STUB'
printf '%s\n' "$*" >>"$STUB/sudo.log"
[ "$1" = -n ] || exit 97
shift
case $1 in
"$O11Y_REMOTE_DOCKER" | "$O11Y_REMOTE_COMPOSE") exec "$@" ;;
esac
exit 97
STUB
  stub "$dir/bin/tar" <<'STUB'
printf '%s\n' "$*" >>"$STUB/tar.log"
exec "$STUB_TAR" "$@"
STUB
  stub "$dir/bin/git" <<<'echo abc1234'
  stub "$dir/bin/getent" <<<'echo "192.0.2.20 STREAM otlp.example.ts.net"'
  # The pinned Compose, with its calls recorded. nas.sh clears the
  # environment for it, so the paths are written into the stub.
  stub "$dir/bin/compose" <<STUB
printf '%s\n' "\$*" >>"$dir/compose.log"
exec "$(command -v docker-cli-plugin-docker-compose)" "\$@"
STUB

  # Knows the containers listed in $STUB/containers, one
  # "project service name compose-files status" line each. `inspect` and a
  # look at a container's environment print the generated S3 env file, as
  # the real ones would.
  stub "$host/bin/docker" <<'STUB'
printf '%s\n' "$@" >"$STUB/docker.args"
all="$*"
case $all in *"${STUB_FAIL:-no failure}"*) exit 1 ;; esac
project=${all##*label=com.docker.compose.project=}
project=${project%% *}
case $1 in
ps)
  [ -f "$STUB/containers" ] || exit 0
  service=
  case $all in
  *label=com.docker.compose.service=*)
    service=${all##*label=com.docker.compose.service=}
    service=${service%% *}
    ;;
  esac
  case $all in
  *--format*) awk -v p="$project" '$1 == p { sub(/^[^ ]+ /, ""); print }' "$STUB/containers" ;;
  *) awk -v p="$project" -v s="$service" '$1 == p && (s == "" || $2 == s) { print $3 }' "$STUB/containers" ;;
  esac
  ;;
exec)
  case $all in
  *grafana_admin_password*) echo stub-grafana-password ;;
  *" env"* | *printenv*) cat "$O11Y_REMOTE_DIR/data/secrets/s3.env" ;;
  *"-X POST"*) printf 204 ;;
  *curl*) printf '%s' "${STUB_HTTP:-200}" ;;
  esac
  ;;
inspect) cat "$O11Y_REMOTE_DIR/data/secrets/s3.env" ;;
run)
  case $all in
  *"stat -c"*) cat "$STUB/layout" ;;
  *"find /d -mindepth 1"*)
    mounted=${all##* -v }
    mounted=${mounted%%:/d *}
    case $mounted in "$STUB"/*) find "$mounted" -mindepth 1 -maxdepth 1 -exec rm -rf {} + ;; esac
    ;;
  esac
  ;;
version) echo "client 24.0.2, server 24.0.2" ;;
esac
exit 0
STUB
  # `config` without -q prints the env file a model loads, as the real one
  # does.
  stub "$host/bin/docker-compose" <<'STUB'
all="$*"
case $all in *"${STUB_FAIL:-no failure}"*) exit 1 ;; esac
case $all in
*" config"*) case $all in *" -q"*) ;; *) cat "$O11Y_REMOTE_DIR/data/secrets/s3.env" ;; esac ;;
*"version --short"*) echo v2.20.1-stub ;;
*"s3probe count"*) echo 3 ;;
*logs*rustfs*) [ ! -f "$STUB/rustfs.log" ] || cat "$STUB/rustfs.log" ;;
esac
exit 0
STUB
  stub "$host/bin/tailscale" <<'STUB'
case "$*" in
version) echo 1.104.1 ;;
"serve status") echo "No serve config" ;;
serve*)
  if [ -n "${STUB_SERVE_DENIED:-}" ]; then
    echo "Access denied: serve config denied" >&2
    exit 1
  fi
  ;;
esac
STUB
  # receipt.sh and rustfs-probe.sh have their own tests; here they record
  # how they were called.
  stub "$repo/tools/receipt.sh" <<'STUB'
echo "receipt.sh $* [curl=$O11Y_CHECK_CURL otlp=$O11Y_CHECK_OTLP_URL grafana=$O11Y_CHECK_GRAFANA_URL]" >>"$STUB/tools.log"
[ -z "${STUB_RECEIPT_FAIL:-}" ] || exit 1
[ "${1:-}" != --state-file ] || echo "0123456789abcdef 0123456789abcdef0123456789abcdef 42 1760000000" >"$2"
STUB
  stub "$repo/tools/rustfs-probe.sh" <<'STUB'
echo "rustfs-probe.sh $*" >>"$STUB/tools.log"
[ -z "${STUB_PROBE_FAIL:-}" ]
STUB

  STUB_TAR=$(command -v tar)
  export STUB=$dir STUB_TAR PATH="$dir/bin:$PATH"
  export O11Y_COMPOSE=$dir/bin/compose O11Y_HEALTH_TIMEOUT=0
  export O11Y_SSH_HOST=nas.example.invalid O11Y_REMOTE_DIR=$remote
  export O11Y_REMOTE_DOCKER=$host/bin/docker O11Y_REMOTE_COMPOSE=$host/bin/docker-compose
  export O11Y_REMOTE_TAILSCALE=$host/bin/tailscale O11Y_TAILNET_DOMAIN=example.ts.net
  export O11Y_NODE_ADDR=192.0.2.10 O11Y_PRIVATE_STRINGS=
  unset O11Y_CONFIRM O11Y_GRAFANA_PORT O11Y_OTLP_GRPC_PORT O11Y_OTLP_HTTP_PORT O11Y_SECRETS_OWNER
  changing=(stage gate-test gate-clean deploy rollback down serve-apply serve-clear)
  sentinel=NasSentinelSecretNotARealSecret000000000
}

teardown() {
  rm -rf "$dir"
}

stub() {
  {
    echo '#!/bin/sh'
    cat
  } >"$1"
  chmod +x "$1"
}

# nas <task> [arguments]: runs the task and keeps what it printed.
nas() {
  run bash "$repo/tools/nas.sh" "$@"
  echo "$output" >>"$dir/output"
}

# go <task> [arguments]: the same with the task's confirmation set.
go() {
  O11Y_CONFIRM=$1 nas "$@"
}

# healthy <project>: every container of the project in the state the health
# gate wants.
healthy() {
  local service
  {
    echo "$1 s3-buckets $1-s3-buckets-1 files Exited (0) 1 minute ago"
    for service in rustfs tempo alloy grafana; do
      echo "$1 $service $1-$service-1 $remote/releases/20260101T000000Z-abc1234/compose.yaml Up 1 minute (healthy)"
    done
    for service in loki mimir; do
      echo "$1 $service $1-$service-1 files Up 1 minute"
    done
  } >>"$dir/containers"
}

# What init leaves under the gate data directory, as the utility container
# would list it.
layout() {
  cat >"$dir/layout" <<'LAYOUT'
alloy 0:0 750
grafana 472:472 750
loki 10001:10001 750
mimir 0:0 750
rustfs 10001:10001 750
secrets 0:0 755
tempo 10001:10001 750
secrets/grafana_admin_password 472:472 400 33
secrets/rustfs.access_key 10001:10001 400 21
secrets/rustfs.secret_key 10001:10001 400 41
secrets/s3.env 0:0 600 102
LAYOUT
}

staged() {
  cat "$repo/tmp/deploy/staged"
}

# in_order <text>...: each text is in a recorded command after the one that
# held the text before it.
in_order() {
  local last=0 line text
  for text in "$@"; do
    line=$(awk -v from="$last" -v text="$text" 'NR > from && index($0, text) { print NR; exit }' "$dir/ssh.log")
    if [[ -z $line ]]; then
      echo "not recorded after line $last: $text"
      return 1
    fi
    last=$line
  done
}

recorded() {
  grep -qF -- "$1" "$dir/ssh.log"
}

# The recorded commands that remove something. `run --rm` is not one.
removals() {
  grep -E "(^|[ ;&|('])(rm|rmdir) " "$dir/ssh.log"
}

# Fails when a recorded command creates, moves or removes something.
read_only() {
  ! grep -qE "(^|[ ;&|('])(mkdir|rm|rmdir|ln|tar|mv -T) " "$dir/ssh.log"
}

# Every task once, the state-changing ones confirmed, in the order an
# operator runs them, with two deploys so there is a previous release.
everything() {
  mkdir -p "$remote/data/secrets"
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$sentinel" "$sentinel" >"$remote/data/secrets/s3.env"
  healthy o11y
  healthy o11y-gate
  layout
  nas preflight
  nas deploy-plan
  go stage
  go gate-test
  grep '^o11y ' "$dir/containers" >"$dir/containers.keep"
  mv "$dir/containers.keep" "$dir/containers"
  go gate-clean
  go deploy
  rm "$repo/tmp/deploy/staged"
  sleep 1
  go deploy
  nas status
  nas logs
  nas logs loki
  nas grafana-password
  go serve-apply
  nas serve-status
  nas smoke-remote
  nas smoke-remote --grpc
  go rollback
  go rollback --previous
  go serve-clear
  go down
}

# --- confirmation ---------------------------------------------------------

@test "a state-changing task without its confirmation fails and makes no ssh call" {
  for task in "${changing[@]}"; do
    nas "$task"
    [ "$status" -ne 0 ]
    [[ $output == *"O11Y_CONFIRM=$task"* ]]
  done
  [ ! -e "$dir/ssh.log" ]
}

@test "the confirmation of one task does not confirm another" {
  for task in "${changing[@]}"; do
    O11Y_CONFIRM=status nas "$task"
    [ "$status" -ne 0 ]
  done
  O11Y_CONFIRM=stage nas deploy
  [ "$status" -ne 0 ]
  [ ! -e "$dir/ssh.log" ]
}

# --- stage ----------------------------------------------------------------

@test "stage uploads under temporary names, verifies, renames, then pulls on the dummy env file" {
  go stage
  [ "$status" -eq 0 ]
  id=$(staged)
  [[ $output == *"release $id"* ]]
  in_order "mkdir $remote/releases/.incoming-$id && tar -xpf - -C $remote/releases/.incoming-$id" \
    "cd $remote/releases/.incoming-$id && sha256sum -c MANIFEST.sha256" \
    "mv -T $remote/releases/.incoming-$id $remote/releases/$id" \
    "--env-file $remote/releases/$id/.env.validate -f $remote/releases/$id/compose.yaml -f $remote/releases/$id/compose.tools.yaml --profile tools pull"
  # Every rename to a final name follows a verification of that directory.
  while read -r line; do
    incoming=${line#mv -T }
    incoming=${incoming%% *}
    in_order "cd $incoming && sha256sum -c MANIFEST.sha256" "$line"
  done < <(grep '^mv -T ' "$dir/ssh.log")
  [ "$(grep -c '^mv -T ' "$dir/ssh.log")" -eq 9 ]
  [ -f "$remote/releases/$id/compose.yaml" ]
  [ "$(find "$remote" -name '.incoming-*' | wc -l)" -eq 0 ]
  # Nothing starts and nothing live changes.
  ! grep -qE ' (up|run|start|restart) ' "$dir/ssh.log" || false
  ! recorded current || false
  [ ! -e "$remote/current" ]
  [ ! -e "$remote/data" ]
}

@test "stage renders the real values, not the test paths' placeholders or an inherited override" {
  O11Y_SECRETS_OWNER=1000:1000 DOCKER_API_VERSION=1.44 go stage
  [ "$status" -eq 0 ]
  env=$remote/releases/$(staged)/.env
  grep -qx "O11Y_DATA_DIR=$remote/data" "$env"
  grep -qx "O11Y_GRAFANA_ROOT_URL=https://grafana.example.ts.net/" "$env"
  grep -qx "O11Y_S3_ENV_FILE=$remote/data/secrets/s3.env" "$env"
  grep -q "^O11Y_CONFIG_LOKI=$remote/config/loki-" "$env"
  ! grep -q O11Y_SECRETS_OWNER "$env" || false
  ! recorded DOCKER_API_VERSION || false
}

@test "a release that fails verification is not renamed and nothing is pulled" {
  STUB_CORRUPT=releases/.incoming- go stage
  [ "$status" -ne 0 ]
  [[ $output == *"does not match its manifest"* ]]
  ! grep -q "^mv -T $remote/releases/" "$dir/ssh.log" || false
  ! recorded " pull" || false
  [ ! -e "$repo/tmp/deploy/staged" ]
  [ "$(find "$remote/releases" -mindepth 1 -maxdepth 1 ! -name '.incoming-*' | wc -l)" -eq 0 ]
}

@test "a config directory that fails verification stops stage before any rename or pull" {
  STUB_CORRUPT=config/.incoming-alloy go stage
  [ "$status" -ne 0 ]
  ! grep -q '^mv ' "$dir/ssh.log" || false
  ! recorded " pull" || false
  [ -d "$(echo "$remote"/config/.incoming-alloy-*)" ]
}

@test "a final directory that already exists is verified again, neither skipped nor replaced" {
  go stage
  [ "$status" -eq 0 ]
  loki=$(basename "$(echo "$remote"/config/loki-*)")
  rm "$dir/ssh.log"
  go stage
  [ "$status" -eq 0 ]
  in_order "test -e $remote/config/$loki" "cd $remote/config/$loki && sha256sum -c MANIFEST.sha256"
  ! recorded ".incoming-$loki" || false
  echo damaged >>"$remote/config/$loki/config.yaml"
  rm "$dir/ssh.log"
  go stage
  [ "$status" -ne 0 ]
  [[ $output == *"$loki is already on the host and no longer matches its manifest"* ]]
  [ -f "$remote/config/$loki/config.yaml" ]
  ! recorded " pull" || false
  ! grep -q '^mv ' "$dir/ssh.log" || false
}

@test "stage removes the temporary directories an interrupted upload left" {
  mkdir -p "$remote/config/.incoming-stale" "$remote/releases/.incoming-stale"
  go stage
  [ "$status" -eq 0 ]
  [ ! -e "$remote/config/.incoming-stale" ]
  [ ! -e "$remote/releases/.incoming-stale" ]
}

# --- deploy ---------------------------------------------------------------

@test "deploy locks, records the attempt, runs init, up and the health gate, then promotes and unlocks" {
  healthy o11y
  go deploy
  [ "$status" -eq 0 ]
  id=$(staged)
  release=$remote/releases/$id
  in_order "mkdir $remote/.deploy.lock" \
    "echo $id >$remote/attempt.new && mv $remote/attempt.new $remote/attempt" \
    "-p o11y --env-file $release/.env -f $release/compose.init.yaml run --rm -T init" \
    "-p o11y --env-file $release/.env -f $release/compose.yaml up -d" \
    "ps -a --filter label=com.docker.compose.project=o11y " \
    "exec -i o11y-rustfs-1 curl" \
    "ln -sfn releases/$id current.new && mv -T current.new current" \
    "rmdir $remote/.deploy.lock"
  # Init loads the init file alone, and the stack is never taken for orphans.
  ! grep 'compose.init.yaml' "$dir/ssh.log" | grep -qE 'compose\.yaml|remove-orphans' || false
  ! grep 'compose.tools.yaml' "$dir/ssh.log" | grep -q 'remove-orphans' || false
  # A first deploy has nothing to call previous.
  ! recorded previous || false
  [ "$(readlink "$remote/current")" = "releases/$id" ]
  [ "$(cat "$remote/attempt")" = "$id" ]
  [ ! -e "$remote/.deploy.lock" ]
  grep -qF "[curl=bash tools/nas.sh in-network-curl o11y-rustfs-1 otlp=http://alloy:4318 grafana=http://grafana:3000]" "$dir/tools.log"
  # The gate asked for the readiness of all six, not only what changed.
  for port in 9000 3100 3200 8080 12345 3000; do
    recorded ":$port/"
  done
}

@test "deploy uses the release stage produced and uploads nothing again" {
  healthy o11y
  go stage
  id=$(staged)
  rm "$dir/ssh.log"
  go deploy
  [ "$status" -eq 0 ]
  ! recorded "tar -xpf" || false
  in_order "cd $remote/releases/$id && sha256sum -c MANIFEST.sha256" "mkdir $remote/.deploy.lock"
  [ "$(readlink "$remote/current")" = "releases/$id" ]
}

@test "a second deploy moves previous before current" {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged" "$dir/ssh.log"
  sleep 1
  go deploy
  [ "$status" -eq 0 ]
  second=$(staged)
  [ "$first" != "$second" ]
  in_order "exec -i o11y-rustfs-1 curl" \
    "ln -sfn releases/$first previous.new && mv -T previous.new previous" \
    "ln -sfn releases/$second current.new && mv -T current.new current" \
    "rmdir $remote/.deploy.lock"
  [ "$(readlink "$remote/previous")" = "releases/$first" ]
  [ "$(readlink "$remote/current")" = "releases/$second" ]
}

@test "a failed health gate on a first deploy promotes nothing, unlocks, and names the first-deploy cleanup" {
  go deploy
  [ "$status" -ne 0 ]
  ! recorded "mv -T current.new" || false
  ! recorded "mv -T previous.new" || false
  [ ! -e "$remote/current" ]
  [ ! -e "$remote/.deploy.lock" ]
  recorded "rmdir $remote/.deploy.lock"
  [[ $output == *"was not promoted"* ]]
  [[ $output == *"First-deploy cleanup"*"O11Y_CONFIRM=down mise run down"* ]]
  [[ $output != *"mise run rollback"* ]]
}

@test "a failed receipt after an earlier deploy promotes nothing, unlocks, and names rollback" {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged" "$dir/ssh.log"
  sleep 1
  STUB_RECEIPT_FAIL=1 go deploy
  [ "$status" -ne 0 ]
  ! recorded "mv -T current.new" || false
  ! recorded "mv -T previous.new" || false
  [ "$(readlink "$remote/current")" = "releases/$first" ]
  [ ! -e "$remote/previous" ]
  [ ! -e "$remote/.deploy.lock" ]
  [[ $output == *"O11Y_CONFIRM=rollback mise run rollback"* ]]
}

@test "a service that is up but not ready fails the health gate" {
  healthy o11y
  STUB_HTTP=503 go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"is not ready"* ]]
  [ ! -e "$remote/current" ]
  [ ! -e "$dir/tools.log" ]
}

@test "a run that finds the lock taken issues neither init nor up and leaves the lock alone" {
  healthy o11y
  go stage
  mkdir "$remote/.deploy.lock"
  rm "$dir/ssh.log"
  go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"the deploy lock exists"* ]]
  ! recorded " init" || false
  ! recorded " up " || false
  ! recorded rmdir || false
  [ -d "$remote/.deploy.lock" ]
}

# --- pointers: rollback, down ---------------------------------------------

@test "rollback uses current, --previous uses previous, and both run the health gate" {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged"
  sleep 1
  go deploy
  second=$(staged)
  rm "$dir/ssh.log" "$dir/tools.log"
  go rollback
  [ "$status" -eq 0 ]
  in_order "mkdir $remote/.deploy.lock" "-f $remote/releases/$second/compose.yaml up -d" "exec -i o11y-rustfs-1 curl" "rmdir $remote/.deploy.lock"
  ! recorded "releases/$first/" || false
  [ -f "$dir/tools.log" ]
  rm "$dir/ssh.log"
  go rollback --previous
  [ "$status" -eq 0 ]
  recorded "-f $remote/releases/$first/compose.yaml up -d"
  ! recorded "releases/$second/" || false
  ! recorded "mv -T" || false
}

@test "rollback fails when the pointer it needs does not exist" {
  go rollback
  [ "$status" -ne 0 ]
  ! recorded " up " || false
  ! recorded "mkdir" || false
}

@test "down uses current when it exists" {
  healthy o11y
  go deploy
  id=$(staged)
  echo 20200101T000000Z-abc1234 >"$remote/attempt"
  rm "$dir/ssh.log"
  go down
  [ "$status" -eq 0 ]
  in_order "mkdir $remote/.deploy.lock" "-p o11y --env-file $remote/releases/$id/.env.validate -f $remote/releases/$id/compose.yaml down" "rmdir $remote/.deploy.lock"
  ! recorded 20200101T000000Z || false
  ! grep ' down' "$dir/ssh.log" | grep -qE -e ' -v|--volumes|--rmi|remove-orphans' || false
}

@test "down uses the recorded attempt when no release was ever promoted" {
  go deploy
  [ "$status" -ne 0 ]
  id=$(staged)
  [ ! -e "$remote/current" ]
  rm "$dir/ssh.log"
  go down
  [ "$status" -eq 0 ]
  recorded "-f $remote/releases/$id/compose.yaml down"
}

@test "down stops when the host cannot be asked which release is current" {
  healthy o11y
  go deploy
  STUB_SSH_DOWN=1 go down
  [ "$status" -ne 0 ]
  [[ $output == *"could not be asked for current"* ]]
  [[ $output != *attempt* ]]
}

@test "down fails when there is neither a promoted release nor an attempt" {
  mkdir -p "$remote"
  go down
  [ "$status" -ne 0 ]
  ! recorded " down" || false
}

# --- gate -----------------------------------------------------------------

@test "gate-test rehearses in the o11y-gate project on its own data directory and ports, then stops it" {
  healthy o11y-gate
  layout
  go gate-test
  [ "$status" -eq 0 ]
  release=$(echo "$remote"/gate/releases/*)
  grep -qx "O11Y_DATA_DIR=$remote/gate/data" "$release/.env"
  grep -qx "O11Y_GRAFANA_PORT=13000" "$release/.env"
  grep -qx "O11Y_OTLP_GRPC_PORT=14317" "$release/.env"
  grep -qx "O11Y_OTLP_HTTP_PORT=14318" "$release/.env"
  # Only the gate project, and its last Compose command is down.
  ! grep -F "$O11Y_REMOTE_COMPOSE" "$dir/ssh.log" | grep -qv -e ' -p o11y-gate ' || false
  [[ $(grep -F "$O11Y_REMOTE_COMPOSE" "$dir/ssh.log" | tail -n 1) == *" -p o11y-gate "*" -f $release/compose.yaml down --remove-orphans" ]]
  # Orphans are removed only by the gate project's down, which also takes
  # the one-off containers a failed probe can leave; first a leftover run's,
  # then this run's.
  [ "$(grep -c 'remove-orphans' "$dir/ssh.log")" -eq 2 ]
  [ "$(grep -c " -p o11y-gate --env-file $release/.env.validate -f $release/compose.yaml down --remove-orphans$" "$dir/ssh.log")" -eq 2 ]
  # Each image's own binary, with no shell.
  for binary in "/usr/bin/loki grafana/loki:" "/tempo grafana/tempo:" "/bin/mimir grafana/mimir:" \
    "/bin/alloy grafana/alloy:" "grafana grafana/grafana:" "rustfs rustfs/rustfs:" \
    "/telemetrygen ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:" "/usr/local/bin/aws amazon/aws-cli:"; do
    grep -F -- "run --rm --network none --entrypoint $binary" "$dir/ssh.log" | grep -qv '/bin/sh'
  done
  grep -qF "rustfs-probe.sh --release $release --project o11y-gate -- bash tools/nas.sh remote-compose" "$dir/tools.log"
  grep -qF "receipt.sh --state-file" "$dir/tools.log"
  grep -qF "receipt.sh --recheck" "$dir/tools.log"
  # Local state is emptied under the gate data directory only.
  in_order "rm -sf loki" "-v $remote/gate/data/loki:/d" "up -d loki" "restart tempo" "restart mimir" "stop \$ids && " " down"
  # Only Loki's local state is emptied; Tempo's could race its upload.
  [ "$(grep -c -e '-v .*/gate/data/[a-z]*:/d' "$dir/ssh.log")" -eq 1 ]
  ! recorded "rm -sf tempo" || false
  [ ! -e "$remote/current" ]
  [ ! -e "$remote/attempt" ]
}

@test "gate-test reports a filesystem RustFS refuses as that, and still stops the project" {
  healthy o11y-gate
  layout
  echo "[FATAL] Server runtime failed: Unsupported filesystem type detected for RustFS local endpoints: /data (BTRFS)." >"$dir/rustfs.log"
  STUB_PROBE_FAIL=1 go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"RustFS refused to start on the filesystem"* ]]
  [[ $(grep -F "$O11Y_REMOTE_COMPOSE" "$dir/ssh.log" | tail -n 1) == *" -p o11y-gate "*" down --remove-orphans" ]]
}

@test "gate-test reports any other probe failure as a probe failure" {
  healthy o11y-gate
  layout
  STUB_PROBE_FAIL=1 go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"the RustFS probe failed"* ]]
  [[ $output != *"refused to start"* ]]
}

@test "gate-test refuses to rehearse on the data of an earlier run" {
  mkdir -p "$remote/gate/data"
  go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"gate-clean"* ]]
  ! recorded " up " || false
  ! recorded " run " || false
}

@test "gate-test fails when the layout under the gate data directory differs" {
  healthy o11y-gate
  layout
  sed -i.bak 's/^secrets 0:0 755$/secrets 0:0 777/' "$dir/layout"
  go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"differ from the layout"* ]]
}

@test "gate-clean refuses while an o11y-gate container exists" {
  mkdir -p "$remote/gate/data"
  healthy o11y-gate
  go gate-clean
  [ "$status" -ne 0 ]
  ! recorded " run " || false
  [ -z "$(removals)" ]
  [ -d "$remote/gate/data" ]
}

@test "gate-clean removes the gate directory and nothing else" {
  mkdir -p "$remote/gate/data/loki" "$remote/gate/releases" "$remote/data" "$remote/config" "$remote/releases"
  healthy o11y
  go gate-clean
  [ "$status" -eq 0 ]
  recorded "run --rm --log-driver none --user 0:0 --network none --entrypoint /bin/sh -v $remote/gate:/d "
  [ "$(grep -c -e '-v ' "$dir/ssh.log")" -eq 1 ]
  [ "$(removals | wc -l)" -eq 2 ]
  recorded "rmdir $remote/gate"
  [ ! -e "$remote/gate" ]
  [ -d "$remote/data" ]
  [ -d "$remote/config" ]
  [ -d "$remote/releases" ]
}

# --- serve ----------------------------------------------------------------

@test "serve-apply issues the three mappings in order, without sudo" {
  go serve-apply
  [ "$status" -eq 0 ]
  t=$O11Y_REMOTE_TAILSCALE
  [ "$(cat "$dir/ssh.log")" = "$t serve --service=svc:grafana --https=443 http://127.0.0.1:3000
$t serve --service=svc:otlp --https=4318 http://127.0.0.1:4318
$t serve --service=svc:otlp --https=4317 http://127.0.0.1:4317
$t serve status" ]
  [ ! -e "$dir/sudo.log" ]
}

@test "serve-apply that is refused says the owner must set an operator user, and stops" {
  STUB_SERVE_DENIED=1 go serve-apply
  [ "$status" -ne 0 ]
  [[ $output == *"set an operator user"* ]]
  [ "$(wc -l <"$dir/ssh.log")" -eq 1 ]
  [ ! -e "$dir/sudo.log" ]
}

@test "serve-clear drains and clears the two services and never resets" {
  go serve-clear
  [ "$status" -eq 0 ]
  in_order "serve drain svc:grafana" "serve drain svc:otlp" "serve clear svc:grafana" "serve clear svc:otlp"
  ! recorded reset || false
  [ ! -e "$dir/sudo.log" ]
}

# --- read-only tasks ------------------------------------------------------

@test "deploy-plan prints images, ports, the release id, the env file and the commands, with no ssh call" {
  nas deploy-plan
  [ "$status" -eq 0 ]
  [ ! -e "$dir/ssh.log" ]
  [[ $output == *"release id: "*"-abc1234"* ]]
  [[ $output == *"rustfs rustfs/rustfs:"*"@sha256:"* ]]
  [[ $output == *"grafana 127.0.0.1:3000 -> 3000"* ]]
  [[ $output == *"alloy 127.0.0.1:4317 -> 4317"* ]]
  [[ $output == *"O11Y_DATA_DIR=$remote/data"* ]]
  [[ $output == *"compose.init.yaml run --rm -T init"* ]]
  [[ $output == *"compose.yaml up -d --remove-orphans"* ]]
  [[ $output == *"mv -T current.new current"* ]]
}

@test "preflight changes nothing on the host" {
  nas preflight
  [ "$status" -eq 0 ]
  [[ $output == *"ok preflight: sudo -n runs docker-compose"* ]]
  [ ! -e "$remote" ]
  read_only
}

@test "preflight fails when the host's Compose is not the pinned version" {
  stub "$host/bin/docker-compose" <<<'echo v2.24.5'
  nas preflight
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL preflight: sudo -n runs docker-compose"* ]]
}

@test "status reports the current release and readiness without changing anything" {
  healthy o11y
  go deploy
  id=$(staged)
  rm "$dir/ssh.log"
  nas status
  [ "$status" -eq 0 ]
  [[ $output == *"current release: $id"* ]]
  [[ $output == *"rustfs (release 20260101T000000Z-abc1234) Up 1 minute (healthy)"* ]]
  [[ $output == *"mimir ready"* ]]
  [[ $output != *"$remote/releases"* ]]
  recorded "stats --no-stream"
  recorded "serve status"
  read_only
}

@test "logs tails 200 lines on the dummy env file and rejects an unknown service" {
  healthy o11y
  go deploy
  release=$remote/releases/$(staged)
  nas logs loki
  [ "$status" -eq 0 ]
  recorded "-p o11y --env-file $release/.env.validate -f $release/compose.yaml logs --no-color --tail=200 loki"
  rm "$dir/ssh.log"
  nas logs 'loki; id'
  [ "$status" -ne 0 ]
  [ ! -s "$dir/ssh.log" ] || ! recorded logs
}

@test "grafana-password reads the one password file from the running container" {
  healthy o11y
  nas grafana-password
  [ "$status" -eq 0 ]
  [ "$output" = stub-grafana-password ]
  [ "$(wc -l <"$dir/ssh.log")" -eq 1 ]
  recorded "cat /run/o11y/grafana_admin_password"
}

@test "smoke-remote checks receipt through both Services from this machine, with no ssh call" {
  nas smoke-remote
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/tools.log")" = "receipt.sh  [curl=curl otlp=https://otlp.example.ts.net:4318 grafana=https://grafana.example.ts.net]" ]
  nas smoke-remote --grpc
  [ "$status" -eq 0 ]
  grep -qE '^receipt.sh --grpc -- docker run --rm --add-host otlp\.example\.ts\.net:192\.0\.2\.20 ghcr\.io/[^ ]+@sha256:[0-9a-f]+ traces --otlp-endpoint otlp\.example\.ts\.net:4317 \[' "$dir/tools.log"
  [ ! -e "$dir/ssh.log" ]
}

# --- plumbing -------------------------------------------------------------

@test "in-network curl arguments reach curl unsplit, through the remote shell" {
  run bash "$repo/tools/nas.sh" in-network-curl o11y-rustfs-1 -H 'Content-Type: application/json' \
    -w '%{http_code}' 'http://grafana:3000/x?query={a="b"}&start=1' "it's" '$HOME;id'
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/docker.args")" = 'exec
-i
o11y-rustfs-1
curl
-H
Content-Type: application/json
-w
%{http_code}
http://grafana:3000/x?query={a="b"}&start=1
it'"'"'s
$HOME;id' ]
}

@test "in-network curl rejects a container name that is not one" {
  run bash "$repo/tools/nas.sh" in-network-curl '-it; id' -s http://x
  [ "$status" -ne 0 ]
  [ ! -e "$dir/ssh.log" ]
}

@test "the Compose passthrough serves the gate project only" {
  run bash "$repo/tools/nas.sh" remote-compose -p o11y down
  [ "$status" -ne 0 ]
  [ ! -e "$dir/ssh.log" ]
  run bash "$repo/tools/nas.sh" remote-compose -p o11y-gate exec -T rustfs curl -w '%{http_code}' http://127.0.0.1:9000/
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/ssh.log")" = "sudo -n $O11Y_REMOTE_COMPOSE -p o11y-gate exec -T rustfs curl -w '%{http_code}' http://127.0.0.1:9000/" ]
}

# --- validation -----------------------------------------------------------

@test "a bad value is rejected by name before any ssh call" {
  bad() {
    local name=${1%%=*}
    env "$1" O11Y_CONFIRM=stage bash "$repo/tools/nas.sh" stage >"$dir/out" 2>&1 && return 1
    grep -q "$name" "$dir/out" || return 1
    # The message names the variable and never repeats the value.
    [ "${#1}" -lt "$((${#name} + 6))" ] || ! grep -qF -- "${1#*=}" "$dir/out"
  }
  bad O11Y_SSH_HOST=-oProxyCommand=id
  bad 'O11Y_SSH_HOST=nas example'
  bad O11Y_SSH_HOST=
  bad O11Y_REMOTE_DIR=srv/o11y
  bad O11Y_REMOTE_DIR=/srv/../etc
  bad O11Y_REMOTE_DIR=/srv/o11y/..
  bad O11Y_REMOTE_DIR=/srv//o11y
  bad O11Y_REMOTE_DIR=/srv/o11y/
  bad 'O11Y_REMOTE_DIR=/srv/o11y;id'
  bad O11Y_REMOTE_DOCKER=docker
  bad O11Y_REMOTE_COMPOSE=/usr/bin/../bin/docker-compose
  bad O11Y_TAILNET_DOMAIN=-bad.example.ts.net
  bad O11Y_TAILNET_DOMAIN=example
  bad O11Y_GRAFANA_PORT=0
  bad O11Y_OTLP_GRPC_PORT=65536
  bad O11Y_OTLP_HTTP_PORT=-1
  bad O11Y_OTLP_HTTP_PORT=4318x
  [ ! -e "$dir/ssh.log" ]
}

@test "a task checks only the variables it uses" {
  O11Y_REMOTE_TAILSCALE=tailscale O11Y_TAILNET_DOMAIN=- nas grafana-password
  [ "$status" -eq 0 ]
  O11Y_REMOTE_TAILSCALE=tailscale nas serve-status
  [ "$status" -ne 0 ]
  [[ $output == *O11Y_REMOTE_TAILSCALE* ]]
}

@test "O11Y_PRIVATE_STRINGS is never validated, empty or not" {
  nas serve-status
  [ "$status" -eq 0 ]
  O11Y_PRIVATE_STRINGS='-x,../y,a b;c' nas serve-status
  [ "$status" -eq 0 ]
}

# --- across every task ----------------------------------------------------

@test "every Compose call names its project and none is the docker compose plugin" {
  everything
  [ "$(grep -cF "$O11Y_REMOTE_COMPOSE" "$dir/sudo.log")" -gt 20 ]
  ! grep -F "$O11Y_REMOTE_COMPOSE" "$dir/sudo.log" | grep -v 'version --short' | grep -qvE "^-n $O11Y_REMOTE_COMPOSE -p (o11y|o11y-gate) " || false
  ! recorded "docker compose" || false
  ! recorded "$O11Y_REMOTE_DOCKER compose" || false
}

@test "sudo is only ever sudo -n on the docker or docker-compose path, and utility containers override user and entrypoint" {
  everything
  [ "$(grep -o 'sudo [^ ]* [^ ]*' "$dir/ssh.log" | sort -u)" = "sudo -n $O11Y_REMOTE_DOCKER
sudo -n $O11Y_REMOTE_COMPOSE" ]
  ! grep -qv -e "^-n $O11Y_REMOTE_DOCKER " -e "^-n $O11Y_REMOTE_COMPOSE " "$dir/sudo.log" || false
  ! grep -F "$O11Y_REMOTE_TAILSCALE" "$dir/sudo.log" || false
  runs=$(grep -F "$O11Y_REMOTE_DOCKER run " "$dir/ssh.log")
  # Eight version checks, the layout listing, Loki's emptying, gate-clean.
  [ "$(wc -l <<<"$runs")" -eq 11 ]
  ! grep -qv -e '--entrypoint ' <<<"$runs" || false
  ! grep -e '--entrypoint /bin/sh' <<<"$runs" | grep -qv -e '--user 0:0 ' || false
  [ "$(grep -c -e '--entrypoint /bin/sh' <<<"$runs")" -eq 3 ]
}

@test "no task reads a generated secret, prints a model or an environment, or lets the S3 key into its output" {
  everything
  # The stubs answer `config` without -q, `inspect` and a look at a
  # container's environment with the env file that holds the sentinel.
  ! grep -rqF "$sentinel" "$dir/output" "$repo/tmp" || false
  ! grep -qE '(^|[ ;&|(])(cat|head|tail|less|more|cp|scp|dd|od|grep|sed|awk|base64|tar) [^;&|]*(secrets|s3\.env|access_key|secret_key)' "$dir/ssh.log" || false
  ! grep -q secrets "$dir/tar.log" || false
  ! grep -qE ' config( |$)' "$dir/sudo.log" || false
  ! grep -qE '(^| )(inspect|printenv|env)( |$)' "$dir/sudo.log" || false
  [ "$(grep -c grafana_admin_password "$dir/ssh.log")" -eq 1 ]
  # Locally, `config` only ever loads the dummy env file.
  ! grep ' config' "$dir/compose.log" | grep -qv -e '--env-file [^ ]*/\.env\.validate ' || false
}

@test "orphans are removed only by a production up or the gate project's down, each on compose.yaml alone" {
  everything
  orphans=$(grep -e '--remove-orphans' "$dir/ssh.log")
  [ -n "$(grep -E ' -p o11y-gate .* down --remove-orphans$' <<<"$orphans")" ]
  ! grep -vE -e ' -p o11y --env-file [^ ]*/\.env -f [^ ]*/compose\.yaml up -d --remove-orphans$' \
    -e ' -p o11y-gate --env-file [^ ]*/\.env\.validate -f [^ ]*/compose\.yaml down --remove-orphans$' <<<"$orphans" || false
}

@test "no task removes anything under releases, config or data" {
  everything
  kept=$(removals | grep -v -e " rm -sf " -e "$remote/gate")
  ! grep -v -e "^mkdir -p $remote/config $remote/releases && rm -rf $remote/config/.incoming-\* $remote/releases/.incoming-\*$" \
    -e "^rmdir $remote/.deploy.lock$" <<<"$kept" || false
  [ -n "$kept" ]
  # What the gate removes sits under the gate directory.
  ! removals | grep -F "$remote/gate" | grep -qE "$remote/(data|releases|config)/[^.]" || false
  [ -d "$remote/data/secrets" ]
  [ "$(find "$remote/releases" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ]
}

@test "every task in the operator's order succeeds against the fake host" {
  everything
  ! grep -n '^FAIL' "$dir/output" || false
  [ "$(grep -c '^ok ' "$dir/output")" -ge 15 ]
}
