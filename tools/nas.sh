#!/usr/bin/env bash
# Every action on the deploy host, one subcommand per mise task:
#
#   tools/nas.sh <task> [arguments]
#
# Read-only: preflight, deploy-plan (no SSH at all), status, logs [service],
# serve-status, smoke-remote [--grpc], grafana-password.
# State-changing, each refused unless O11Y_CONFIRM=<task> is set: stage,
# gate-test, gate-clean, deploy, rollback [--previous], down, serve-apply,
# serve-clear.
#
# A deploy never edits what a running stack uses. `stage` uploads a rendered
# release beside the others, verifying it before it gets its final name.
# `deploy` starts it and moves the `current` pointer only once the health
# gate has passed, so the last release that passed stays intact. Every task
# that changes the host's directory or a project runs under one lock,
# .deploy.lock in O11Y_REMOTE_DIR, taken before it reads any state there.
#
# Rules every remote command follows:
# - The host only grants root as `sudo -n` on the docker and docker-compose
#   paths, so nothing else ever follows sudo. tailscale runs without it.
# - Compose is the standalone docker-compose, always with -p <project>.
# - Utility containers override both the user and the entrypoint.
# - The generated secrets are never read, printed or copied. Compose loads
#   the real env file only where a container needs it (init, up, run); every
#   other call names .env.validate, which points at a dummy. `config` runs
#   only locally, only on that dummy. Nothing runs `docker inspect`.
#   grafana-password is the one deliberate exception.
# - --remove-orphans is passed only with compose.yaml alone. With the init
#   or tools file it would remove the running stack.
#
# Unlike the local test scripts this one runs on the real O11Y_* values, so
# it never calls isolate_environment, and it never pins the Docker API
# version: local Compose calls here only load a model.
#
# Environment (mise.local.toml), each validated by the tasks that use it:
#   O11Y_SSH_HOST          SSH host alias
#   O11Y_REMOTE_DIR        directory on the host that holds everything
#   O11Y_REMOTE_DOCKER     absolute path of docker on the host
#   O11Y_REMOTE_COMPOSE    absolute path of docker-compose on the host
#   O11Y_REMOTE_TAILSCALE  absolute path of tailscale on the host
#   O11Y_TAILNET_DOMAIN    tailnet DNS name the two Services live under
#   O11Y_GRAFANA_PORT, O11Y_OTLP_GRPC_PORT, O11Y_OTLP_HTTP_PORT
#                          loopback ports on the host (3000, 4317, 4318)
#   O11Y_HEALTH_TIMEOUT    seconds each health wait may take (300)
#   O11Y_DISK_RESERVE_GB   free space preflight, gate-test and deploy require
#                          under O11Y_REMOTE_DIR, in GiB (50), on top of 10
#                          percent of the filesystem
#
# Output is variable names, release ids and pass or fail lines. Everything
# a task prints goes to tmp/deploy/<task>.log, and the remote diagnostics it
# keeps out of sight go to tmp/deploy/<task>.raw.log. Both are private.
# Everything a task prints, such as versions, the serve configuration,
# container logs or an SSH error, has the deployment's paths, names and
# tailnet addresses replaced with placeholders first. deploy-plan and
# grafana-password are the only tasks that print private values.
# Never add `set -x`: the commands hold deployment paths.
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck source=tools/lib.sh
source tools/lib.sh

task=${1:-}
[[ $# -eq 0 ]] || shift

services=(rustfs loki tempo mimir alloy grafana)
id_re='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4,40}$'
timeout=${O11Y_HEALTH_TIMEOUT:-300}
reserve_gb=${O11Y_DISK_RESERVE_GB:-50}
dir=${O11Y_REMOTE_DIR:-}
docker="sudo -n ${O11Y_REMOTE_DOCKER:-}"
tailscale=${O11Y_REMOTE_TAILSCALE:-}
grafana_port=${O11Y_GRAFANA_PORT:-3000}
grpc_port=${O11Y_OTLP_GRPC_PORT:-4317}
http_port=${O11Y_OTLP_HTTP_PORT:-4318}
log=/dev/null
diagnostics_log=/dev/null
locked=0
gate_release=
swap_pending=
model=
free_kb=
total_kb=

# --- validation -----------------------------------------------------------

need_path() {
  local value=${!1:-} dots='(^|/)\.\.(/|$)'
  [[ $value =~ ^/[A-Za-z0-9._/-]+$ && $value != *//* && $value != */ && ! $value =~ $dots ]] ||
    die "$task: $1 must be an absolute path of letters, digits, dots, hyphens and underscores, with no .. segment and no doubled or trailing slash"
}

need_port() {
  if [[ ! $2 =~ ^[1-9][0-9]{0,4}$ ]] || (($2 > 65535)); then
    die "$task: $1 must be a port from 1 to 65535"
  fi
}

# need <kind>...: each task names what it uses, and only that is checked.
# A message names the variable, never its value.
need() {
  local what label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
  for what in "$@"; do
    case $what in
    host)
      [[ ${O11Y_SSH_HOST:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
        die "$task: O11Y_SSH_HOST must be a host alias of letters, digits, dots, hyphens and underscores"
      ;;
    dir) need_path O11Y_REMOTE_DIR ;;
    docker) need_path O11Y_REMOTE_DOCKER ;;
    compose) need_path O11Y_REMOTE_COMPOSE ;;
    tailscale) need_path O11Y_REMOTE_TAILSCALE ;;
    domain)
      [[ ${O11Y_TAILNET_DOMAIN:-} =~ ^$label(\.$label)+$ ]] || die "$task: O11Y_TAILNET_DOMAIN must be a DNS name"
      ;;
    reserve)
      [[ $reserve_gb =~ ^[0-9]{1,6}$ ]] || die "$task: O11Y_DISK_RESERVE_GB must be a whole number of GiB"
      ;;
    ports)
      need_port O11Y_GRAFANA_PORT "$grafana_port"
      need_port O11Y_OTLP_GRPC_PORT "$grpc_port"
      need_port O11Y_OTLP_HTTP_PORT "$http_port"
      ;;
    esac
  done
}

confirm() {
  [[ ${O11Y_CONFIRM:-} == "$task" ]] ||
    die "$task changes state on the host. Run it as: O11Y_CONFIRM=$task mise run $task"
}

# --- remote plumbing ------------------------------------------------------

# q <word>...: the words quoted for the remote shell.
q() {
  local word out='' sq="'" esc="'\\''"
  for word in "$@"; do
    if [[ $word =~ ^[A-Za-z0-9._/:=@%+,-]+$ ]]; then
      out+=" $word"
    else
      out+=" '${word//$sq/$esc}'"
    fi
  done
  printf '%s' "${out# }"
}

