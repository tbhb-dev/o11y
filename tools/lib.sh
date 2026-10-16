#!/usr/bin/env bash
# Shared by the scripts that drive Docker: validate.sh, rustfs-probe.sh and
# smoke.sh. Source it; it changes nothing on its own beyond the environment.

# The Compose binary mise pins to the version the deploy host runs. Calling it
# by this name, not `docker compose`, is what keeps every local test on that
# version.
O11Y_COMPOSE=${O11Y_COMPOSE:-docker-cli-plugin-docker-compose}

# That Compose version speaks Docker API 1.43 at most, and engines from 29 on
# refuse anything below 1.44. Naming the engine's minimum makes the old
# client usable against a new engine; an older engine needs nothing.
pin_docker_api() {
  local min
  min=$(docker version --format '{{.Server.MinAPIVersion}}')
  # shellcheck disable=SC2312 # printf, sort and head over two words don't fail
  if [[ $(printf '%s\n' 1.44 "$min" | sort -V | head -n 1) == 1.44 ]]; then
    export DOCKER_API_VERSION=$min
  fi
}

# isolate_environment: the tests set every O11Y_* value themselves. Compose
# gives a shell variable precedence over its --env-file, so an inherited
# value, a deployment's for example, would silently replace a placeholder,
# and an inherited COMPOSE_* setting would change which files and profiles
# load. Drop them all before setting anything.
isolate_environment() {
  local name
  for name in $(compgen -v O11Y_) $(compgen -v COMPOSE_); do
    case $name in
    O11Y_COMPOSE | O11Y_SMOKE_LEAK) ;;
    *) unset "$name" ;;
    esac
  done
}

host_is_linux() {
  # shellcheck disable=SC2312 # uname -s doesn't fail
  [[ $(uname -s) == Linux ]]
}

