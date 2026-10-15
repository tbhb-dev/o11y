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
  # every connection fail, and STUB_SSH_FAIL_ON (a glob) the matching ones.
  # STUB_ON_LOCK runs before each attempt at the lock, STUB_ON_VERIFY once
  # before the first manifest check, as another run would in between.
  # STUB_SIGNAL_ON (a glob) sends the task SIGTERM, as an operator might.
  stub "$dir/bin/ssh" <<'STUB'
for command; do :; done
[ -z "${STUB_SSH_DOWN:-}" ] || exit 255
if [ -n "${STUB_SSH_RESOLVE_FAIL:-}" ]; then
  echo "ssh: Could not resolve hostname $O11Y_SSH_HOST: Name or service not known" >&2
  exit 255
fi
if [ -n "${STUB_SSH_RESOLVE_FAIL_ON:-}" ]; then
  # shellcheck disable=SC2254 # the variable is a pattern
  case $command in
  $STUB_SSH_RESOLVE_FAIL_ON)
    echo "ssh: Could not resolve hostname $O11Y_SSH_HOST: Name or service not known" >&2
    exit 255
    ;;
  esac
fi
if [ -n "${STUB_SSH_FAIL_ON:-}" ]; then
  # shellcheck disable=SC2254 # the variable is a pattern
  case $command in $STUB_SSH_FAIL_ON) exit 255 ;; esac
fi
case $command in
*"mkdir $O11Y_REMOTE_DIR/.deploy.lock"*) [ -z "${STUB_ON_LOCK:-}" ] || sh -c "$STUB_ON_LOCK" ;;
*"sha256sum -c"*)
  if [ -n "${STUB_ON_VERIFY:-}" ] && [ ! -e "$STUB/verify.hooked" ]; then
    : >"$STUB/verify.hooked"
    sh -c "$STUB_ON_VERIFY"
  fi
  ;;
esac
printf '%s\n' "$command" >>"$STUB/ssh.log"
if [ -n "${STUB_SIGNAL_ON:-}" ]; then
  # shellcheck disable=SC2254
  case $command in $STUB_SIGNAL_ON) kill -TERM "$PPID" ;; esac
fi
# STUB_HOLD_ON (a glob) marks the moment and holds the command three
# seconds, long enough for a test to signal the task while it runs.
if [ -n "${STUB_HOLD_ON:-}" ]; then
  # shellcheck disable=SC2254
  case $command in $STUB_HOLD_ON) : >"$STUB/held" && sleep 3 ;; esac
fi
sh -c "$command"
status=$?
# STUB_LEAK_ON (a glob) leaves a process behind after the command, the way
# an SSH connection master can. With STUB_LEAK_KIND=fd9 it keeps only the
# descriptors beyond the standard three; with stdout it keeps stdout.
if [ -n "${STUB_LEAK_ON:-}" ]; then
  # shellcheck disable=SC2254
  case $command in
  $STUB_LEAK_ON)
    case ${STUB_LEAK_KIND:-} in
    stdout) sleep 30 </dev/null 2>/dev/null & ;;
    stderr) sleep 30 </dev/null >/dev/null & ;;
    *) sleep 30 </dev/null >/dev/null 2>&1 & ;;
    esac
    echo $! >>"$STUB/leaked-processes"
    ;;
  esac
fi
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
# STUB_DOCKER_ERROR makes docker fail the way a broken daemon does, naming
# the host and a path in its message.
if [ -n "${STUB_DOCKER_ERROR:-}" ]; then
  echo "error during connect on $O11Y_SSH_HOST: open $O11Y_REMOTE_DIR/x: no such file" >&2
  exit 1
fi
project=${all##*label=com.docker.compose.project=}
project=${project%% *}
case $1 in
ps)
  case $all in
  *label=com.docker.compose.project=*) ;;
  *)
    # The whole host's containers, with private names in them.
    echo "minio-1 minio $O11Y_REMOTE_DIR/other Up 2 days $O11Y_SSH_HOST"
    exit 0
    ;;
  esac
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
  *)
    # Without -a only running containers count.
    case " $* " in *" -a"*) running= ;; *) running=1 ;; esac
    awk -v p="$project" -v s="$service" -v r="$running" \
      '$1 == p && (s == "" || $2 == s) && (r == "" || $5 == "Up") { print $3 }' "$STUB/containers"
    ;;
  esac
  ;;
exec)
  case $all in
  *grafana_admin_password*) echo stub-grafana-password ;;
  *" env"* | *printenv*) cat "$O11Y_REMOTE_DIR/data/secrets/s3.env" ;;
  *"-X POST"*)
    printf 204
    [ -z "${STUB_FLUSH_THEN_FAILS:-}" ] || exit 255
    ;;
  *api/v1/query*)
    # Mimir through Grafana: the five self-scrapes, up, unless
    # STUB_SELF_DOWN leaves Tempo out.
    jobs="alloy grafana loki mimir tempo"
    [ -z "${STUB_SELF_DOWN:-}" ] || jobs="alloy grafana loki mimir"
    printf '{"status":"success","data":{"result":['
    sep=
    for job in $jobs; do
      printf '%s{"metric":{"job":"o11y/%s","cluster":"o11y","namespace":"o11y"},"value":[0,"1"]}' "$sep" "$job"
      sep=,
    done
    printf ']}}'
    ;;
  *curl*)
    printf '%s' "${STUB_HTTP:-200}"
    # STUB_HTTP_THEN_FAILS answers, then fails, as a dropped connection can.
    [ -z "${STUB_HTTP_THEN_FAILS:-}" ] || exit 255
    ;;
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
version) echo "client 24.0.2, server 24.0.2 on $O11Y_SSH_HOST" ;;
stats)
  # No container named: the real one lists every container on the host.
  [ "$#" -gt 4 ] || echo "stats of every container on the host"
  ;;
esac
exit 0
STUB
  # `config` without -q prints the env file a model loads, as the real one
  # does. The host's dockerd refuses to create a missing bind mount source,
  # so a run or up whose data or config directory is missing fails.
  stub "$host/bin/docker-compose" <<'STUB'