# One multiplexed connection per run, so the agent signs once. The socket
# lives in ~/.ssh, which is the user's own, rather than under TMPDIR: macOS's
# TMPDIR is long enough that the socket's path, with the 17 characters ssh
# appends while it binds, passes the 104-byte limit on a socket's path. Here
# it is $HOME plus 51 bytes, which fits any HOME under 36, and no other user
# can plant a directory in its way, as one could under a fixed name in /tmp.
# The connection master can outlive the task, so ssh gets no descriptor
# beyond the standard three: the cleanup descriptor would hold the output open.
remote_stdin() {
  [[ -d $HOME/.ssh ]] || mkdir -m 700 "$HOME/.ssh"
  ssh -o BatchMode=yes -o ControlMaster=auto -o ControlPersist=10m -o "ControlPath=$HOME/.ssh/o11y-%C" \
    -- "$O11Y_SSH_HOST" "$1" 9>&-
}

remote() {
  remote_stdin "$1" </dev/null
}

# quiet <command...>: the command's output to the diagnostics log, a
# regular file, so no reader can fail it or hold it open, and its status
# is its own.
quiet() {
  "$@" >>"$diagnostics_log" 2>&1
}

# compose_cmd <project> <release dir> <env file> <compose file>...
compose_cmd() {
  local out="sudo -n $O11Y_REMOTE_COMPOSE -p $1 --env-file $2/$3" release=$2 file
  shift 3
  for file in "$@"; do
    out+=" -f $release/$file"
  done
  echo "$out"
}

of_project() {
  echo "--filter label=com.docker.compose.project=$1"
}

# util_cmd <host dir> <script>: root in a utility container with no network
# and the directory at /d. It can reach the secret files, so it keeps no log.
util_cmd() {
  echo "$docker run --rm --log-driver none --user 0:0 --network none --entrypoint /bin/sh -v $1:/d $(image_of init) -c $(q "$2")"
}

# Exits 1 when the lock is taken, 3 when the directory can't be made.
lock_cmd() {
  echo "mkdir -p $dir || exit 3; mkdir $dir/.deploy.lock"
}

attempt_cmd() {
  echo "echo $1 >$dir/attempt.new && mv $dir/attempt.new $dir/attempt"
}

# swap_cmd <new current> <new previous or nothing>: the pointer moves of a
# deploy or a rollback, in one remote command. Each is a rename over the old
# link, so a reader sees the old target or the new one and never a missing
# link. Both new links exist before either rename, and the
# remote shell finishes the two renames even when the local side dies or
# the connection drops, since it has no terminal to lose.
swap_cmd() {
  local cmd="cd $dir && ln -sfn releases/$1 current.new"
  if [[ -n $2 && $2 != "$1" ]]; then
    echo "$cmd && ln -sfn releases/$2 previous.new && mv -T previous.new previous && mv -T current.new current"
  else
    echo "$cmd && mv -T current.new current"
  fi
}

# gate_down_cmd <gate release dir>: stops the o11y-gate project. Compose
# 2.20.1's `down` leaves one-off `run` containers, such as an s3probe that a
# failed probe left behind, unless it removes orphans. That is safe here
# because it names the disposable project with compose.yaml alone.
gate_down_cmd() {
  echo "$(compose_cmd o11y-gate "$1" .env.validate compose.yaml) down --remove-orphans"
}

lock() {
  local status=0
  quiet remote "$(lock_cmd)" || status=$?
  case $status in
  0) locked=1 ;;
  1) die "$task: the lock exists, so another run is active or one was interrupted. Look at .deploy.lock under O11Y_REMOTE_DIR on the host, and remove it with rmdir once no run is active" ;;
  3) die "$task: O11Y_REMOTE_DIR could not be created on the host" ;;
  *) die "$task: the host could not be reached to take the lock" ;;
  esac
}

# A failed unlock fails the run, even one that otherwise passed.
# A run ended by a signal keeps the lock: a remote command it started may
# still be running as root.
# A signal can arrive while a command's output goes to the task log, so the
# messages go to the terminal's stderr, saved as descriptor 9 at the start.
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $gate_release ]]; then
    # A failed rehearsal keeps its container logs, then stops like any other.
    [[ $status -eq 0 ]] || quiet remote "$(compose_cmd o11y-gate "$gate_release" .env.validate compose.yaml) logs --no-color --tail=500" || true
    # Only a failed run gets here: a passing gate-test stops the project
    # itself and reports it.
    quiet remote "$(gate_down_cmd "$gate_release")" ||
      echo "FAIL $task: the o11y-gate project could not be stopped" >&9
  fi
  if [[ -n $swap_pending ]]; then
    # The swap may have stopped halfway, so the lock stays until someone
    # has looked at the two pointers.
    # shellcheck disable=SC2086 # two ids
    set -- $swap_pending
    local expected="current should name release $1 and previous release ${2:-}"
    [[ -n ${2:-} && ${2:-} != "$1" ]] || expected="current should name release $1, and previous stays as it was"
    echo "FAIL $task: the pointer swap may not have finished, so the lock stays. On the host, $expected. Check the links in O11Y_REMOTE_DIR, set them to match, then remove .deploy.lock" >&9
    ((status != 0)) || status=1
  elif [[ $locked -eq 1 ]]; then
    if ((status >= 128)); then
      echo "FAIL $task: interrupted, so the lock stays. Look at .deploy.lock under O11Y_REMOTE_DIR on the host, and remove it with rmdir once no run is active" >&9
    elif ! quiet remote "rmdir $dir/.deploy.lock"; then
      echo "FAIL $task: the lock could not be removed" >&9
      [[ $status -ne 0 ]] || status=1
    fi
  fi
  exit "$status"
}