# local_engine_only [expected engine]: the local test tasks drive this
# machine's own engine, Docker Desktop's VM on macOS or the local daemon on
# Linux, and nothing else. The threat is misdirection: an inherited
# DOCKER_HOST or DOCKER_CONTEXT, or a current context left pointing at the
# deploy host's engine. A socket someone forwards on purpose to another
# engine is out of scope. So both variables are dropped, the current
# context must be default or desktop-linux, and its endpoint must be one of
# the local daemon's own socket paths and an actual socket here. Last, as a
# second layer, the engine must name itself as this machine's. Inside the
# rehearsal's container, where the engine's socket is mounted and the
# container's own name differs, the caller passes the name and system the
# outside run already verified, and only that socket path is accepted.
# Anything else stops the task before it sends the engine any work.
# Docker's own error output is discarded, because it can hold the context
# name and the socket path, and messages never print either.
engine_identity=
local_engine_only() {
  local expected=${1:-} context endpoint socket info name os here allowed=()
  unset DOCKER_HOST DOCKER_CONTEXT
  context=$(docker context show 2>/dev/null) || die "local engine: the Docker context could not be read"
  case $context in
  default | desktop-linux) ;;
  *) die "local engine: the current Docker context is neither default nor desktop-linux, so this task refuses to run" ;;
  esac
  endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' "$context" 2>/dev/null) ||
    die "local engine: the Docker context could not be inspected"
  if [[ -n $expected ]]; then
    allowed=(/var/run/docker.sock)
  elif host_is_linux; then
    allowed=(/var/run/docker.sock /run/docker.sock)
  else
    allowed=("$HOME/.docker/run/docker.sock" /var/run/docker.sock)
  fi
  socket=${endpoint#unix://}
  [[ $endpoint == unix://* && " ${allowed[*]} " == *" $socket "* && -S $socket ]] ||
    die "local engine: the Docker context does not use this machine's own daemon socket"
  info=$(docker info --format '{{.Name}}|{{.OperatingSystem}}' 2>/dev/null) || die "local engine: the engine did not answer"
  name=${info%%|*}
  os=${info#*|}
  if [[ -n $expected ]]; then
    [[ $info == "$expected" ]] || die "local engine: the engine is not the one the outside run verified"
  elif host_is_linux; then
    here=$(uname -n) || die "local engine: this machine's name could not be read"
    [[ $name == "$here" ]] || die "local engine: the engine is not this machine's own"
  else
    [[ $name == docker-desktop && $os == "Docker Desktop" ]] || die "local engine: the engine is not this machine's Docker Desktop"
  fi
  # shellcheck disable=SC2034 # the scripts that source this file read it
  engine_identity=$info
}

# test_data_dir <name>: prints the data directory of a local test project.
# On Linux it sits under tmp/. Docker Desktop shares host directories with
# its Linux VM through a FUSE filesystem, which RustFS's startup guard
# rejects and which does not keep file owners, so there the directory lives
# inside the VM, where containers see an ordinary Linux filesystem and every
# check runs unchanged. The caller sets root to the repository root.
test_data_dir() {
  if host_is_linux; then
    echo "${root:?}/tmp/$1/data"
  else
    echo "/var/lib/o11y-test/$1"
  fi
}

# publish_s3_env <image> <file>: Compose runs on the host and reads s3.env
# when it loads the model. With the data directory inside a VM the host
# cannot see it, so copy it out and point Compose at the copy. Test projects
# only: a deployment never copies this file anywhere. The key travels on the
# container's stdout, which Docker's log driver would record, so logging is
# off for this container.
publish_s3_env() {
  host_is_linux && return
  (
    umask 077
    docker run --rm --log-driver none --user 0:0 --network none --entrypoint /bin/cat \
      -v "$O11Y_DATA_DIR/secrets:/s:ro" "$1" /s/s3.env >"$2"
  ) || return 1
  export O11Y_S3_ENV_FILE=$2
}

# remove_test_data <image>: root in a utility container removes what the
# stack's users wrote.
remove_test_data() {
  docker run --rm --user 0:0 --network none --entrypoint /bin/sh \
    -v "$(dirname "$O11Y_DATA_DIR"):/d" "$1" -c "rm -rf '/d/$(basename "$O11Y_DATA_DIR")'"
}

ok() {
  echo "ok $*"
}

die() {
  echo "FAIL $*" >&2
  exit 1
}

# poll <seconds> <command...>: retries the command until it succeeds.
poll() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

# Reads a RustFS start log on stdin. RustFS starts on a well-known default
# login when its key is missing and only warns about it, so the log is the
# place to catch that. 1.0.1 logs no resource-detection line, so the positive
# marker is the startup line that also reports the console as off.
rustfs_log_ok() {
  local log
  log=$(cat)
  grep -q '"console_enabled":false' <<<"$log" || return 1
  lacks -iE 'rustfsadmin|is not set|default root credentials|ENOSYS|Function not implemented|Unsupported filesystem' <<<"$log"
}

# lacks <grep arguments...>: 0 when no line of stdin matches, 1 when one
# does, 2 when grep itself fails. It reads all of its input, so a command
# feeding it never gets SIGPIPE. `! grep -q` reads a failed grep as no
# match, and stops reading at the first match, which under pipefail turns
# the upstream SIGPIPE into a pass.
lacks() {
  local status=0
  grep "$@" >/dev/null || status=$?
  case $status in
  0) return 1 ;;
  1) return 0 ;;
  *) return 2 ;;
  esac
}

# json_after_start: reads a RustFS log on stdin, all of it. 0 when every
# line after its first "Starting: " entrypoint line is a JSON log line, 3
# when one isn't, such as an exporter dump, 4 when there is no start line,
# and anything else when awk itself fails.
json_after_start() {
  awk '{ sub(/\r$/, "") } started && !/^\{/ { bad = 1 } /^Starting: / { started = 1 }
    END { exit bad ? 3 : (started ? 0 : 4) }'
}