all="$*"
case $all in *"${STUB_FAIL:-no failure}"*) exit 1 ;; esac
case " $all " in
*" run "* | *" up "*)
  env_file=${all#*--env-file }
  for source in $(grep -E '^O11Y_(DATA_DIR|CONFIG_[A-Z]+)=' "${env_file%% *}" | cut -d= -f2-); do
    [ -e "$source" ] || {
      echo "Error response from daemon: Bind mount failed: '$source' does not exist" >&2
      exit 1
    }
  done
  ;;
esac
# STUB_FAIL_SECOND fails the second call that matches it.
case $all in
*"${STUB_FAIL_SECOND:-no failure}"*)
  echo x >>"$STUB/fail-second.count"
  [ "$(wc -l <"$STUB/fail-second.count")" -ne 2 ] || exit 1
  ;;
esac
# STUB_NOISY makes down print a lot, as a real one does on a slow host.
case $all in
*" down"*) [ -z "${STUB_NOISY:-}" ] || seq 1 5000 | sed 's/^/Container stopping /' ;;
esac
case $all in
*" config"*) case $all in *" -q"*) ;; *) cat "$O11Y_REMOTE_DIR/data/secrets/s3.env" ;; esac ;;
*"version --short"*) echo v2.20.1-stub ;;
*"s3probe count"*)
  echo 3
  # STUB_COUNT_FAILS prints a count, then fails, as a dropped connection can.
  [ -z "${STUB_COUNT_FAILS:-}" ] || exit 255
  ;;
*logs*rustfs*) [ ! -f "$STUB/rustfs.log" ] || cat "$STUB/rustfs.log" ;;
*logs*)
  # Grafana logs the environment overrides it starts with.
  echo "logger=settings msg=\"Config overridden from Environment variable\" var=\"GF_SERVER_ROOT_URL=https://grafana.$O11Y_TAILNET_DOMAIN/\""
  ;;
esac
exit 0
STUB
  stub "$host/bin/tailscale" <<'STUB'
case "$*" in
version) echo 1.104.1 ;;
"serve status")
  if [ -n "${STUB_SERVE_CONFIG:-}" ]; then
    # What a configured host shows: its names and tailnet addresses.
    echo "https://grafana.$O11Y_TAILNET_DOMAIN (tailnet only) on $O11Y_SSH_HOST"
    echo "|-- / proxy http://127.0.0.1:3000 at 100.$((64 + 37)).2.3 and fd7a:115c:a1e""0::1 $O11Y_PRIVATE_STRINGS"
  else
    echo "No serve config"
  fi
  ;;
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
  # The probe starts with init, which the host refuses while the release's
  # data directory is missing.
  stub "$repo/tools/rustfs-probe.sh" <<'STUB'
echo "rustfs-probe.sh $*" >>"$STUB/tools.log"
[ -d "$(grep '^O11Y_DATA_DIR=' "$2/.env" | cut -d= -f2-)" ] || exit 1
[ -z "${STUB_PROBE_FAIL:-}" ]
STUB

  # STUB_RAW_SED_DIES ends the prefixing diagnostics writer of an earlier version
  # at once, and STUB_GREP_FAILS makes its line filter fail; the current
  # script uses neither, and must not care.
  stub "$dir/bin/sed" <<'STUB'
case "$*" in *'raw| '*) [ -z "${STUB_RAW_SED_DIES:-}" ] || exit 0 ;; esac
exec "$STUB_SED" "$@"
STUB
  stub "$dir/bin/grep" <<'STUB'
case "$*" in
*'^raw| '*)
  if [ -n "${STUB_GREP_FAILS:-}" ]; then
    cat >/dev/null
    exit 2
  fi
  ;;
esac
exec "$STUB_GREP" "$@"
STUB
  # STUB_TR_FAILS makes the tr that strips carriage returns fail after
  # passing its input through.
  stub "$dir/bin/tr" <<'STUB'
if [ -n "${STUB_TR_FAILS:-}" ] && [ "$*" = '-d \r' ]; then
  cat
  exit 2
fi
exec "$STUB_TR" "$@"
STUB
  # STUB_TAIL_FAILS makes tail fail, so the operator's copy of the output
  # can't be shown.
  stub "$dir/bin/tail" <<'STUB'
[ -z "${STUB_TAIL_FAILS:-}" ] || exit 1
exec "$STUB_TAIL" "$@"
STUB
  # The free space under the deploy directory, in kilobytes, for df -Pk:
  # STUB_DISK_FREE of STUB_DISK_TOTAL, 500 GiB of 1000 GiB unless a test
  # says otherwise. Any other df call goes to the real one.
  stub "$dir/bin/df" <<'STUB'
if [ "$1" = -Pk ]; then
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  echo "/dev/fake ${STUB_DISK_TOTAL:-1048576000} 0 ${STUB_DISK_FREE:-524288000} 50% /"
  exit 0
fi
exec "$STUB_DF" "$@"
STUB
  STUB_DF=$(command -v df)
  STUB_TAR=$(command -v tar)
  STUB_TAIL=$(command -v tail)
  STUB_SED=$(command -v sed)
  STUB_GREP=$(command -v grep)
  STUB_TR=$(command -v tr)
  export STUB=$dir STUB_DF STUB_TAR STUB_TAIL STUB_SED STUB_GREP STUB_TR PATH="$dir/bin:$PATH"
  export O11Y_COMPOSE=$dir/bin/compose O11Y_HEALTH_TIMEOUT=0
  export O11Y_SSH_HOST=nas.example.invalid O11Y_REMOTE_DIR=$remote
  export O11Y_REMOTE_DOCKER=$host/bin/docker O11Y_REMOTE_COMPOSE=$host/bin/docker-compose
  export O11Y_REMOTE_TAILSCALE=$host/bin/tailscale O11Y_TAILNET_DOMAIN=example.ts.net
  export O11Y_NODE_ADDR=192.0.2.10 O11Y_PRIVATE_STRINGS=
  unset O11Y_CONFIRM O11Y_DISK_RESERVE_GB O11Y_GRAFANA_PORT O11Y_OTLP_GRPC_PORT O11Y_OTLP_HTTP_PORT O11Y_SECRETS_OWNER
  changing=(stage gate-test gate-clean deploy rollback down serve-apply serve-clear)
  sentinel=NasSentinelSecretNotARealSecret000000000
}