# redact: the remote output on stdin, fit for the terminal. The deployment's
# directory, host alias, tailnet domain and private strings become
# placeholders, and tailnet addresses become <tailnet address>. The raw
# output stays in the task log.
redact() {
  local line entry entries=() private='<private>'
  # shellcheck disable=SC2016 # the placeholders are the variable names
  local dir_name='$O11Y_REMOTE_DIR' domain_name='$O11Y_TAILNET_DOMAIN' host_name='$O11Y_SSH_HOST'
  IFS=, read -r -a entries <<<"${O11Y_PRIVATE_STRINGS:-}"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${O11Y_REMOTE_DIR:-} ]] || line=${line//"$O11Y_REMOTE_DIR"/$dir_name}
    [[ -z ${O11Y_TAILNET_DOMAIN:-} ]] || line=${line//"$O11Y_TAILNET_DOMAIN"/$domain_name}
    [[ -z ${O11Y_SSH_HOST:-} ]] || line=${line//"$O11Y_SSH_HOST"/$host_name}
    for entry in ${entries[@]+"${entries[@]}"}; do
      [[ ${#entry} -lt 4 ]] || line=${line//"$entry"/$private}
    done
    printf '%s\n' "$line"
  done | sed -E -e 's/(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])(\.[0-9]{1,3}){2}/\1<tailnet address>/g' \
    -e 's/fd7a:115c:a1e[0]:[0-9a-fA-F:]*/<tailnet address>/g'
}

# shown <remote command>: runs it with its errors on its output, which the
# task log keeps and the operator sees redacted.
shown() {
  remote "$1" 2>&1
}

# promoted <pointer>: the release id the pointer names, or nothing.
promoted() {
  local target
  target=$(remote "if [ -L $dir/$1 ]; then readlink $dir/$1; fi") || die "$task: the host could not be asked for $1"
  [[ -n $target ]] || return 0
  [[ $target == releases/* && ${target#releases/} =~ $id_re ]] || die "$task: $1 on the host does not name a release"
  echo "${target#releases/}"
}

# active: the promoted release, or the recorded attempt when none ever was.
# Bash drops `set -e` inside a command substitution, which is where this
# runs, so a failed lookup has to end it by hand.
active() {
  local id
  id=$(promoted current) || exit 1
  if [[ -z $id ]]; then
    id=$(remote "if [ -f $dir/attempt ]; then cat $dir/attempt; fi") || die "$task: the host could not be asked for the attempt"
    [[ -n $id ]] || die "$task: no release was promoted and no attempt is recorded, so there is nothing to act on"
    [[ $id =~ $id_re ]] || die "$task: the recorded attempt is not a release id"
  fi
  echo "$id"
}

# --- local render and model -----------------------------------------------

# Loads a model only, on the dummy env file, with nothing inherited.
local_compose() {
  env -i PATH="$PATH" HOME="$HOME" "$O11Y_COMPOSE" "$@"
}

# render_release <outdir> <project> <data dir> <Grafana URL> <three ports>:
# renders for the host and checks that the three models load.
render_release() {
  local out=$1 project=$2 file
  (
    unset O11Y_SECRETS_OWNER
    export O11Y_DATA_DIR=$3 O11Y_GRAFANA_ROOT_URL=$4
    export O11Y_GRAFANA_PORT=$5 O11Y_OTLP_GRPC_PORT=$6 O11Y_OTLP_HTTP_PORT=$7
    tools/render.sh "$out" --config-root "$dir/config"
  ) || die "$task: render failed"
  for file in compose.yaml compose.init.yaml compose.tools.yaml; do
    local_compose -p "$project" --env-file "$out/release/.env.validate" -f "$out/release/$file" config -q ||
      die "$task: $file does not load"
  done
}

# load_model [release dir]: the resolved model that image references are
# read from. Without a release it renders a throwaway one on placeholders.
load_model() {
  local release=${1:-} scratch=''
  if [[ -z $release ]]; then
    scratch=$(mktemp -d)
    (
      unset O11Y_SECRETS_OWNER O11Y_GRAFANA_PORT O11Y_OTLP_GRPC_PORT O11Y_OTLP_HTTP_PORT
      O11Y_DATA_DIR=/srv/o11y/data O11Y_GRAFANA_ROOT_URL=http://127.0.0.1/ tools/render.sh "$scratch"
    ) || die "$task: render failed"
    release=$scratch/release
  fi
  model=$(local_compose -p o11y --profile tools --env-file "$release/.env.validate" \
    -f "$release/compose.yaml" -f "$release/compose.tools.yaml" -f "$release/compose.init.yaml" config --format json) ||
    die "$task: the Compose model does not load"
  [[ -z $scratch ]] || rm -rf "$scratch"
  jq -e '[.services["init", "rustfs", "loki", "tempo", "mimir", "alloy", "grafana", "telemetrygen", "s3probe"].image] | all' \
    <<<"$model" >/dev/null || die "$task: the Compose model lacks an image reference"
}

image_of() {
  jq -er --arg s "$1" '.services[$s].image' <<<"$model"
}

new_release_id() {
  local commit
  commit=$(git rev-parse --short HEAD) || die "$task: a release id needs the commit, and this is not a git checkout"
  echo "$(date -u +%Y%m%dT%H%M%SZ)-$commit"
}

# --- staging --------------------------------------------------------------

prepare_cmd() {
  echo "mkdir -p $dir/config $1 && rm -rf $dir/config/.incoming-* $1/.incoming-*"
}

verify_cmd() {
  echo "cd $1 && sha256sum -c MANIFEST.sha256 >/dev/null"
}

pull_cmd() {
  echo "$(compose_cmd o11y "$dir/releases/$1" .env.validate compose.yaml compose.tools.yaml) --profile tools pull -q"
}

# upload <local dir> <remote parent> <name>: the directory arrives under a
# temporary name and is renamed only once its manifest verifies there, so a
# final name always means a complete copy. One that already exists is
# verified again, not trusted and not replaced.
upload() {
  local final=$2/$3 incoming=$2/.incoming-$3
  if remote "test -e $final"; then
    quiet remote "$(verify_cmd "$final")" ||
      die "$task: $3 is already on the host and no longer matches its manifest. Nothing was changed; inspect it before staging again"
    return
  fi
  COPYFILE_DISABLE=1 tar -cf - -C "$1" . | quiet remote_stdin "mkdir $incoming && tar -xpf - -C $incoming" ||
    die "$task: the upload of $3 failed"
  quiet remote "$(verify_cmd "$incoming")" ||
    die "$task: $3 does not match its manifest after the upload. It was left under its temporary name and nothing was renamed"
  quiet remote "mv -T $incoming $final" || die "$task: $3 could not be renamed into place"
}

upload_configs() {
  local config
  for config in "$1"/config/*/; do
    upload "${config%/}" "$dir/config" "$(basename "$config")"
  done
}

stage() {
  local id out
  id=$(new_release_id)
  out=tmp/deploy/$id
  render_release "$out" o11y "$dir/data" "https://grafana.$O11Y_TAILNET_DOMAIN/" "$grafana_port" "$grpc_port" "$http_port"
  quiet remote "$(prepare_cmd "$dir/releases")" || die "$task: the release directories could not be prepared on the host"
  upload_configs "$out"
  upload "$out/release" "$dir/releases" "$id"
  quiet remote "$(pull_cmd "$id")" || die "$task: the images could not be pulled"
  echo "$id" >tmp/deploy/staged
  ok "$task: release $id is on the host, verified, and its images are pulled. Nothing was started"
}

# staged: the release the last stage produced, when it is of this commit.
staged() {
  local id
  [[ -f tmp/deploy/staged ]] || return 0
  id=$(<tmp/deploy/staged)
  [[ $id =~ $id_re && $id == *-"$(git rev-parse --short HEAD)" && -d tmp/deploy/$id/release ]] || return 0
  echo "$id"
}

# --- health gate ----------------------------------------------------------

# containers <project>: one "service name compose-files status" line each,
# stopped ones included. `docker ps` reports state without the environment
# that `docker inspect` would print.
containers() {
  remote "$docker ps -a $(of_project "$1") --format $(q '{{.Label "com.docker.compose.service"}} {{.Names}} {{.Label "com.docker.compose.project.config_files"}} {{.Status}}')"
}

container_of() {
  containers "$1" | awk -v s="$2" '$1 == s { print $2; exit }'
}

# The bucket one-shot exited 0, all six services are up, and the four with a
# healthcheck report healthy. A changed backend config recreates Alloy and
# Grafana too, so this always looks at every service.
settled() {
  local listing service
  listing=$(containers "$1") || return 1
  grep -Eq '^s3-buckets [^ ]+ [^ ]+ Exited \(0\)' <<<"$listing" || return 1
  for service in "${services[@]}"; do
    grep -Eq "^$service [^ ]+ [^ ]+ Up " <<<"$listing" || return 1
  done
  for service in rustfs tempo alloy grafana; do
    grep -Eq "^$service [^ ]+ [^ ]+ Up .*\(healthy\)" <<<"$listing" || return 1
  done
}

ready_url() {
  case $1 in
  rustfs) echo http://127.0.0.1:9000/health/ready ;;
  loki) echo http://loki:3100/ready ;;
  tempo) echo http://tempo:3200/ready ;;
  mimir) echo http://mimir:8080/ready ;;
  alloy) echo http://alloy:12345/-/ready ;;
  grafana) echo http://grafana:3000/api/health ;;
  esac
}

# in_network <container> <curl arguments...>: curl inside the rustfs
# container, the one image on the stack's network that has it.
in_network() {
  local container=$1
  shift
  remote_stdin "$docker exec -i $container curl $(q "$@")"
}

http_status() {
  in_network "$@" -s -o /dev/null -w '%{http_code}' -m 10 </dev/null
}

is_ready() {
  local code
  code=$(http_status "$1" "$2") || return 1
  [[ $code == 200 ]]
}

# all_ready <project>: prints the first thing that is not ready and fails.
all_ready() {
  local rustfs service
  poll "$timeout" settled "$1" || {
    echo "the containers of $1 did not all come up healthy"
    return 1
  }
  rustfs=$(container_of "$1" rustfs) || {
    echo "the containers of $1 could not be listed"
    return 1
  }
  for service in "${services[@]}"; do
    poll "$timeout" is_ready "$rustfs" "$(ready_url "$service")" || {
      echo "$service is not ready"
      return 1
    }
  done
}

# receipt <project> <receipt.sh arguments...>: the receipt check from inside
# the stack's network.
receipt() {
  local rustfs
  rustfs=$(container_of "$1" rustfs) || return 1
  shift
  O11Y_CHECK_CURL="bash tools/nas.sh in-network-curl $rustfs" O11Y_CHECK_OTLP_URL=http://alloy:4318 \
    O11Y_CHECK_GRAFANA_URL=http://grafana:3000 quiet tools/receipt.sh ${1+"$@"} </dev/null 9>&-
}

# health_gate <project> [receipt.sh arguments...]
health_gate() {
  local project=$1 why
  shift
  why=$(all_ready "$project") || {
    echo "FAIL $task: $why" >&2
    return 1
  }
  receipt "$project" ${1+"$@"} || {
    echo "FAIL $task: the receipt check failed; see $diagnostics_log" >&2
    return 1
  }
}

# The host's dockerd refuses to create a missing bind mount source, so the
# data directory init mounts is made first, as the SSH user. Init sets the
# owners and modes of what it creates inside, and a directory that exists
# is left as it is.
data_cmd() {
  echo "mkdir -p -m 755 $dir/data"
}

up_cmd() {
  echo "$(compose_cmd o11y "$dir/releases/$1" .env compose.yaml) up -d --remove-orphans"
}

# fs_type_cmd: the type of the filesystem under O11Y_REMOTE_DIR, or under
# its nearest existing ancestor before the first stage, else "unknown".
# df -T names it from the mount table. Where df lacks -T, or prints - because
# the table doesn't name the type, stat reads it from the filesystem itself.
fs_type_cmd() {
  echo "d=$dir; while [ ! -e \"\$d\" ]; do d=\$(dirname \"\$d\"); done; t=\$(df -PT \"\$d\" 2>/dev/null | awk 'NR == 2 { print \$2 }'); case \$t in '' | -) t=\$(stat -f -c %T \"\$d\" 2>/dev/null) ;; esac; echo \"\${t:-unknown}\""
}

# disk_cmd: kilobytes available and in total on the filesystem under
# O11Y_REMOTE_DIR, or under its nearest existing ancestor before the first
# stage.
disk_cmd() {
  echo "d=$dir; while [ ! -e \"\$d\" ]; do d=\$(dirname \"\$d\"); done; df -Pk \"\$d\" | awk 'NR == 2 { print \$4, \$2 }'"
}

# disk_space: sets free_kb and total_kb, or fails.
disk_space() {
  local out
  out=$(remote "$(disk_cmd)") || return 1
  read -r free_kb total_kb <<<"$out"
  [[ $free_kb =~ ^[0-9]+$ && $total_kb =~ ^[1-9][0-9]*$ ]]
}

# disk_summary: free space in GiB and as a percentage of the filesystem.
disk_summary() {
  echo "$((free_kb / 1048576)) GiB free of $((total_kb / 1048576)) GiB ($((free_kb * 100 / total_kb)) percent)"
}

# disk_gate: refuses to go on with less than the reserve free, or less than
# 10 percent of the filesystem. It runs once the task holds the lock, if it
# takes one, so a refusal goes through the ordinary cleanup and frees it.
# Rollback never calls it: going back to the last release that passed must
# work on a full disk too.
disk_gate() {
  disk_space || die "$task: the host could not be asked for its free space under O11Y_REMOTE_DIR"
  if ((free_kb < reserve_gb * 1048576 || free_kb * 10 < total_kb)); then
    die "$task: the filesystem under O11Y_REMOTE_DIR has $(disk_summary), below the reserve of $reserve_gb GiB and 10 percent. Nothing was started"
  fi
  ok "$task: the filesystem under O11Y_REMOTE_DIR has $(disk_summary), above the reserve of $reserve_gb GiB and 10 percent"
}

# --- tasks ----------------------------------------------------------------

preflight() {
  local failed=0 version
  # fact <required|noted> <label> <summary> <remote command>: the raw output
  # goes to the diagnostics log. The summary is `text` for the redacted
  # output, `lines` for a count of its lines, or `serve` for whether a
  # configuration exists.
  fact() {
    local out status=ok summary
    out=$(remote "$4" 2>&1) || status=FAIL
    printf '%s\n' "--- $2" "$out" >>"$diagnostics_log"
    [[ $status == ok || $1 == required ]] || status=note
    case $3 in
    text) summary=$(redact <<<"$out" | tr '\n' ' ') ;;
    lines) summary="$(grep -c . <<<"$out" || true) line(s); listed in $diagnostics_log" ;;
    serve) if grep -q 'No serve config' <<<"$out"; then summary=none; else summary="configured; shown in $diagnostics_log"; fi ;;
    esac
    echo "$status $task: $2${summary:+: ${summary% }}"
    [[ $status != FAIL ]] || failed=1
  }
  fact required "SSH reaches the host" text "uname -sr"
  fact required "sudo -n runs docker" text "$docker version --format $(q 'client {{.Client.Version}}, server {{.Server.Version}}')"
  version=$("$O11Y_COMPOSE" version --short)
  fact required "sudo -n runs docker-compose, at the version the local tests pin ($version)" text \
    "sudo -n $O11Y_REMOTE_COMPOSE version --short | grep -F $(q "$version")"
  fact required "tailscale answers without sudo" text "$tailscale version | head -n 1"
  fact noted "serve configuration" serve "$tailscale serve status"
  fact required "sha256sum exists and mv accepts -T, which staging and promotion rely on" text \
    "sha256sum --version >/dev/null && mv --help 2>&1 | grep -q -- -T"
  fact noted "listeners on the stack's ports (none before the first deploy)" lines \
    "netstat -ltn | grep -E $(q ":($grafana_port|$grpc_port|$http_port) ") || true"
  fact noted "filesystem where O11Y_REMOTE_DIR will live" text "$(fs_type_cmd)"
  fact noted "existing containers" lines "$docker ps -a --format $(q '{{.Names}} {{.Image}} {{.Status}}')"
  [[ $failed -eq 0 ]] || die "$task: a required fact does not hold"
  disk_gate
}

