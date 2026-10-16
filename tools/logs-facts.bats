#!/usr/bin/env bats
# tools/logs-facts.sh against a fake host. Nothing here contacts a real one.
# The script runs with a PATH of stubs and the few real tools it needs:
# sudo admits only `-n <docker path>`, docker answers from files under the
# test directory, and its `run` executes the reader's script here, with the
# mount's target and the reader's mount table rewritten to fixtures. stat,
# head, awk, sleep, netstat, ss and df are stubs that fail or misbehave on
# request. Every run asserts that no private value reached the output: the
# test directory holds the data root, and every private value the stubs
# print contains the word private.
# cspell:ignore compgen drwx hostconfig logconfig mountinfo noprofile norc relatime rprivate statx submount tmpfs versinfo

setup() {
  dir=$(cd "$(mktemp -d)" && pwd -P)
  data=$dir/private-data-root
  image=grafana/alloy:v1.20.1@sha256:2aa2099af76c0098d4af7a4d6e48f86cb66dc1a000222ad927a1c67c6542d13f
  mkdir -p "$dir/bin" "$dir/sys" "$dir/host" "$dir/logconfig"
  real_bash=$(command -v bash)
  for tool in awk bash cat cut df grep head ln ls mv paste printf rm sed sort stat tr uniq; do
    ln -s "$(command -v "$tool")" "$dir/sys/$tool"
  done
  ln -s "$(command -v sleep)" "$dir/sys/real-sleep"

  # The host's mount table: the data root lies under the test directory's
  # mount, and nothing is mounted below it.
  cat >"$dir/host-mountinfo" <<EOF
22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/md0 rw
30 22 0:30 / $dir rw,relatime shared:12 - btrfs /dev/vg1 rw
EOF
  # The reader's: its target alone, read-only. docker run rewrites the
  # target to the data root's containers directory, so the fixture names it.
  echo "50 40 0:50 /containers $data/containers ro,relatime - btrfs /dev/vg1 rw" >"$dir/reader-mountinfo"
  sed "s|^host_mountinfo=.*|host_mountinfo=$dir/host-mountinfo|" "$BATS_TEST_DIRNAME/logs-facts.sh" >"$dir/logs-facts.sh"
  [ "$(grep -c "^host_mountinfo=$dir/host-mountinfo$" "$dir/logs-facts.sh")" -eq 1 ]

  # Six running stack services, one gate container, and another app.
  : >"$dir/services"
  : >"$dir/all"
  i=0
  for service in alloy grafana loki mimir rustfs tempo; do
    i=$((i + 1))
    id=$(cid "a$i")
    printf '%s %s\n' "$service" "$id" >>"$dir/services"
    printf '%s o11y json-file\n' "$id" >>"$dir/all"
    mkdir -p "$data/containers/$id"
    printf '{"log":"started\\n","stream":"stderr","time":"2026-10-16T00:00:00Z"}\n' >"$data/containers/$id/$id-json.log"
    echo '{}' >"$data/containers/$id/config.v2.json"
    echo '{}' >"$data/containers/$id/hostconfig.json"
  done
  printf '%s o11y-gate json-file\n' "$(cid b1)" >>"$dir/all"
  printf '%s private-app json-file\n' "$(cid c1)" >>"$dir/all"
  {
    echo "Active Internet connections (only servers)"
    echo "Proto Recv-Q Send-Q Local Address Foreign Address State"
    printf 'tcp 0 0 0.0.0.0:5000 0.0.0.0:* LISTEN\ntcp 0 0 127.0.0.1:3000 0.0.0.0:* LISTEN\ntcp6 0 0 :::22 :::* LISTEN\n'
  } >"$dir/netstat"

  stub "$dir/bin/sudo" <<'STUB'
printf '%s %s\n' "$1" "$2" >>"$STUB/sudo.log"
[ "$1" = -n ] && [ "$2" = "$STUB/host/docker" ] || exit 97
shift
exec "$@"
STUB
  # STUB_DOCKER_FAIL (a glob) fails the matching call with an error that
  # names a private path, as a broken daemon would.
  stub "$dir/host/docker" <<'STUB'
# One line a call: a reader's script is cut at its first line.
all="$*"
printf '%s\n' "${all%%$'\n'*}" >>"$STUB/docker.log"
# shellcheck disable=SC2053 # the variable is a pattern
if [[ -n ${STUB_DOCKER_FAIL:-} && $* == $STUB_DOCKER_FAIL ]]; then
  echo "Error response from daemon: open $STUB/private-data-root/x: permission denied" >&2
  exit 1
fi
case $1 in
info)
  case $3 in
  *DockerRootDir*) printf '%s\n' "${STUB_ROOT-$STUB/private-data-root}" ;;
  *) printf '%s\n' "${STUB_INFO-24.0.2 btrfs json-file 4.4.302+}" ;;
  esac
  ;;