teardown() {
  # A run that hung leaves its processes behind; they all carry this copy's
  # path.
  pkill -f "$repo/tools/nas.sh" 2>/dev/null || true
  if [ -f "$dir/leaked-processes" ]; then
    xargs kill <"$dir/leaked-processes" 2>/dev/null || true
  fi
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
    [[ $output == *"O11Y_CONFIRM=$task"* ]] || false
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
  [[ $output == *"release $id"* ]] || false
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
  [[ $output == *"does not match its manifest"* ]] || false
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
  [[ $output == *"$loki is already on the host and no longer matches its manifest"* ]] || false
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

@test "a first deploy creates the data directory as the SSH user before init mounts it" {
  healthy o11y
  [ ! -e "$remote/data" ]
  go deploy
  [ "$status" -eq 0 ]
  id=$(staged)
  in_order "echo $id >$remote/attempt.new" "mkdir -p -m 755 $remote/data" "-f $remote/releases/$id/compose.init.yaml run --rm -T init"
  [[ $(grep -F "mkdir -p -m 755 $remote/data" "$dir/ssh.log") != *sudo* ]] || false
  [ -d "$remote/data" ]
}

@test "a later deploy leaves an existing data directory as it is" {
  healthy o11y
  mkdir -p "$remote/data/secrets"
  chmod 700 "$remote/data"
  go deploy
  [ "$status" -eq 0 ]
  [ -d "$remote/data/secrets" ]
  [ -n "$(find "$remote/data" -maxdepth 0 -perm 700)" ]
}

@test "deploy stops before init when the data directory can't be created" {
  healthy o11y
  STUB_SSH_FAIL_ON="mkdir -p -m 755 $remote/data" go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"the data directory could not be created"* ]]
  ! recorded " run --rm -T init" || false
}

@test "deploy uses the release stage produced and uploads nothing again" {
  healthy o11y
  go stage
  id=$(staged)
  rm "$dir/ssh.log"
  go deploy
  [ "$status" -eq 0 ]
  ! recorded "tar -xpf" || false
  in_order "mkdir $remote/.deploy.lock" "cd $remote/releases/$id && sha256sum -c MANIFEST.sha256" "rmdir $remote/.deploy.lock"
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
  # Both new links first, then both renames, in one remote command.
  in_order "exec -i o11y-rustfs-1 curl" \
    "cd $remote && ln -sfn releases/$second current.new && ln -sfn releases/$first previous.new && mv -T previous.new previous && mv -T current.new current" \
    "rmdir $remote/.deploy.lock"
  [ "$(grep -c 'current.new' "$dir/ssh.log")" -eq 1 ]
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
  [[ $output == *"was not promoted"* ]] || false
  [[ $output == *"First-deploy cleanup"*"O11Y_CONFIRM=down mise run down"* ]] || false
  [[ $output != *"mise run rollback"* ]] || false
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
  [[ $output == *"O11Y_CONFIRM=rollback mise run rollback"* ]] || false
}

@test "a service that is up but not ready fails the health gate" {
  healthy o11y
  STUB_HTTP=503 go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"is not ready"* ]] || false
  [ ! -e "$remote/current" ]
  [ ! -e "$dir/tools.log" ]
}

@test "a readiness check that answers 200 and then fails fails the health gate" {
  healthy o11y
  STUB_HTTP_THEN_FAILS=1 go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"is not ready"* ]] || false
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
  [[ $output == *"the lock exists"* ]] || false
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
}

@test "rollback fails when the pointer it needs does not exist" {
  go rollback
  [ "$status" -ne 0 ]
  ! recorded " up " || false
  ! recorded " up " || false
  recorded "rmdir $remote/.deploy.lock"
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
  [[ $output == *"could not be reached to take the lock"* ]] || false
  [[ $output != *attempt* ]] || false
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
  [[ $(grep -F "$O11Y_REMOTE_COMPOSE" "$dir/ssh.log" | tail -n 1) == *" -p o11y-gate "*" -f $release/compose.yaml down --remove-orphans" ]] || false
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
  [[ $output == *"RustFS refused to start on the filesystem"* ]] || false
  [[ $(grep -F "$O11Y_REMOTE_COMPOSE" "$dir/ssh.log" | tail -n 1) == *" -p o11y-gate "*" down --remove-orphans" ]] || false
}

@test "gate-test reports any other probe failure as a probe failure" {
  healthy o11y-gate
  layout
  STUB_PROBE_FAIL=1 go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"the RustFS probe failed"* ]] || false
  [[ $output != *"refused to start"* ]] || false
}

@test "gate-test refuses to rehearse on the data of an earlier run" {
  mkdir -p "$remote/gate/data"
  go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"gate-clean"* ]] || false
  ! recorded " up " || false
  ! recorded " run " || false
}

@test "gate-test checks that the gate data directory is absent, then creates it before the probe's init" {
  healthy o11y-gate
  layout
  go gate-test
  [ "$status" -eq 0 ]
  in_order "test ! -e $remote/gate/data" "mkdir -m 755 $remote/gate/data"
  [[ $(grep -F "mkdir -m 755 $remote/gate/data" "$dir/ssh.log") != *sudo* ]] || false
  grep -qF "rustfs-probe.sh --release" "$dir/tools.log"
}

@test "gate-test stops before the probe when the gate data directory can't be created" {
  healthy o11y-gate
  layout
  STUB_SSH_FAIL_ON="mkdir -m 755 $remote/gate/data" go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"the gate data directory could not be created"* ]]
  [ ! -f "$dir/tools.log" ]
}

@test "gate-test fails when the layout under the gate data directory differs" {
  healthy o11y-gate
  layout
  sed -i.bak 's/^secrets 0:0 755$/secrets 0:0 777/' "$dir/layout"
  go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"differ from the layout"* ]] || false
}