deploy_plan() {
  local out=tmp/deploy/plan id config
  id=$(new_release_id)
  rm -rf "$out"
  render_release "$out" o11y "$dir/data" "https://grafana.$O11Y_TAILNET_DOMAIN/" "$grafana_port" "$grpc_port" "$http_port"
  load_model "$out/release"
  echo "release id: $id (stage stamps its own time)"
  echo "images:"
  jq -r '.services | to_entries[] | "  \(.key) \(.value.image)"' <<<"$model"
  echo "published ports:"
  jq -r '.services | to_entries[] | .key as $s | .value.ports[]? | "  \($s) \(.host_ip):\(.published) -> \(.target)"' <<<"$model"
  echo "release .env:"
  sed 's/^/  /' "$out/release/.env"
  echo "remote commands, in order, each over SSH to O11Y_SSH_HOST:"
  {
    echo "# stage, which deploy runs too when nothing is staged for this commit"
    lock_cmd
    prepare_cmd "$dir/releases"
    for config in "$out"/config/*/; do
      config=$(basename "$config")
      echo "test -e $dir/config/$config    # when it exists: verify it and upload nothing"
      echo "mkdir $dir/config/.incoming-$config && tar -xpf - -C $dir/config/.incoming-$config"
      verify_cmd "$dir/config/.incoming-$config"
      echo "mv -T $dir/config/.incoming-$config $dir/config/$config"
    done
    echo "mkdir $dir/releases/.incoming-$id && tar -xpf - -C $dir/releases/.incoming-$id"
    verify_cmd "$dir/releases/.incoming-$id"
    echo "mv -T $dir/releases/.incoming-$id $dir/releases/$id"
    pull_cmd "$id"
    echo "rmdir $dir/.deploy.lock"
    echo "# deploy"
    lock_cmd
    verify_cmd "$dir/releases/$id"
    attempt_cmd "$id"
    data_cmd
    echo "$(compose_cmd o11y "$dir/releases/$id" .env compose.init.yaml) run --rm -T init"
    up_cmd "$id"
    echo "$docker ps -a $(of_project o11y) --format ...    # repeated until every service is up and healthy"
    echo "$docker exec -i <rustfs container> curl ...    # readiness of each service, then the receipt check"
    echo "$(swap_cmd "$id" '<the release current names>')    # on a first deploy, only current"
    echo "rmdir $dir/.deploy.lock"
  } | sed 's/^/  /'
}

deploy() {
  local id current
  disk_gate
  id=$(staged)
  if [[ -z $id ]] || ! quiet remote "$(verify_cmd "$dir/releases/$id")"; then
    stage
    id=$(<tmp/deploy/staged)
  fi
  current=$(promoted current)
  quiet remote "$(attempt_cmd "$id")" || die "$task: the attempt could not be recorded"
  quiet remote "$(data_cmd)" || die "$task: the data directory could not be created"
  if quiet remote "$(compose_cmd o11y "$dir/releases/$id" .env compose.init.yaml) run --rm -T init" &&
    quiet remote "$(up_cmd "$id")" &&
    health_gate o11y; then
    swap_pending="$id $current"
    quiet remote "$(swap_cmd "$id" "$current")" || die "$task: release $id passed the health gate, but the pointers could not be moved"
    swap_pending=
    ok "$task: release $id passed the health gate and is now current"
    return
  fi
  echo "FAIL $task: release $id was not promoted and is left as it is for inspection; see $diagnostics_log" >&2
  if [[ -n $current ]]; then
    echo "To return to release $current, the last one that passed: O11Y_CONFIRM=rollback mise run rollback" >&2
  else
    echo "No release was ever promoted. First-deploy cleanup, which stops the recorded attempt: O11Y_CONFIRM=down mise run down" >&2
  fi
  exit 1
}

# rollback [--previous]: starts current again, or previous. Once previous
# passes the health gate the two pointers swap, so current names what runs
# and a later deploy keeps the release rolled back from as previous rather
# than the last one that passed.
rollback() {
  local pointer=current id current=
  [[ ${1:-} != --previous ]] || pointer=previous
  id=$(promoted "$pointer")
  [[ -n $id ]] || die "$task: there is no $pointer release on the host"
  [[ $pointer == current ]] || current=$(promoted current)
  quiet remote "$(up_cmd "$id")" || die "$task: up from release $id failed; see $diagnostics_log"
  health_gate o11y || die "$task: release $id did not pass the health gate"
  if [[ $pointer == previous ]]; then
    swap_pending="$id $current"
    quiet remote "$(swap_cmd "$id" "$current")" || die "$task: release $id is running, but the pointer swap failed"
    swap_pending=
    ok "$task: release $id is running, passed the health gate and is current again; previous names release ${current:-none}"
    return
  fi
  ok "$task: release $id is running and passed the health gate"
}

down() {
  local id
  id=$(active)
  quiet remote "$(compose_cmd o11y "$dir/releases/$id" .env.validate compose.yaml) down" ||
    die "$task: down failed; see $diagnostics_log"
  ok "$task: the containers of release $id are removed. Data, secrets, config and images are untouched"
}

status() {
  local id listing rustfs service
  id=$(promoted current)
  echo "current release: ${id:-none}"
  listing=$(containers o11y) || die "$task: the host could not be asked for its containers"
  if [[ -z $listing ]]; then
    echo "no containers"
  else
    # Only the release id of the compose file path is shown.
    sed -E 's#^([^ ]+) [^ ]+ [^ ]*/releases/([^/ ]+)/[^ ]* #\1 (release \2) #' <<<"$listing"
    rustfs=$(awk '$1 == "rustfs" { print $2; exit }' <<<"$listing")
    for service in "${services[@]}"; do
      if [[ -n $rustfs ]] && is_ready "$rustfs" "$(ready_url "$service")"; then
        echo "$service ready"
      else
        echo "$service not ready"
      fi
    done
    # With no running container, a bare `docker stats` would list every
    # other container on the host.
    remote "ids=\$($docker ps -q $(of_project o11y)) || exit 1; if [ -n \"\$ids\" ]; then $docker stats --no-stream --format $(q 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}') \$ids; else echo 'no running containers to measure'; fi" ||
      echo "container statistics are unavailable"
  fi
  if disk_space; then
    echo "disk under O11Y_REMOTE_DIR: $(disk_summary)"
  else
    echo "free space under O11Y_REMOTE_DIR is unavailable"
  fi
  shown "$tailscale serve status" || echo "serve status is unavailable"
}

logs() {
  local id service=${1:-}
  case $service in
  '' | rustfs | s3-buckets | loki | tempo | mimir | alloy | grafana) ;;
  *) die "$task: unknown service" ;;
  esac
  id=$(active)
  remote "$(compose_cmd o11y "$dir/releases/$id" .env.validate compose.yaml) logs --no-color --tail=200 $service"
}

