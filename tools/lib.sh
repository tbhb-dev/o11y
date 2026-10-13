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
  [[ $(uname -s) == Linux ]]
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
# only: a deployment never copies this file anywhere.
publish_s3_env() {
  host_is_linux && return
  (
    umask 077
    docker run --rm --user 0:0 --network none --entrypoint /bin/cat \
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
  ! grep -qiE 'rustfsadmin|is not set|default root credentials|ENOSYS|Function not implemented|Unsupported filesystem' <<<"$log"
}

# sentinel_absent <sentinel> <name=path>...: fails when a file or directory
# holds the sentinel, naming each place on stderr and never the value.
sentinel_absent() {
  local sentinel=$1 place found=0
  shift
  for place in "$@"; do
    if grep -rqF -- "$sentinel" "${place#*=}"; then
      echo "FAIL a sentinel secret is in ${place%%=*}" >&2
      found=1
    fi
  done
  return "$found"
}