@test "gate-clean refuses while an o11y-gate container exists" {
  mkdir -p "$remote/gate/data"
  healthy o11y-gate
  go gate-clean
  [ "$status" -ne 0 ]
  ! recorded " run " || false
  [ "$(removals)" = "rmdir $remote/.deploy.lock" ]
  [ -d "$remote/gate/data" ]
}

@test "gate-clean removes the gate directory and nothing else" {
  mkdir -p "$remote/gate/data/loki" "$remote/gate/releases" "$remote/data" "$remote/config" "$remote/releases"
  healthy o11y
  go gate-clean
  [ "$status" -eq 0 ]
  recorded "run --rm --log-driver none --user 0:0 --network none --entrypoint /bin/sh -v $remote/gate:/d "
  [ "$(grep -c -e '-v ' "$dir/ssh.log")" -eq 1 ]
  [ "$(removals | grep -vc "^rmdir $remote/.deploy.lock$")" -eq 2 ]
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
  [[ $output == *"set an operator user"* ]] || false
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
  [[ $output == *"release id: "*"-abc1234"* ]] || false
  [[ $output == *"rustfs rustfs/rustfs:"*"@sha256:"* ]] || false
  [[ $output == *"grafana 127.0.0.1:3000 -> 3000"* ]] || false
  [[ $output == *"alloy 127.0.0.1:4317 -> 4317"* ]] || false
  [[ $output == *"O11Y_DATA_DIR=$remote/data"* ]] || false
  [[ $output == *"compose.init.yaml run --rm -T init"* ]] || false
  [[ $output == *"compose.yaml up -d --remove-orphans"* ]] || false
  [[ $output == *"mv -T current.new current"* ]] || false
}

@test "preflight changes nothing on the host" {
  nas preflight
  [ "$status" -eq 0 ]
  [[ $output == *"ok preflight: sudo -n runs docker-compose"* ]] || false
  [ ! -e "$remote" ]
  read_only
}

@test "preflight fails when the host's Compose is not the pinned version" {
  stub "$host/bin/docker-compose" <<<'echo v2.24.5'
  nas preflight
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL preflight: sudo -n runs docker-compose"* ]] || false
}

# df_without_type: a df that prints - for the type, as one does when the
# mount table doesn't name it, and a stat that reads it from the filesystem
# and records the path it was asked about.
df_without_type() {
  mv "$dir/bin/df" "$dir/bin/df.free"
  stub "$dir/bin/df" <<'STUB'
[ "$1" != -Pk ] || exec "$STUB/bin/df.free" "$@"
echo "Filesystem Type 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake - 1000 10 990 1% /"
STUB
  stub "$dir/bin/stat" <<'STUB'
[ "$1 $2 $3" = "-f -c %T" ] || exit 1
echo "$4" >"$STUB/stat.args"
echo btrfs
STUB
}

@test "preflight names the filesystem of the nearest existing ancestor of O11Y_REMOTE_DIR" {
  df_without_type
  nas preflight
  [ "$status" -eq 0 ]
  [[ $output == *"ok preflight: filesystem where O11Y_REMOTE_DIR will live: btrfs"* ]] || false
  [ "$(cat "$dir/stat.args")" = "$host" ]
  [ ! -e "$remote" ]
  read_only
}

@test "gate-test names the filesystem through stat when df prints none" {
  healthy o11y-gate
  layout
  df_without_type
  go gate-test
  [ "$status" -eq 0 ]
  [[ $output == *"filesystem under O11Y_REMOTE_DIR: $(uname -r) btrfs"* ]] || false
  [ "$(cat "$dir/stat.args")" = "$remote" ]
}

@test "the filesystem is reported as unknown, not left empty, when neither df nor stat names it" {
  healthy o11y-gate
  layout
  mv "$dir/bin/df" "$dir/bin/df.free"
  stub "$dir/bin/df" <<<'[ "$1" != -Pk ] || exec "$STUB/bin/df.free" "$@"; echo "df: invalid option -- T" >&2; exit 1'
  stub "$dir/bin/stat" <<<'exit 1'
  go gate-test
  [ "$status" -eq 0 ]
  [[ $output == *"filesystem under O11Y_REMOTE_DIR: $(uname -r) unknown"* ]] || false
  nas preflight
  [[ $output == *"filesystem where O11Y_REMOTE_DIR will live: unknown"* ]] || false
}