grafana_password() {
  remote "$docker exec \$($docker ps -q $(of_project o11y) --filter label=com.docker.compose.service=grafana) cat /run/o11y/grafana_admin_password"
}

# serve <subcommand and arguments>: one change to the serve configuration,
# never through sudo. Changing it needs root or an operator user, and the
# host grants root for nothing but docker.
serve() {
  local out
  out=$(remote "$tailscale serve $*" 2>&1) && return
  echo "$out" >>"$diagnostics_log"
  grep -qiE 'access denied|permission denied|operator' <<<"$out" || return 1
  die "$task: the SSH user may not change the serve configuration. The owner has to set an operator user on the host once, as root (tailscale set --operator=<user>), then run this task again"
}

serve_apply() {
  local mapping
  for mapping in "svc:grafana --https=443 http://127.0.0.1:$grafana_port" \
    "svc:otlp --https=4318 http://127.0.0.1:$http_port" "svc:otlp --https=4317 http://127.0.0.1:$grpc_port"; do
    serve "--service=$mapping" || die "$task: tailscale refused a mapping; its message is in $diagnostics_log"
  done
  shown "$tailscale serve status"
}

# Drains before clearing so open connections finish, and only ever clears
# the two services: `serve reset` would drop everything else the host serves.
serve_clear() {
  local service failed=0
  for service in svc:grafana svc:otlp; do
    serve "drain $service" || echo "note $task: $service could not be drained; see $diagnostics_log"
  done
  for service in svc:grafana svc:otlp; do
    serve "clear $service" || failed=1
  done
  [[ $failed -eq 0 ]] || die "$task: a service could not be cleared; see $diagnostics_log"
  shown "$tailscale serve status"
}