image) [ -z "${STUB_NO_IMAGE:-}" ] ;;
ps)
  # The project's containers, each running unless its line names a state.
  if [ "$2" = -aq ]; then
    cut -c 1-12 "$STUB/all"
  else
    awk 'NF == 2 { $3 = "running" } { print }' "$STUB/services"
  fi
  ;;
inspect)
  case $3 in
  *Config.Labels*)
    shift 3
    for id; do
      # STUB_INSPECT_SKIP leaves out the ids that start with it.
      [ -z "${STUB_INSPECT_SKIP:-}" ] || [ "${id#"$STUB_INSPECT_SKIP"}" = "$id" ] || continue
      awk -v id="$id" 'index($1, id) == 1 { print $2 "|" $3 }' "$STUB/all"
    done
    ;;
  *)
    if [ -f "$STUB/logconfig/$4" ]; then
      cat "$STUB/logconfig/$4"
    else
      echo "json-file|10m|3|com.docker.compose.project,com.docker.compose.service||3"
    fi
    ;;
  esac
  ;;
run)
  shift
  mount=
  script=
  while [ "$#" -gt 0 ]; do
    case $1 in
    --mount) mount=$2 && shift ;;
    -c) script=$2 && shift ;;
    esac
    shift
  done
  source=${mount#*source=}
  source=${source%%,*}
  target=${mount#*target=}
  target=${target%%,*}
  script=${script//$target/$source}
  script=${script//\/proc\/self\/mountinfo/$STUB/reader-mountinfo}
  exec "$STUB_READER_BASH" -c "$script"
  ;;
esac
STUB
  # STUB_STAT_FAIL_ON (a glob over the arguments) fails the matching call;
  # STUB_STAT_EXTRA adds a field to every inode and size answer.
  stub "$dir/bin/stat" <<'STUB'
# shellcheck disable=SC2053 # the variable is a pattern
if [[ -n ${STUB_STAT_FAIL_ON:-} && $* == $STUB_STAT_FAIL_ON ]]; then
  echo "stat: cannot statx '$STUB/private-data-root': Permission denied" >&2
  exit 1
fi
if [[ -n ${STUB_STAT_EXTRA:-} && $2 == '%i %s' ]]; then
  out=$("$STUB/sys/stat" "$@") || exit 1
  echo "$out 9"
  exit 0
fi
exec "$STUB/sys/stat" "$@"
STUB
  stub "$dir/bin/head" <<'STUB'
# shellcheck disable=SC2053 # the variable is a pattern
if [[ -n ${STUB_HEAD_FAIL_ON:-} && $* == $STUB_HEAD_FAIL_ON ]]; then
  echo "head: cannot open '$STUB/private-data-root' for reading: Permission denied" >&2
  exit 1
fi
exec "$STUB/sys/head" "$@"
STUB
  # STUB_AWK_FAIL_ON (a glob over the program) runs awk, then exits 1, as
  # an awk that printed a valid answer and then failed would.
  stub "$dir/bin/awk" <<'STUB'
# shellcheck disable=SC2053 # the variable is a pattern
if [[ -n ${STUB_AWK_FAIL_ON:-} && $* == $STUB_AWK_FAIL_ON ]]; then
  "$STUB/sys/awk" "$@"
  exit 1
fi
exec "$STUB/sys/awk" "$@"
STUB
  # The reader's ten-minute wait: STUB_ON_SLEEP runs in its place.
  stub "$dir/bin/sleep" <<'STUB'
[ -z "${STUB_ON_SLEEP:-}" ] || "$STUB/sys/bash" -c "$STUB_ON_SLEEP"
STUB
  stub "$dir/bin/netstat" <<'STUB'
[ -z "${STUB_NETSTAT_FAIL:-}" ] || {
  echo "netstat: $STUB/private-data-root: error" >&2
  exit 1
}
cat "$STUB/netstat"
STUB
  stub "$dir/bin/df" <<'STUB'
[ -z "${STUB_DF_FAIL:-}" ] || exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "${STUB_DF-/dev/md0 2385528 1700000 600000 75% /}"
STUB
  export STUB=$dir STUB_READER_BASH=$real_bash
  loki_log=$data/containers/$(cid a3)/$(cid a3)-json.log
}

# cid <two hex digits>: a 64-digit container id whose short form starts
# with them, so short ids never collide.
cid() {
  printf '%s%062d' "$1" 0
}

teardown() {
  rm -rf "$dir"
}

stub() {
  {
    echo "#!$real_bash"
    cat
  } >"$1"
  chmod +x "$1"
}

# clean <command...>: the command in an environment like the one nas.sh
# gives the script, env -i with PATH, plus the stubs' STUB_* settings.
# bats itself exports functions, which the script would refuse.
clean() {
  local name settings=()
  for name in $(compgen -v STUB); do
    settings+=("$name=${!name}")
  done
  env -i PATH="$dir/bin:$dir/sys" "${settings[@]}" "$@"
}

# facts: runs the script on the fake host, keeps its output and status,
# and fails when a private value reached the output.
facts() {
  run clean "${HOST_BASH:-$real_bash}" "$dir/logs-facts.sh" "$dir/host/docker" "$image"
  if [[ $output == *"$dir"* || $output == *private* ]]; then
    echo "a private value reached the output: $output"
    return 1
  fi
}

# failed <line>: the run stopped with status 1 and printed exactly that one
# FAIL line, and never its OK line.
failed() {
  [ "$status" -eq 1 ] || {
    echo "status $status: $output"
    return 1
  }
  [[ $output == *"$1"* ]] || {
    echo "expected '$1' in: $output"
    return 1
  }
  [ "$(grep -c '^FAIL ' <<<"$output")" -eq 1 ]
  [[ $output != *"OK all checks passed"* ]]
}

# --- a clean host -----------------------------------------------------------

@test "a clean host prints every check, then OK" {
  STUB_ON_SLEEP="for f in $data/containers/*/*-json.log; do printf 0123456789 >>\"\$f\"; done" facts
  [ "$status" -eq 0 ]
  [[ $output == *"D0 engine 24.0.2"* ]]
  [[ $output == *"D0 storage btrfs"* ]]
  [[ $output == *"D0 default-log-driver json-file"* ]]
  [[ $output == *"D0 kernel 4.4.302+"* ]]
  [[ $output == *"A2 image present"* ]]
  [[ $output == *"R1 enclosing-mount ancestor"* ]]
  [[ $output == *"R1 type btrfs"* ]]
  [[ $output == *"R1 access rw"* ]]
  [[ $output == *"R1 propagation shared:12"* ]]
  [[ $output == *"R1 mounts-below-containers 0"* ]]
  [[ $output == *"R2 one read-only target"* ]]
  [[ $output == *"R3 json-file-logs-on-host 6"* ]]
  [[ $output == *"R3 tempo-globbed yes"* ]]
  [[ $output == *"R3 tempo-readable yes"* ]]
  [[ $output == *"R4 log-mode "* ]]
  [[ $output == *"R4 acl-on-target no"* ]]
  [[ $output == *"R5 o11y json-file 6"* ]]
  [[ $output == *"R5 o11y-gate json-file 1"* ]]
  [[ $output == *"R5 other json-file 1"* ]]
  [[ $output == *"R6 loki json-file 10m x 3 labels=set mode=default"* ]]
  [[ $output == *"A4 loki-bytes-a-day 1440"* ]]
  [[ $output == *"A5 tcp-ports-on-all-addresses 22 5000"* ]]
  [[ $output == *"N7 root-free-kib 600000"* ]]
  [[ $output == *"N7 root-total-kib 2385528"* ]]
  [[ $output == *"OK all checks passed" ]]
  [[ $output != *FAIL* ]]
}

@test "a function inherited from the environment stops the run before anything is asked" {
  run clean 'BASH_FUNC_declare%%=() { echo private; }' "$real_bash" "$dir/logs-facts.sh" "$dir/host/docker" "$image"
  [ "$status" -eq 1 ]
  [[ $output == "FAIL env: the shell inherited functions from its environment" ]]
  [ ! -e "$dir/sudo.log" ]
}

# each_bash <test body function>: runs it under this bash and, where there
# is one, under macOS's bash 3.2.
each_bash() {
  HOST_BASH=$real_bash "$1"
  if [[ -x /bin/bash ]] && [[ $(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"') == 3 ]]; then
    HOST_BASH=/bin/bash "$1"
  fi
}

unbound_after_trap() {
  sed -i 's/^trap finish EXIT$/&\n: "$no_such_variable"/' "$dir/logs-facts.sh"
  [ "$(grep -c '^: "$no_such_variable"$' "$dir/logs-facts.sh")" -eq 1 ]
  facts
  failed "FAIL run: the script stopped on an unexpected error"
  sed -i '/^: "$no_such_variable"$/d' "$dir/logs-facts.sh"
}

@test "an unbound variable after the trap fails with FAIL run, on bash 3.2 too" {
  each_bash unbound_after_trap
}

terminated() {
  local pid
  rm -f "$dir/sleeping"
  # Started without the clean wrapper's function in between, so the
  # signal reaches the script's own shell.
  local name settings=(STUB_ON_SLEEP=": >'$dir/sleeping'; '$dir/sys/real-sleep' 2")
  for name in $(compgen -v STUB); do
    settings+=("$name=${!name}")
  done
  env -i PATH="$dir/bin:$dir/sys" "${settings[@]}" "$HOST_BASH" "$dir/logs-facts.sh" "$dir/host/docker" "$image" >"$dir/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ ! -e "$dir/sleeping" ] || break
    "$dir/sys/real-sleep" 0.2
  done
  [ -e "$dir/sleeping" ]
  kill -TERM "$pid"
  status=0
  wait "$pid" || status=$?
  output=$(cat "$dir/out")
  [[ $output != *"$dir"* && $output != *private* ]]
  failed "FAIL run: the run was stopped by a signal"
}

@test "SIGTERM during the run fails with FAIL run, on bash 3.2 too" {
  each_bash terminated
}

@test "docker is reached only through sudo -n and the docker path" {
  facts
  [ "$status" -eq 0 ]
  [ "$(grep -cvxF -- "-n $dir/host/docker" "$dir/sudo.log")" -eq 0 ]
  [ "$(wc -l <"$dir/sudo.log")" -eq "$(wc -l <"$dir/docker.log")" ]
}

@test "every reader is a locked-down throwaway container from the pinned image, bound with --mount" {
  facts
  [ "$status" -eq 0 ]
  runs=$(grep -c '^run ' "$dir/docker.log")
  [ "$runs" -eq 4 ]
  expected="run --rm -i --pull never --network none --log-driver none --user 0:0 --cap-drop ALL --security-opt no-new-privileges:true --read-only --mount type=bind,source=$data/containers,target=/var/log/docker-containers,readonly,bind-propagation=rprivate --entrypoint /usr/bin/env $image -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash --noprofile --norc -c set -euo pipefail; target=/var/log/docker-containers; "
  [ "$(grep -cF -- "$expected" "$dir/docker.log")" -eq "$runs" ]
  # Before the script: the script's own awk takes -v.
  sed 's/ -c set -euo pipefail; .*//' "$dir/docker.log" >"$dir/docker-options.log"
  [ "$(grep -cE -- '(^| )(-v|--volume|--privileged|--cap-add)( |=)' "$dir/docker-options.log")" -eq 0 ]
}

@test "the host side keeps to bash 3.2" {
  [[ -x /bin/bash ]] || skip "no /bin/bash"
  version=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')
  [[ $version == 3 ]] || skip "/bin/bash is not bash 3"
  HOST_BASH=/bin/bash facts
  [ "$status" -eq 0 ]
  [[ $output == *"OK all checks passed" ]]
}

@test "a wrong argument count stops the run before anything is asked" {
  run clean "$real_bash" "$dir/logs-facts.sh" "$dir/host/docker"
  [ "$status" -eq 1 ]
  [[ $output == "FAIL args: it takes the docker path and the Alloy image" ]]
  [ ! -e "$dir/sudo.log" ]
}

# --- D0 and A2 -------------------------------------------------------------

@test "a failed docker info stops at D0, and its private path never prints" {
  STUB_DOCKER_FAIL='info*' facts
  failed "FAIL D0: docker info failed"
}

@test "a data root that is not a plain absolute path stops at D0" {
  STUB_ROOT="relative/private-data-root" facts
  failed "FAIL D0: the data root is not a plain absolute path"
  STUB_ROOT="$data/../private" facts
  failed "FAIL D0: the data root is not a plain absolute path"
}

@test "a default log driver of an unexpected shape stops at D0 and never prints" {
  STUB_INFO="24.0.2 btrfs private-driver 4.4.302+" facts
  failed "FAIL D0: default-log-driver has an unexpected shape"
}

@test "docker info with an extra field stops at D0" {
  STUB_INFO="24.0.2 btrfs json-file 4.4.302+ private" facts
  failed "FAIL D0: docker info has an unexpected shape"
}

@test "a missing image stops at A2 and nothing runs" {
  STUB_NO_IMAGE=1 facts
  failed "FAIL A2: the pinned Alloy image is not on the host"
  [ "$(grep -c '^run ' "$dir/docker.log")" -eq 0 ]
}

# --- R1 and R2 -------------------------------------------------------------

@test "a mount below containers/ stops at R1" {
  echo "40 30 0:40 / $data/containers/private rw - tmpfs tmpfs rw" >>"$dir/host-mountinfo"
  facts
  failed "FAIL R1: a mount is at or below containers/"
}

@test "a mount table with no enclosing mount stops at R1" {
  : >"$dir/host-mountinfo"
  facts
  failed "FAIL R1: the mount table could not be read, or holds no enclosing mount"
}

@test "an awk whose interpreter is missing stops the run, and its path never prints" {
  {
    echo "#!$dir/private-interpreter/bin/awk-runtime"
    echo 'BEGIN { }'
  } >"$dir/bin/awk"
  chmod +x "$dir/bin/awk"
  facts
  failed "FAIL R1: the mount table could not be read, or holds no enclosing mount"
}

@test "a writable reader target stops at R2" {
  sed -i 's/ ro,relatime / rw,relatime /' "$dir/reader-mountinfo"
  facts
  failed "FAIL R2: the reader's mounts are not exactly one read-only target"
}

@test "a submount under the reader's target stops at R2" {
  echo "51 50 0:51 / $data/containers/private ro - tmpfs tmpfs rw" >>"$dir/reader-mountinfo"
  facts
  failed "FAIL R2: the reader's mounts are not exactly one read-only target"
}

@test "a reader that cannot start stops at R2" {
  STUB_DOCKER_FAIL='run *' facts
  failed "FAIL R2: the reader could not read its own mount table"
}

# --- R3 and R4 -------------------------------------------------------------

@test "a missing service stops at R3" {
  grep -v '^mimir ' "$dir/services" >"$dir/services.new"
  mv "$dir/services.new" "$dir/services"
  facts
  failed "FAIL R3: the running o11y services are not exactly the expected six"
}

@test "an unexpected container in the project stops at R3" {
  printf 'private-svc %s\n' "$(cid d1)" >>"$dir/services"
  facts
  failed "FAIL R3: docker ps has an unexpected shape"
}

@test "an unreadable log stops at R3" {
  STUB_HEAD_FAIL_ON="-c 1 $loki_log" facts
  failed "FAIL R3: a service's log was not globbed or not readable"
}

@test "a log the glob does not find stops at R3" {
  rm "$loki_log"
  facts
  failed "FAIL R3: a service's log was not globbed or not readable"
}

@test "an empty ls answer stops at R4 rather than reading as no ACL" {
  stub "$dir/bin/ls" <<<':'
  facts
  failed "FAIL R4: ls printed an unexpected mode word"
}

@test "an ACL mark on the target reads as yes" {
  stub "$dir/bin/ls" <<<'echo "drwx--x---+ 3 root root 4096 Oct 16 00:00 x"'
  facts
  [ "$status" -eq 0 ]
  [[ $output == *"R4 acl-on-target yes"* ]]
}

@test "a malformed mount table line stops at R1" {
  echo "private" >>"$dir/host-mountinfo"
  facts
  failed "FAIL R1: the mount table could not be read, or holds no enclosing mount"
}

@test "a failed stat on config.v2.json inside the reader stops at R4" {
  STUB_STAT_FAIL_ON='*config.v2.json' facts
  failed "FAIL R4: the reader failed"
}

# --- R5 and R6 -------------------------------------------------------------

@test "another app on an unknown log driver counts as other other-driver, and neither name prints" {
  printf '%s private-app private-driver\n' "$(cid c2)" >>"$dir/all"
  facts
  [ "$status" -eq 0 ]
  [[ $output == *"R5 other other-driver 1"* ]]
  [[ $output == *"R5 other json-file 1"* ]]
}

@test "a failed docker inspect stops at R5" {
  STUB_DOCKER_FAIL='inspect -f {{index .Config.Labels*' facts
  failed "FAIL R5: docker inspect failed"
}

@test "an inspect that misses a container stops at R5" {
  STUB_INSPECT_SKIP=c facts
  failed "FAIL R5: docker inspect did not report one line per container"
}

@test "a labels option holding a path stops at R6, and the value never prints" {
  echo "json-file|10m|3|/private/labels||3" >"$dir/logconfig/$(cid a3)"
  facts
  failed "FAIL R6: a service has an unexpected labels option"
}

@test "a service off json-file 10m x 3 stops at R6" {
  echo "json-file|20m|3|||2" >"$dir/logconfig/$(cid a3)"
  facts
  failed "FAIL R6: a service is not on json-file 10m x 3"
}

@test "an unexpected mode option stops at R6" {
  echo "json-file|10m|3||private-mode|3" >"$dir/logconfig/$(cid a3)"
  facts
  failed "FAIL R6: a service has an unexpected mode option"
}

# --- A4 --------------------------------------------------------------------

@test "one rotation in the window sums the two parts" {
  STUB_ON_SLEEP="printf 12345 >>'$loki_log' && mv '$loki_log' '$loki_log.1' && printf 1234567 >'$loki_log'" facts
  [ "$status" -eq 0 ]
  [[ $output == *"A4 loki-bytes-a-day 1728"* ]]
}

@test "two rotations in the window stop at A4" {
  STUB_ON_SLEEP="ln '$loki_log' '$dir/keep0' && mv '$loki_log' '$loki_log.1' && printf a >'$loki_log' && ln '$loki_log' '$dir/keep1' && mv '$loki_log' '$loki_log.1' && printf b >'$loki_log'" facts
  failed "FAIL A4: a log rotated more than once in the window; shorten it"
}

@test "a log that shrank without rotating stops at A4" {
  STUB_ON_SLEEP="printf x >'$loki_log'" facts
  failed "FAIL A4: a log shrank without rotating"
}

@test "a rotated log smaller than before it rotated stops at A4" {
  STUB_ON_SLEEP="mv '$loki_log' '$loki_log.1' && : >'$loki_log.1' && printf ab >'$loki_log'" facts
  failed "FAIL A4: a rotated log is smaller than before it rotated"
}

@test "loki dropping out during A4's window stops at A4" {
  STUB_ON_SLEEP="grep -v '^loki ' '$dir/services' >'$dir/services.new' && mv '$dir/services.new' '$dir/services'" facts
  failed "FAIL A4: the services changed during the window"
}

@test "a container recreated during A4's window stops at A4" {
  STUB_ON_SLEEP="sed -i 's/^loki .*/loki $(cid f3)/' '$dir/services'" facts
  failed "FAIL A4: the services changed during the window"
}

@test "a container that is not running stops at R3" {
  sed -i 's/^\(loki .*\)$/\1 restarting/' "$dir/services"
  facts
  failed "FAIL R3: docker ps has an unexpected shape"
}

@test "a failed stat inside A4's snapshot stops at A4" {
  STUB_STAT_FAIL_ON='-c %i %s *' facts
  failed "FAIL A4: the reader failed"
}

@test "a snapshot with an extra field stops at A4" {
  STUB_STAT_EXTRA=1 facts
  failed "FAIL A4: a snapshot has an unexpected shape"
}

# --- A5 --------------------------------------------------------------------

@test "ss answers when netstat is missing" {
  rm "$dir/bin/netstat"
  stub "$dir/bin/ss" <<<'printf "State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 128 *:8080 *:*\nLISTEN 0 128 [::]:22 [::]:*\n"'
  facts
  [ "$status" -eq 0 ]
  [[ $output == *"A5 tcp-ports-on-all-addresses 22 8080"* ]]
}

@test "a host with neither netstat nor ss stops at A5" {
  rm "$dir/bin/netstat"
  facts
  failed "FAIL A5: neither netstat nor ss is on the host"
}

@test "a failed netstat with no ss stops at A5" {
  STUB_NETSTAT_FAIL=1 facts
  failed "FAIL A5: netstat failed"
}

@test "a port with a leading zero stops at A5 rather than reaching arithmetic" {
  echo "tcp 0 0 0.0.0.0:08 0.0.0.0:* LISTEN" >>"$dir/netstat"
  facts
  failed "FAIL A5: a port has an unexpected shape"
}

@test "a port above 65535 stops at A5" {
  echo "tcp 0 0 0.0.0.0:65536 0.0.0.0:* LISTEN" >>"$dir/netstat"
  facts
  failed "FAIL A5: a port has an unexpected shape"
}

@test "netstat output without its header stops at A5 rather than reading as no listeners" {
  echo "private output in no known shape" >"$dir/netstat"
  facts
  failed "FAIL A5: the listener table has an unexpected shape"
  : >"$dir/netstat"
  facts
  failed "FAIL A5: the listener table has an unexpected shape"
}

@test "a netstat line that is not a listening TCP line stops at A5" {
  echo "udp 0 0 0.0.0.0:53 0.0.0.0:* private" >>"$dir/netstat"
  facts
  failed "FAIL A5: the listener table has an unexpected shape"
}

@test "no listener on all addresses prints none" {
  printf 'Proto Recv-Q Send-Q Local Address Foreign Address State\ntcp 0 0 127.0.0.1:3000 0.0.0.0:* LISTEN\n' >"$dir/netstat"
  facts
  [ "$status" -eq 0 ]
  [[ $output == *"A5 tcp-ports-on-all-addresses none"* ]]
}

# --- N7 --------------------------------------------------------------------

@test "a non-numeric df stops at N7" {
  STUB_DF="/dev/md0 2385528 1700000 private 75% /" facts
  failed "FAIL N7: root-free-kib has an unexpected shape"
}

@test "a failed df stops at N7" {
  STUB_DF_FAIL=1 facts
  failed "FAIL N7: df failed"
}

@test "an awk that prints valid sizes and then fails stops at N7" {
  STUB_AWK_FAIL_ON='*Filesystem*' facts
  failed "FAIL N7: the df output could not be read"
}