# files_differ <a> <b>: 0 when the two files differ, 1 when they are the
# same, 2 when cmp can't compare them. `! cmp -s` reads a comparison
# error as a difference.
files_differ() {
  local status=0
  cmp -s "$1" "$2" || status=$?
  case $status in
  1) return 0 ;;
  0) return 1 ;;
  *) return 2 ;;
  esac
}

# expected_up_jobs <config.alloy>: the jobs a release's Up panels must show,
# one per line: every scrape job, plus o11y/rustfs from the release that
# added the self receiver on. Fails when the config can't be read or names
# no job, rather than printing a shorter list.
expected_up_jobs() {
  local jobs status=0
  jobs=$(grep -o '"job" = "[^"]*"' "$1") || return 1
  jobs=$(cut -d'"' -f4 <<<"$jobs") || return 1
  grep -q '^otelcol.receiver.otlp "self"' "$1" || status=$?
  case $status in
  0) jobs+=$'\no11y/rustfs' ;;
  1) ;;
  *) return 1 ;;
  esac
  printf '%s\n' "$jobs"
}

# Reads Mimir's /metrics exposition on stdin and prints how many samples it
# has discarded as otlp_parse_error. Mimir exports no discard series until
# its first discard, so an absent series counts as zero, but only in text
# that is Mimir's exposition: anything else fails, so a failed scrape can't
# pass for no discards.
otlp_parse_discards() {
  awk '
    $0 == "# TYPE cortex_build_info gauge" { mimir = 1 }
    /^cortex_discarded_samples_total\{/ && /reason="otlp_parse_error"/ {
      if ($NF !~ /^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) bad = 1
      n += $NF
    }
    END {
      if (!mimir || bad) exit 1
      print n + 0
    }'
}

# expect_status <status> <curl arguments...>: the request must complete and
# answer with exactly that status. A transport failure or any other status
# fails, so an outage cannot pass for a refusal.
expect_status() {
  local want=$1 got
  shift
  # lint-curl: allow the status code is the answer, compared with the wanted one below
  got=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$@") || {
    echo "request failed before any status arrived" >&2
    return 1
  }
  [[ $got == "$want" ]] || {
    echo "expected status $want, got $got" >&2
    return 1
  }
}

# output_is <expected> <command...>: the command succeeds and prints exactly
# the expected text. Comparing the output alone passes a command that
# printed the right answer and then failed, as a dropped connection or a
# timed-out curl can, and one that failed with nothing when nothing is the
# answer wanted.
output_is() {
  local want=$1 got
  shift
  got=$("$@") || return 1
  [[ $got == "$want" ]]
}

# sentinel_absent <sentinel> <name=path>...: fails when a file or directory
# holds the sentinel, naming each place on stderr and never the value. A
# place that could not show anything also fails, because a search that had
# nothing to look at is not a clean result: a missing or unreadable path, an
# empty file, or a directory without a single non-empty file.
sentinel_absent() {
  local sentinel=$1 place name path files status found=0
  shift
  for place in "$@"; do
    name=${place%%=*} path=${place#*=}
    if [[ -f $path && ! -s $path ]]; then
      echo "FAIL $name is empty, so it cannot be searched" >&2
      found=1
      continue
    fi
    if [[ -d $path ]]; then
      if ! files=$(find "$path" -type f -size +0 2>/dev/null); then
        echo "FAIL $name could not be searched" >&2
        found=1
        continue
      elif [[ -z $files ]]; then
        echo "FAIL $name holds no non-empty file, so it cannot be searched" >&2
        found=1
        continue
      fi
    fi
    status=0
    grep -rqF -- "$sentinel" "$path" 2>/dev/null || status=$?
    case $status in
    0)
      echo "FAIL a sentinel secret is in $name" >&2
      found=1
      ;;
    1) ;;
    *)
      echo "FAIL $name could not be searched" >&2
      found=1
      ;;
    esac
  done
  return "$found"
}