# resolve <name>: its IPv4 address as this machine resolves it. A container
# does not use the host's resolver, which is the one that knows the tailnet.
resolve() {
  if command -v getent >/dev/null; then
    getent ahostsv4 "$1" | awk 'NR == 1 { print $1 }'
  else
    dscacheutil -q host -a name "$1" | awk '/^ip_address:/ { print $2; exit }'
  fi
}

smoke_remote() {
  local name=otlp.$O11Y_TAILNET_DOMAIN address
  export O11Y_CHECK_CURL=curl O11Y_CHECK_OTLP_URL=https://$name:4318
  export O11Y_CHECK_GRAFANA_URL=https://grafana.$O11Y_TAILNET_DOMAIN
  case ${1:-} in
  '') tools/receipt.sh 9>&- ;;
  --grpc)
    load_model
    address=$(resolve "$name") || true
    [[ $address =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "$task: the OTLP service name does not resolve on this machine"
    tools/receipt.sh --grpc -- docker run --rm --add-host "$name:$address" "$(image_of telemetrygen)" \
      traces --otlp-endpoint "$name:4317" 9>&-
    ;;
  *) die "$task: unknown argument" ;;
  esac
}

# The gate project's layout after init, as smoke.sh asserts it locally:
# names, owners, modes and sizes only.
gate_layout="alloy 0:0 750
grafana 472:472 750
loki 10001:10001 750
mimir 0:0 750
rustfs 10001:10001 750
secrets 0:0 755
tempo 10001:10001 750
secrets/grafana_admin_password 472:472 400 33
secrets/rustfs.access_key 10001:10001 400 21
secrets/rustfs.secret_key 10001:10001 400 41
secrets/s3.env 0:0 600 102"

# Each image's own binary, run with no shell, is what shows that it starts
# on the host's kernel.
gate_binaries="loki /usr/bin/loki -version
tempo /tempo -version
mimir /bin/mimir -version
alloy /bin/alloy --version
grafana grafana --version
rustfs rustfs --version
telemetrygen /telemetrygen --help
s3probe /usr/local/bin/aws --version"