@test "the SSH control socket stays under the socket path limit however long TMPDIR is" {
  mv "$dir/bin/ssh" "$dir/bin/ssh.stub"
  stub "$dir/bin/ssh" <<'STUB'
printf '%s\n' "$@" | sed -n 's/^ControlPath=//p' >>"$STUB/control-paths"
exec "$STUB/bin/ssh.stub" "$@"
STUB
  long=$dir/$(printf 'tmp%.0s' {1..40})
  mkdir "$long"
  TMPDIR=$long nas preflight
  [ "$status" -eq 0 ]
  path=$(sort -u "$dir/control-paths")
  [ "$(wc -l <<<"$path")" -eq 1 ]
  [[ $path != "$long"* ]] || false
  # %C expands to 40 hex digits, and ssh appends 17 characters while it
  # binds the socket.
  expanded=${path//%C/0123456789abcdef0123456789abcdef01234567}
  ((${#expanded} + 17 < 104)) || false
  [ -d "$(dirname "$path")" ]
}

@test "status reports the current release and readiness without changing anything" {
  healthy o11y
  go deploy
  id=$(staged)
  rm "$dir/ssh.log"
  nas status
  [ "$status" -eq 0 ]
  [[ $output == *"current release: $id"* ]] || false
  [[ $output == *"rustfs (release 20260101T000000Z-abc1234) Up 1 minute (healthy)"* ]] || false
  [[ $output == *"mimir ready"* ]] || false
  [[ $output != *"$remote/releases"* ]] || false
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
  [[ $output == *O11Y_REMOTE_TAILSCALE* ]] || false
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

# --- review round 1 -------------------------------------------------------

# two_deploys: two promoted releases, ids in $first and $second.
two_deploys() {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged"
  sleep 1
  go deploy
  second=$(staged)
  rm "$dir/ssh.log"
}

@test "rollback takes no argument but --previous, and refuses before any ssh call" {
  for args in previous --prev "--previous extra" 20260101T000000Z-abc1234; do
    # shellcheck disable=SC2086 # each case is a list of words
    O11Y_CONFIRM=rollback nas rollback $args
    [ "$status" -ne 0 ]
    [[ $output == *"the only argument it takes is --previous"* ]] || false
  done
  [ ! -e "$dir/ssh.log" ]
}

@test "rollback --previous swaps the pointers once the restored release passes the health gate" {
  two_deploys
  go rollback --previous
  [ "$status" -eq 0 ]
  # Both new links first, then both renames, in one remote command.
  in_order "-f $remote/releases/$first/compose.yaml up -d" "exec -i o11y-rustfs-1 curl" \
    "cd $remote && ln -sfn releases/$first current.new && ln -sfn releases/$second previous.new && mv -T previous.new previous && mv -T current.new current"
  [ "$(grep -c 'current.new' "$dir/ssh.log")" -eq 1 ]
  [ "$(readlink "$remote/current")" = "releases/$first" ]
  [ "$(readlink "$remote/previous")" = "releases/$second" ]
  # The next deploy keeps the restored release as previous.
  rm "$repo/tmp/deploy/staged"
  sleep 1
  go deploy
  [ "$status" -eq 0 ]
  [ "$(readlink "$remote/previous")" = "releases/$first" ]
}

@test "rollback --previous that fails the health gate leaves both pointers alone" {
  two_deploys
  STUB_RECEIPT_FAIL=1 go rollback --previous
  [ "$status" -ne 0 ]
  [ "$(readlink "$remote/current")" = "releases/$second" ]
  [ "$(readlink "$remote/previous")" = "releases/$first" ]
}

@test "deploy reads current only once it holds the lock" {
  two_deploys
  # Another run promotes a third release just before this one gets the lock.
  STUB_ON_LOCK="cd $remote && ln -sfn releases/20200101T000000Z-abc1234 current" go stage
  rm "$dir/ssh.log"
  STUB_ON_LOCK="cd $remote && ln -sfn releases/20200101T000000Z-abc1234 current" go deploy
  [ "$status" -eq 0 ]
  [ "$(readlink "$remote/previous")" = "releases/20200101T000000Z-abc1234" ]
}

@test "rollback and down choose their release only once they hold the lock" {
  two_deploys
  mkdir -p "$remote/releases/20200101T000000Z-abc1234"
  STUB_ON_LOCK="cd $remote && ln -sfn releases/20200101T000000Z-abc1234 current" go rollback
  recorded "-f $remote/releases/20200101T000000Z-abc1234/compose.yaml up -d"
  ! recorded "releases/$second/compose.yaml" || false
  ln -sfn "releases/$second" "$remote/current"
  rm "$dir/ssh.log"
  STUB_ON_LOCK="cd $remote && ln -sfn releases/20200101T000000Z-abc1234 current" go down
  [ "$status" -eq 0 ]
  recorded "-f $remote/releases/20200101T000000Z-abc1234/compose.yaml down"
  ! recorded "releases/$second/compose.yaml" || false
}

@test "stage, gate-test and gate-clean hold the lock, and change nothing while another run has it" {
  mkdir -p "$remote/gate/data" "$remote/config/.incoming-alloy-000000000000"
  mkdir "$remote/.deploy.lock"
  for task in stage gate-test gate-clean; do
    rm -f "$dir/ssh.log"
    go "$task"
    [ "$status" -ne 0 ]
    [[ $output == *"the lock exists"* ]] || false
    [ "$(cat "$dir/ssh.log")" = "mkdir -p $remote || exit 3; mkdir $remote/.deploy.lock" ]
  done
  [ -d "$remote/config/.incoming-alloy-000000000000" ]
  [ -d "$remote/gate/data" ]
  [ -d "$remote/.deploy.lock" ]
}

@test "a second stage that starts while one is uploading fails on the lock and disturbs nothing" {
  STUB_ON_VERIFY="O11Y_CONFIRM=stage bash $repo/tools/nas.sh stage >$dir/second.out 2>&1; echo \$? >$dir/second.status" go stage
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/second.status")" -ne 0 ]
  grep -q "the lock exists" "$dir/second.out"
  # Every final directory is a verified copy.
  for final in "$remote"/config/*/ "$remote/releases/$(staged)/"; do
    (cd "$final" && sha256sum -c MANIFEST.sha256 >/dev/null)
  done
  [ "$(find "$remote" -name '.incoming-*' | wc -l)" -eq 0 ]
}

@test "gate-clean stops when the container query fails and removes nothing" {
  mkdir -p "$remote/gate/data/loki"
  healthy o11y-gate
  STUB_FAIL="ps -aq" go gate-clean
  [ "$status" -ne 0 ]
  [[ $output == *"could not be asked for o11y-gate containers"* ]] || false
  ! recorded " run " || false
  [ -d "$remote/gate/data/loki" ]
}

@test "gate-test stops when the host can't say whether gate data exists" {
  healthy o11y-gate
  layout
  STUB_SSH_FAIL_ON="test*-e $remote/gate/data" go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"could not be asked whether gate data exists"* ]] || false
  ! recorded " run " || false
  ! recorded " up -d" || false
}

@test "gate-test fails, and says nothing of a stopped project, when its final down fails" {
  healthy o11y-gate
  layout
  STUB_FAIL_SECOND="down --remove-orphans" go gate-test
  [ "$status" -ne 0 ]
  [[ $output != *"project is stopped"* ]] || false
  [[ $output == *"could not be stopped"* ]] || false
}

@test "a run that otherwise passed fails when the lock can't be removed" {
  healthy o11y
  go deploy
  STUB_SSH_FAIL_ON="rmdir $remote/.deploy.lock" go down
  [ "$status" -ne 0 ]
  [[ $output == *"the lock could not be removed"* ]] || false
}

@test "a run ended by a signal keeps the lock" {
  healthy o11y
  STUB_SIGNAL_ON="*up -d --remove-orphans" go deploy
  [ "$status" -eq 143 ]
  [ -d "$remote/.deploy.lock" ]
  ! recorded "rmdir $remote/.deploy.lock" || false
  [[ $output == *"interrupted, so the lock stays"* ]] || false
}

@test "status measures no container when none of the stack's is running" {
  echo "o11y s3-buckets o11y-s3-buckets-1 files Exited (0) 1 minute ago" >"$dir/containers"
  nas status
  [ "$status" -eq 0 ]
  [[ $output != *"stats of every container on the host"* ]] || false
  [[ $output == *"no running containers to measure"* ]] || false
}

@test "remote output reaches the terminal without the deployment's names, paths or tailnet addresses" {
  export O11Y_TAILNET_DOMAIN=sentinel-net.example.ts.net O11Y_SSH_HOST=sentinel-host
  export O11Y_PRIVATE_STRINGS=sentinelModel42 STUB_SERVE_CONFIG=1
  healthy o11y
  nas preflight
  nas status
  go serve-apply
  nas serve-status
  go serve-clear
  ! grep -n -e sentinel-net -e sentinel-host -e sentinelModel42 -e "$remote" \
    -e "100\.$((64 + 37))\." -e "fd7a:115c:a1e[0]" "$dir/output" || false
  # The placeholders show where they were.
  grep -q 'https://grafana.$O11Y_TAILNET_DOMAIN' "$dir/output"
  grep -q '<tailnet address>' "$dir/output"
  # The raw output is kept in the private task logs.
  grep -q sentinel-net "$repo/tmp/deploy/serve-status.log"
}

# --- review round 2 -------------------------------------------------------

@test "a rollback swap cut off by the connection keeps the lock and names both releases" {
  two_deploys
  STUB_SSH_FAIL_ON="*current.new && ln -sfn*" go rollback --previous
  [ "$status" -ne 0 ]
  [[ $output == *"the pointer swap may not have finished, so the lock stays"* ]] || false
  [[ $output == *"current should name release $first and previous release $second"* ]] || false
  [[ $output != *"$remote"* ]] || false
  [ -d "$remote/.deploy.lock" ]
  ! recorded "rmdir $remote/.deploy.lock" || false
  # A retry finds the lock and starts nothing.
  rm "$dir/ssh.log"
  go rollback --previous
  [ "$status" -ne 0 ]
  [[ $output == *"the lock exists"* ]] || false
  ! recorded " up " || false
}

@test "a rollback swap interrupted by a signal keeps the lock and names both releases" {
  two_deploys
  STUB_SIGNAL_ON="*current.new && ln -sfn*" go rollback --previous
  [ "$status" -ne 0 ]
  [[ $output == *"current should name release $first and previous release $second"* ]] || false
  [ -d "$remote/.deploy.lock" ]
  ! recorded "rmdir $remote/.deploy.lock" || false
}

@test "status shows SSH and docker failures without the deployment's names" {
  export O11Y_SSH_HOST=sentinel-host
  healthy o11y
  STUB_SSH_RESOLVE_FAIL=1 nas status
  [ "$status" -ne 0 ]
  [[ $output == *'Could not resolve hostname $O11Y_SSH_HOST'* ]] || false
  [[ $output != *sentinel-host* ]] || false
  grep -q sentinel-host "$repo/tmp/deploy/status.log"
  # The container query, readiness and statistics fail the same way.
  STUB_DOCKER_ERROR=1 nas status
  [ "$status" -ne 0 ]
  [[ $output == *"error during connect"* ]] || false
  [[ $output != *sentinel-host* && $output != *"$remote"* ]] || false
  STUB_FAIL=stats nas status
  [[ $output == *"container statistics are unavailable"* ]] || false
  STUB_HTTP=000 nas status
  [ "$status" -eq 0 ]
  [[ $output == *"loki not ready"* ]] || false
}

@test "logs shows container logs without the tailnet domain, and keeps the raw ones in the task log" {
  export O11Y_TAILNET_DOMAIN=sentinel-net.example.ts.net
  healthy o11y
  go deploy
  nas logs grafana
  [ "$status" -eq 0 ]
  [[ $output == *'GF_SERVER_ROOT_URL=https://grafana.$O11Y_TAILNET_DOMAIN/'* ]] || false
  [[ $output != *sentinel-net* ]] || false
  grep -q "https://grafana.sentinel-net.example.ts.net/" "$repo/tmp/deploy/logs.log"
}

# --- hardening ------------------------------------------------------------

@test "a deploy promotion cut off by the connection keeps the lock and names both releases" {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged" "$dir/ssh.log"
  sleep 1
  STUB_SSH_FAIL_ON="*current.new && ln -sfn*" go deploy
  [ "$status" -ne 0 ]
  second=$(staged)
  [[ $output == *"the pointer swap may not have finished, so the lock stays"* ]] || false
  [[ $output == *"current should name release $second and previous release $first"* ]] || false
  [[ $output != *"$remote"* ]] || false
  [ -d "$remote/.deploy.lock" ]
  ! recorded "rmdir $remote/.deploy.lock" || false
  rm "$dir/ssh.log"
  go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"the lock exists"* ]] || false
  ! recorded " up " || false
}

@test "a first deploy whose promotion is cut off says previous stays as it was" {
  healthy o11y
  STUB_SSH_FAIL_ON="*ln -sfn releases/*current.new*" go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"current should name release $(staged), and previous stays as it was"* ]] || false
  [ -d "$remote/.deploy.lock" ]
}

@test "a deploy promotion interrupted by a signal keeps the lock and names both releases" {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged" "$dir/ssh.log"
  sleep 1
  STUB_SIGNAL_ON="*current.new && ln -sfn*" go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"current should name release $(staged) and previous release $first"* ]] || false
  [ -d "$remote/.deploy.lock" ]
  ! recorded "rmdir $remote/.deploy.lock" || false
}

@test "all a task prints has reached its output by the time the task exits" {
  bash "$repo/tools/nas.sh" serve-status >"$dir/terminal" 2>&1
  grep -q "No serve config" "$dir/terminal"
  # The exit status is the task's own.
  set +e
  O11Y_REMOTE_TAILSCALE=tailscale bash "$repo/tools/nas.sh" serve-status >"$dir/terminal" 2>&1
  code=$?
  set -e
  [ "$code" -eq 1 ]
  grep -q "O11Y_REMOTE_TAILSCALE" "$dir/terminal"
}

@test "the tasks that change the host show SSH errors without the host alias" {
  export O11Y_SSH_HOST=sentinel-host
  healthy o11y
  go deploy
  for task in deploy rollback down; do
    rm -f "$remote/.deploy.lock"
    STUB_SSH_RESOLVE_FAIL_ON="*readlink*" go "$task"
    [ "$status" -ne 0 ]
    [[ $output == *'Could not resolve hostname $O11Y_SSH_HOST'* ]] || false
    [[ $output != *sentinel-host* ]] || false
    grep -q sentinel-host "$repo/tmp/deploy/$task.log"
  done
  rmdir "$remote/.deploy.lock" 2>/dev/null || true
  STUB_SSH_RESOLVE_FAIL_ON="*ps -aq*" go gate-clean
  [ "$status" -ne 0 ]
  [[ $output == *'Could not resolve hostname $O11Y_SSH_HOST'* ]] || false
  [[ $output != *sentinel-host* ]] || false
}

@test "deploy-plan prints the real values it asks the owner to approve" {
  export O11Y_TAILNET_DOMAIN=sentinel-net.example.ts.net
  nas deploy-plan
  [ "$status" -eq 0 ]
  [[ $output == *"https://grafana.sentinel-net.example.ts.net/"* ]] || false
  [[ $output == *"O11Y_DATA_DIR=$remote/data"* ]] || false
}

# --- draining ---------------------------------------------------------------

# in_own_group <command...>: runs the command in a process group of its own
# in the background, so a test can signal that whole group without bats.
in_own_group() {
  # A background job starts with INT ignored; the task needs it back.
  perl -e '$SIG{INT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' "$@" &
}

wait_for() {
  local tries=0
  until [ -e "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.1
  done
}

@test "a TERM sent to the task's whole process group fails the run, and its last output still arrives" {
  healthy o11y
  go deploy
  STUB_HOLD_ON="*compose.yaml down" O11Y_CONFIRM=down in_own_group bash "$repo/tools/nas.sh" down >"$dir/terminal" 2>&1
  pid=$!
  wait_for "$dir/held"
  kill -TERM -- "-$pid"
  set +e
  wait "$pid"
  code=$?
  set -e
  [ "$code" -eq 143 ]
  grep -q "interrupted, so the lock stays" "$dir/terminal"
  [ -d "$remote/.deploy.lock" ]
}

# The operator may pipe the task's error output, as in `mise run deploy
# 2>&1 | tee`. The reader here waits for the end of that pipe, so a leftover
# process that kept a descriptor on it would hold the run open.
@test "a process the task leaves behind with an extra descriptor can't hold the operator's pipe open" {
  healthy o11y
  STUB_LEAK_ON="rmdir*" STUB_LEAK_KIND=fd9 O11Y_CONFIRM=deploy run perl -e 'alarm 20; exec @ARGV' \
    bash -c 'set -o pipefail; bash "$1" deploy 2>&1 | cat' _ "$repo/tools/nas.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"is now current"* ]] || false
}

@test "an unfiltered task's leftover process can't hold the operator's pipe open" {
  healthy o11y
  STUB_LEAK_ON="*grafana_admin_password*" STUB_LEAK_KIND=fd9 run perl -e 'alarm 20; exec @ARGV' \
    bash -c 'set -o pipefail; bash "$1" grafana-password 2>&1 | cat' _ "$repo/tools/nas.sh"
  [ "$status" -eq 0 ]
  [ "$output" = stub-grafana-password ]
}

@test "an INT sent to the task's whole process group fails the run with 130 and keeps the lock" {
  healthy o11y
  go deploy
  STUB_HOLD_ON="*compose.yaml down" O11Y_CONFIRM=down in_own_group bash "$repo/tools/nas.sh" down >"$dir/terminal" 2>&1
  pid=$!
  wait_for "$dir/held"
  kill -INT -- "-$pid"
  set +e
  wait "$pid"
  code=$?
  set -e
  [ "$code" -eq 130 ]
  grep -q "interrupted, so the lock stays" "$dir/terminal"
  [ -d "$remote/.deploy.lock" ]
}

@test "a leftover process that holds the task's stdout can't hold the run open" {
  healthy o11y
  go deploy
  STUB_LEAK_ON="*logs --no-color*" STUB_LEAK_KIND=stdout run perl -e 'alarm 20; exec @ARGV' bash "$repo/tools/nas.sh" logs
  [ "$status" -eq 0 ]
  [[ $output == *"GF_SERVER_ROOT_URL"* ]] || false
}

@test "two runs of the same task at once both keep their output in the log" {
  bash "$repo/tools/nas.sh" serve-status >"$dir/first" 2>&1 &
  first=$!
  bash "$repo/tools/nas.sh" serve-status >"$dir/second" 2>&1 &
  second=$!
  wait "$first"
  wait "$second"
  grep -q "No serve config" "$dir/first"
  grep -q "No serve config" "$dir/second"
  [ "$(grep -c "No serve config" "$repo/tmp/deploy/serve-status.log")" -eq 2 ]
}

@test "the log keeps every run, and each run shows only its own output" {
  nas serve-status
  nas serve-status
  [ "$status" -eq 0 ]
  [ "$(grep -c "No serve config" <<<"$output")" -eq 1 ]
  [ "$(grep -c "No serve config" "$repo/tmp/deploy/serve-status.log")" -eq 2 ]
}

@test "a run whose output can't be shown fails, even when the task passed" {
  STUB_TAIL_FAILS=1 nas serve-status
  [ "$status" -eq 1 ]
  [[ $output == *"the output could not be shown"* ]] || false
  grep -q "No serve config" "$repo/tmp/deploy/serve-status.log"
}

@test "the recovery message of a cut-off promotion reaches the task log even when nothing can be shown" {
  healthy o11y
  go deploy
  first=$(staged)
  rm "$repo/tmp/deploy/staged"
  sleep 1
  STUB_TAIL_FAILS=1 STUB_SSH_FAIL_ON="*current.new && ln -sfn*" go deploy
  [ "$status" -ne 0 ]
  grep -q "current should name release $(staged) and previous release $first" "$repo/tmp/deploy/deploy.log"
}

@test "remote diagnostics go to their own log and stay out of the operator's copy" {
  nas preflight
  [ "$status" -eq 0 ]
  grep -q -- '--- SSH reaches the host' "$repo/tmp/deploy/preflight.raw.log"
  [[ $output != *"--- SSH reaches the host"* ]] || false
}

@test "a diagnostics writer that ends early can't fail a remote command or free the lock" {
  healthy o11y
  go deploy
  STUB_RAW_SED_DIES=1 STUB_NOISY=1 go down
  [ "$status" -eq 0 ]
  [[ $output == *"containers of release"*"are removed"* ]] || false
  [ "$(grep -c 'Container stopping' "$repo/tmp/deploy/down.raw.log")" -eq 5000 ]
}

@test "a leftover process that holds only the diagnostics can't hold gate-test open" {
  healthy o11y-gate
  layout
  STUB_LEAK_ON="*s3probe count*" STUB_LEAK_KIND=stderr O11Y_CONFIRM=gate-test \
    run perl -e 'alarm 20; exec @ARGV' bash "$repo/tools/nas.sh" gate-test
  [ "$status" -eq 0 ]
  [[ $output == *"the rehearsal passed"* ]] || false
}

@test "a line filter that fails can't hide the operator's copy" {
  STUB_GREP_FAILS=1 nas serve-status
  [ "$status" -eq 0 ]
  [[ $output == *"No serve config"* ]] || false
}

@test "an object count that prints a number and then fails fails gate-test" {
  healthy o11y-gate
  layout
  STUB_COUNT_FAILS=1 O11Y_CONFIRM=gate-test nas gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"the loki bucket is empty after a flush"* ]] || false
  [[ $output != *"the rehearsal passed"* ]] || false
}

@test "a carriage-return filter that fails fails gate-test" {
  healthy o11y-gate
  layout
  STUB_TR_FAILS=1 O11Y_CONFIRM=gate-test nas gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"the loki bucket is empty after a flush"* ]] || false
  [[ $output != *"the rehearsal passed"* ]] || false
}

@test "a flush that answers 204 and then fails fails gate-test" {
  healthy o11y-gate
  layout
  STUB_FLUSH_THEN_FAILS=1 O11Y_CONFIRM=gate-test nas gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"Loki's flush endpoint failed"* ]] || false
}

# --- disk reserve ---------------------------------------------------------

@test "deploy below the disk reserve starts nothing, frees the lock and says why" {
  healthy o11y
  STUB_DISK_FREE=$((10 * 1048576)) go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL deploy: the filesystem under O11Y_REMOTE_DIR has 10 GiB free of 1000 GiB (1 percent), below the reserve of 50 GiB and 10 percent"* ]] || false
  recorded "mkdir $remote/.deploy.lock"
  ! recorded "up -d" || false
  ! recorded "tar -xpf" || false
  [ ! -e "$remote/.deploy.lock" ]
}

@test "deploy refuses under 10 percent free even above the reserve" {
  healthy o11y
  STUB_DISK_FREE=$((90 * 1048576)) go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"has 90 GiB free of 1000 GiB (9 percent), below the reserve"* ]] || false
  ! recorded "up -d" || false
  [ ! -e "$remote/.deploy.lock" ]
}

@test "preflight and gate-test refuse below the reserve, and gate-test frees the lock" {
  healthy o11y-gate
  layout
  O11Y_DISK_RESERVE_GB=600 nas preflight
  [ "$status" -ne 0 ]
  [[ $output == *"below the reserve of 600 GiB"* ]] || false
  O11Y_DISK_RESERVE_GB=600 go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL gate-test: the filesystem under O11Y_REMOTE_DIR has 500 GiB free"* ]] || false
  ! recorded "o11y-gate" || false
  [ ! -e "$remote/.deploy.lock" ]
}

@test "above the reserve the gate passes and says so, and status prints the free space" {
  healthy o11y
  go deploy
  [ "$status" -eq 0 ]
  [[ $output == *"ok deploy: the filesystem under O11Y_REMOTE_DIR has 500 GiB free of 1000 GiB (50 percent), above the reserve"* ]] || false
  nas status
  [[ $output == *"disk under O11Y_REMOTE_DIR: 500 GiB free of 1000 GiB (50 percent)"* ]] || false
}

@test "a host that can't report its free space fails the gate" {
  healthy o11y
  stub "$dir/bin/df" <<<'exit 1'
  go deploy
  [ "$status" -ne 0 ]
  [[ $output == *"could not be asked for its free space"* ]] || false
  ! recorded "up -d" || false
  [ ! -e "$remote/.deploy.lock" ]
}

@test "a reserve that is not a whole number of GiB is rejected by name before any ssh call" {
  for value in 50G -1 1e3; do
    O11Y_DISK_RESERVE_GB=$value go deploy
    [ "$status" -ne 0 ]
    [[ $output == *"O11Y_DISK_RESERVE_GB must be a whole number of GiB"* ]] || false
  done
  [ ! -e "$dir/ssh.log" ]
}

@test "rollback below the reserve still runs, and checks no free space" {
  two_deploys
  STUB_DISK_FREE=1024 go rollback --previous
  [ "$status" -eq 0 ]
  [ "$(readlink "$remote/current")" = "releases/$first" ]
  ! recorded "df -Pk" || false
}

@test "gate-test fails when a self-scrape is not up, and still stops the project" {
  healthy o11y-gate
  layout
  STUB_SELF_DOWN=1 go gate-test
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL gate-test: up is not 1 for exactly the five o11y/* jobs"* ]] || false
  recorded "-p o11y-gate --env-file"
  [ "$(grep -c "down --remove-orphans" "$dir/ssh.log")" -ge 2 ]
}