gate_test() {
  local id out release data=$dir/gate/data main tools facts service binary flag rustfs status code
  disk_gate
  id=$(new_release_id)
  out=tmp/deploy/gate-$id
  release=$dir/gate/releases/$id
  render_release "$out" o11y-gate "$data" http://127.0.0.1:13000/ 13000 14317 14318
  load_model "$out/release"
  quiet remote "$(prepare_cmd "$dir/gate/releases")" || die "$task: the gate directories could not be prepared on the host"
  upload_configs "$out"
  upload "$out/release" "$dir/gate/releases" "$id"
  main=$(compose_cmd o11y-gate "$release" .env compose.yaml)
  tools=$(compose_cmd o11y-gate "$release" .env compose.yaml compose.tools.yaml)

  # From here on the project is stopped on the way out, pass or fail. The
  # first stop clears what a killed run left behind.
  gate_release=$release
  quiet remote "$(gate_down_cmd "$release")" ||
    die "$task: a leftover o11y-gate project could not be stopped"
  # Exit 1 means the data exists; anything else, such as SSH's 255, means
  # the host could not be asked.
  status=0
  remote "test ! -e $data" || status=$?
  case $status in
  0) ;;
  1) die "$task: data of an earlier rehearsal exists, and a rehearsal of a first deploy starts from nothing. Run gate-clean first" ;;
  *) die "$task: the host could not be asked whether gate data exists" ;;
  esac

  facts=$(remote "uname -r; $(fs_type_cmd)" | redact | tr '\n' ' ') || facts=unknown
  echo "note $task: kernel and filesystem under O11Y_REMOTE_DIR: $facts"

  while read -r service binary flag; do
    quiet remote "$docker run --rm --network none --entrypoint $binary $(image_of "$service") $flag" ||
      die "$task: the $service image's own binary does not run on this host; see $diagnostics_log"
  done <<<"$gate_binaries"
  ok "$task: the binary of each of the eight images runs on the host's kernel"

  # Made only now, after the check above and right before the probe's init
  # first mounts it. See data_cmd.
  quiet remote "mkdir -m 755 $data" || die "$task: the gate data directory could not be created"
  if ! tools/rustfs-probe.sh --release "$release" --project o11y-gate -- bash tools/nas.sh remote-compose </dev/null 9>&-; then
    if remote "$(compose_cmd o11y-gate "$release" .env.validate compose.yaml) logs --no-color --no-log-prefix rustfs" 2>&1 |
      grep -qi 'unsupported filesystem'; then
      die "$task: RustFS refused to start on the filesystem under the gate data directory ($facts). This is its unsupported-filesystem guard, not a fault in the probe"
    fi
    die "$task: the RustFS probe failed"
  fi

  quiet remote "$main up -d" || die "$task: up failed; see $diagnostics_log"
  health_gate o11y-gate --state-file "$out/receipt" --grpc -- bash tools/nas.sh remote-compose -p o11y-gate \
    --env-file "$release/.env" -f "$release/compose.yaml" -f "$release/compose.tools.yaml" \
    run --rm -T telemetrygen traces --otlp-endpoint alloy:4317 --otlp-insecure ||
    die "$task: the stack did not boot and pass the receipt check"
  ok "$task: the stack boots, every service is ready, and the receipt check passes over OTLP/HTTP and gRPC"

  # The five self-scrapes, as smoke checks them: each job up, with the
  # cluster and namespace labels.
  rustfs=$(container_of o11y-gate rustfs)
  self_scraped() {
    local body
    body=$(in_network "$rustfs" -s -m 10 "http://grafana:3000/api/datasources/proxy/uid/mimir/api/v1/query?query=up%3D%3D1" </dev/null) || return 1
    [[ $(jq -c '[.data.result[].metric | select(.namespace == "o11y" and (.cluster // "") != "") | .job] | sort' <<<"$body" 2>/dev/null) == '["o11y/alloy","o11y/grafana","o11y/loki","o11y/mimir","o11y/tempo"]' ]]
  }
  poll "$timeout" self_scraped || die "$task: up is not 1 for exactly the five o11y/* jobs, each with the cluster and namespace labels"
  ok "$task: up is 1 for exactly the five o11y/* jobs, each labelled"

  [[ $(remote "$(util_cmd "$data" "cd /d && stat -c '%n %u:%g %a' * && stat -c '%n %u:%g %a %s' secrets/*")") == "$gate_layout" ]] ||
    die "$task: owners, modes or sizes under the gate data directory differ from the layout"
  ok "$task: the data directories and the four secret files have the expected owners, modes and sizes"

  # Read back from the object store, as smoke.sh does: Loki, with its
  # container removed and its local directory emptied, can only answer from
  # its bucket. Gate project only; a deployment's local state is never
  # emptied. Tempo and Mimir are shown only to hold objects and to keep the
  # receipt across a restart: Tempo's query frontend sets the lookup mode
  # itself on each request it splits off (modules/frontend/traceid_sharder.go
  # at v3.1.0), so a lookup limited to stored blocks proves nothing and
  # emptying its local state could race the upload, and
  # Mimir answers a query this fresh from its ingester.
  has_objects() {
    local count
    count=$(remote "$tools run --rm -T s3probe count $1" 2>>"$diagnostics_log" | tr -d '\r') || return 1
    [[ $count =~ ^[0-9]+$ && $count -ge 1 ]]
  }
  code=$(http_status "$rustfs" -X POST http://loki:3100/flush) && [[ $code == 204 ]] || die "$task: Loki's flush endpoint failed"
  code=$(http_status "$rustfs" -X POST http://mimir:8080/ingester/flush) && [[ $code == 204 ]] || die "$task: Mimir's flush endpoint failed"
  poll 120 has_objects loki || die "$task: the loki bucket is empty after a flush"
  poll 120 has_objects mimir-blocks || die "$task: the mimir-blocks bucket is empty after a flush"
  # Tempo cuts a block every 30 seconds by default and has no flush endpoint.
  poll 240 has_objects tempo || die "$task: the tempo bucket is still empty"
  quiet remote "$main rm -sf loki" || die "$task: loki could not be removed"
  quiet remote "$(util_cmd "$data/loki" 'rm -rf /d/* /d/.[!.]*')" || die "$task: the local state of loki could not be emptied"
  quiet remote "$main up -d loki" || die "$task: loki could not be created again"
  all_ready o11y-gate >>"$diagnostics_log" || die "$task: the stack did not come back after loki was recreated"
  receipt o11y-gate --recheck "$out/receipt" || die "$task: loki lost the receipt once its local state was emptied"
  for service in tempo mimir; do
    quiet remote "$main restart $service" || die "$task: $service did not restart"
    all_ready o11y-gate >>"$diagnostics_log" || die "$task: the stack did not come back after $service restarted"
    receipt o11y-gate --recheck "$out/receipt" || die "$task: the receipt is gone after restarting $service"
  done
  ok "$task: the three buckets hold objects, Loki returns the receipt from its bucket alone, Tempo and Mimir keep it across a restart"

  # What a daemon or host restart does: everything stopped, then started at
  # once with dependents first, with no `up` to order it.
  quiet remote "ids=\$(for s in grafana alloy tempo mimir loki rustfs; do $docker ps -q $(of_project o11y-gate) --filter label=com.docker.compose.service=\$s; done) && $docker stop \$ids && $docker start \$ids" ||
    die "$task: the containers could not be stopped and started"
  health_gate o11y-gate || die "$task: the stack did not recover from a restart without up"
  ok "$task: the stack recovers from a stop and start of every container and passes the receipt check again"
  quiet remote "$(gate_down_cmd "$release")" || die "$task: the rehearsal passed, but the o11y-gate project could not be stopped"
  gate_release=
  ok "$task: the rehearsal passed and the o11y-gate project is stopped. Its data stays until gate-clean"
}

gate_clean() {
  local existing status=0
  existing=$(remote "$docker ps -aq $(of_project o11y-gate)") ||
    die "$task: the host could not be asked for o11y-gate containers; nothing was removed"
  [[ -z $existing ]] || die "$task: an o11y-gate container still exists; nothing was removed"
  remote "test -d $dir/gate" || status=$?
  case $status in
  0) ;;
  1) die "$task: there is no gate directory on the host; nothing to remove" ;;
  *) die "$task: the host could not be asked for the gate directory; nothing was removed" ;;
  esac
  load_model
  quiet remote "$(util_cmd "$dir/gate" 'find /d -mindepth 1 -maxdepth 1 -exec rm -rf {} +')" ||
    die "$task: the gate directory could not be emptied; see $diagnostics_log"
  quiet remote "rmdir $dir/gate" || die "$task: the emptied gate directory could not be removed; see $diagnostics_log"
  ok "$task: the gate directory is removed, and nothing else"
}

# --- dispatch -------------------------------------------------------------

case $task in
in-network-curl)
  # What receipt.sh is given as its curl: receipt.sh <-> the rustfs container.
  need host docker
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "$task: not a container name"
  in_network "$@"
  exit
  ;;
remote-compose)
  # What rustfs-probe.sh and the gRPC receipt are given as their Compose
  # command. Gate project only.
  need host compose
  [[ ${1:-} == -p && ${2:-} == o11y-gate ]] || die "$task: only the o11y-gate project"
  remote_stdin "sudo -n $O11Y_REMOTE_COMPOSE $(q "$@")"
  exit
  ;;
rollback)
  [[ $# -eq 0 || ($# -eq 1 && $1 == --previous) ]] || die "$task: the only argument it takes is --previous"
  confirm
  ;;
stage | gate-test | gate-clean | deploy | down | serve-apply | serve-clear) confirm ;;
preflight | deploy-plan | status | logs | serve-status | smoke-remote | grafana-password) ;;
*)
  echo "usage: nas.sh <task> [arguments]; the tasks are listed at the top of this file" >&2
  exit 2
  ;;
esac

# filtered <task> [arguments]: runs the task as a child whose stdout and
# stderr are appended to the task log, a regular file, which no descriptor
# a leftover process holds can block and which no signal can lose. The
# child runs in the foreground, so a signal reaches it, its own cleanup
# decides what stays on the host, and its status, 128 and up for a signal,
# is what this shell exits with. Once it has ended, this shell shows the
# operator a redacted copy of the task log from where this run began. A
# copy that can't be shown fails a run that otherwise passed.
filtered() {
  local start status
  start=$(($(wc -c <"$log") + 1))
  echo "running $task; the raw output is in $log, the remote diagnostics in $diagnostics_log"
  # This shell only waits; the child handles a signal.
  trap : INT TERM
  set +e
  O11Y_NAS_FILTERED=1 bash "$root/tools/nas.sh" "$task" "$@" >>"$log" 2>&1
  status=$?
  if ! tail -c "+$start" "$log" | redact; then
    echo "FAIL $task: the output could not be shown; the raw output is in $log" >&2
    ((status != 0)) || status=1
  fi
  exit "$status"
}

# What a task prints, SSH errors included, reaches the operator only
# through redact. Two tasks print unfiltered: deploy-plan shows the owner
# the real values a deploy will use, which is what the owner approves, and
# grafana-password prints the one password by design.
case $task in
deploy-plan | grafana-password) ;;
*)
  log=tmp/deploy/$task.log
  diagnostics_log=tmp/deploy/$task.raw.log
  if [[ -z ${O11Y_NAS_FILTERED:-} ]]; then
    mkdir -p tmp/deploy
    : >>"$log"
    : >>"$diagnostics_log"
    filtered "$@"
  fi
  ;;
esac

case $task in
preflight) need host dir docker compose tailscale ports reserve ;;
deploy-plan) need dir docker compose domain ports ;;
stage) need host dir docker compose domain ports ;;
deploy) need host dir docker compose domain ports reserve ;;
gate-test) need host dir docker compose reserve ;;
gate-clean | rollback | down | logs) need host dir docker compose ;;
status) need host dir docker tailscale ;;
serve-apply) need host tailscale ports ;;
serve-status | serve-clear) need host tailscale ;;
smoke-remote) need domain ;;
grafana-password) need host docker ;;
esac

if [[ $task == deploy-plan ]]; then
  mkdir -p tmp/deploy
  log=tmp/deploy/$task.log
  diagnostics_log=$log
  : >"$log"
fi
exec 9>&2
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Everything that changes the host's directory or a project holds the lock,
# and takes it before reading any state there.
case $task in
stage | gate-test | gate-clean | deploy | rollback | down) lock ;;
esac

case $task in
preflight) preflight ;;
deploy-plan) deploy_plan ;;
stage) stage ;;
gate-test) gate_test ;;
gate-clean) gate_clean ;;
deploy) deploy ;;
rollback) rollback "$@" ;;
down) down ;;
status) status ;;
logs) logs "$@" ;;
serve-apply) serve_apply ;;
serve-status) shown "$tailscale serve status" ;;
serve-clear) serve_clear ;;
smoke-remote) smoke_remote "$@" ;;
grafana-password) grafana_password ;;
esac
