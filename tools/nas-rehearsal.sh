#!/usr/bin/env bash
# Local rehearsal of the deploy host tasks: tools/nas.sh, unchanged, against
# this machine's Docker engine. A stub ssh runs each remote command here
# under sh, a stub sudo allows only `sudo -n` on the docker and
# docker-compose paths, and tailscale is a stub. The run works on a copy of
# the tree, so a git stub names the commit for the release id. Every O11Y_* value is a
# placeholder, and a scratch directory stands in for O11Y_REMOTE_DIR.
#
#   tools/nas-rehearsal.sh
#
# Runs preflight, stage, a first deploy through the health gate and the
# receipt check, status, logs, a second deploy, rollback --previous and
# down, then gate-test and gate-clean. It takes several minutes and needs
# network access for the images and the Compose binary.
#
# The run happens in a Linux container that reaches the engine through its
# socket, as root, the way the deploy host runs Compose under sudo. The
# scratch directory lives on the engine's own filesystem, under the same
# path inside and outside, because Compose hands bind mount paths to the
# engine and RustFS refuses a shared host folder. It uses the projects o11y
# and o11y-gate, so it refuses to start while either exists, and it removes
# everything it created on the way out.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck source=tools/lib.sh
source tools/lib.sh

scratch=/var/lib/o11y-nas-rehearsal
cli_image=docker:29.0.1-cli@sha256:f7d048590d889e00868920f658e807ecbc4ef662d51c9af67eb5534a447d58d6
compose_version=2.20.1
projects=(o11y o11y-gate)

# leftovers: what the two projects still have on the engine.
leftovers() {
  local project
  for project in "${projects[@]}"; do
    docker ps -aq --filter "label=com.docker.compose.project=$project"
    docker network ls -q --filter "label=com.docker.compose.project=$project"
    docker volume ls -q --filter "label=com.docker.compose.project=$project"
  done
}

if [[ ${1:-} != --inside ]]; then
  [[ -z $(leftovers) ]] ||
    die "a container, network or volume of project o11y or o11y-gate exists on this engine; the rehearsal uses those names and leaves them alone"
  util_image=$(sed -n 's/^ *image: \(rustfs\/rustfs:.*\)$/\1/p' compose.yaml | head -n 1)
  remove_scratch() {
    docker run --rm --network none --user 0:0 --entrypoint /bin/sh -v /var/lib:/l "$util_image" \
      -c 'rm -rf /l/o11y-nas-rehearsal' || echo "FAIL the scratch directory $scratch could not be removed" >&2
  }
  remove_scratch
  trap remove_scratch EXIT
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$scratch:$scratch" -v "$root:/src:ro" \
    -e "REHEARSAL_COMMIT=$(git rev-parse --short HEAD)" "$cli_image" \
    sh -c 'apk add --no-cache bash coreutils curl findutils jq tar >/dev/null && exec bash /src/tools/nas-rehearsal.sh --inside'
  [[ -z $(leftovers) ]] || die "the rehearsal left a container, network or volume behind"
  ok "rehearsal: nothing of projects o11y and o11y-gate is left on the engine"
  exit
fi

# --- inside the container -------------------------------------------------

work=/work
remote=$scratch/o11y
stubs=$scratch/stubs
compose=$scratch/docker-compose-$compose_version
mkdir -p "$stubs" "$work"

arch=$(uname -m)
url=https://github.com/docker/compose/releases/download/v$compose_version/docker-compose-linux-$arch
curl -fsSL -o "$compose" "$url"
expected=$(curl -fsSL "$url.sha256" | cut -d' ' -f1)
[[ $(sha256sum "$compose" | cut -d' ' -f1) == "$expected" ]] || die "the Compose $compose_version download does not match its checksum"
chmod +x "$compose"

stub() {
  {
    echo '#!/bin/sh'
    cat
  } >"$stubs/$1"
  chmod +x "$stubs/$1"
}
# The last argument is the remote command; stdin passes through.
stub ssh <<'STUB'
for command; do :; done
exec sh -c "$command"
STUB
stub sudo <<'STUB'
[ "$1" = -n ] || exit 97
shift
case $1 in
"$O11Y_REMOTE_DOCKER" | "$O11Y_REMOTE_COMPOSE") exec "$@" ;;
esac
echo "sudo: refused $1" >&2
exit 97
STUB
# shellcheck disable=SC2016 # the stub expands it when it runs
stub git <<<'echo "$REHEARSAL_COMMIT"'
stub tailscale <<'STUB'
case "$*" in
version) echo 1.104.1 ;;
*) echo "No serve config" ;;
esac
STUB

tar -C /src --exclude ./.git --exclude ./tmp --exclude ./mise.local.toml -cf - . | tar -C "$work" -xf -
cd "$work"

export PATH=$stubs:$PATH O11Y_COMPOSE=$compose
export O11Y_SSH_HOST=nas.example.invalid O11Y_REMOTE_DIR=$remote O11Y_TAILNET_DOMAIN=example.ts.net
export O11Y_REMOTE_DOCKER=/usr/local/bin/docker O11Y_REMOTE_COMPOSE=$compose O11Y_REMOTE_TAILSCALE=$stubs/tailscale
# Ports of their own, so the rehearsal does not collide with a local smoke
# run; the gate project keeps its fixed 13000, 14317 and 14318.
export O11Y_GRAFANA_PORT=23000 O11Y_OTLP_GRPC_PORT=24317 O11Y_OTLP_HTTP_PORT=24318
# The pinned Compose speaks an API older than current engines accept. The
# deploy host's engine needs no such pin, and nas.sh never sets it.
pin_docker_api

release_files() {
  local release
  release=$(find "$remote/releases" "$remote/gate/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.incoming-*' 2>/dev/null | head -n 1)
  [[ -n $release ]] && echo "$release"
}

cleanup() {
  local status=$? release project
  trap - EXIT
  if release=$(release_files); then
    for project in "${projects[@]}"; do
      "$compose" -p "$project" --env-file "$release/.env.validate" -f "$release/compose.yaml" down -v >/dev/null 2>&1 || true
    done
  fi
  rm -rf "${scratch:?}"/*
  exit "$status"
}
trap cleanup EXIT

# step <description> <task> [arguments]: runs one task, confirmed when it
# needs to be, and shows what it printed.
step() {
  local what=$1 output
  shift
  echo "--- $*"
  if ! output=$(O11Y_CONFIRM=$1 bash tools/nas.sh "$@" 2>&1); then
    echo "$output"
    [[ ! -f tmp/deploy/$1.log ]] || tail -n 40 "tmp/deploy/$1.log"
    die "rehearsal: $what"
  fi
  echo "$output"
}

pointer() {
  readlink "$remote/$1"
}

step "preflight failed" preflight
step "stage failed" stage
first=releases/$(cat tmp/deploy/staged)
step "the first deploy failed" deploy
[[ $(pointer current) == "$first" && ! -e $remote/previous ]] || die "rehearsal: the first deploy did not make its release current"
ok "rehearsal: first deploy is current"

status=$(step "status failed" status)
[[ $(grep -c ' ready$' <<<"$status") -eq 6 ]] || die "rehearsal: status does not report all six services ready"
grep -q "(release ${first#releases/}) Up" <<<"$status" || die "rehearsal: status does not name the running release"
ok "rehearsal: status reports six ready services and the running release"
[[ -n $(bash tools/nas.sh logs loki) ]] || die "rehearsal: logs printed nothing"
ok "rehearsal: logs prints Loki's log"

rm tmp/deploy/staged
sleep 1
step "the second deploy failed" deploy
second=releases/$(cat tmp/deploy/staged)
[[ $second != "$first" && $(pointer current) == "$second" && $(pointer previous) == "$first" ]] ||
  die "rehearsal: the second deploy did not move previous and current"
ok "rehearsal: second deploy is current, the first is previous"

step "rollback --previous failed" rollback --previous
grep -q "(release ${first#releases/}) Up" <<<"$(bash tools/nas.sh status)" ||
  die "rehearsal: after rollback --previous the containers do not run the first release"
ok "rehearsal: rollback --previous runs the first release again"

step "down failed" down
[[ -z $(docker ps -aq --filter label=com.docker.compose.project=o11y) ]] || die "rehearsal: down left containers"
[[ -d $remote/data/secrets && -L $remote/current ]] || die "rehearsal: down removed more than the containers"
ok "rehearsal: down removed the containers and kept data, secrets and releases"

step "gate-test failed" gate-test
[[ -z $(docker ps -aq --filter label=com.docker.compose.project=o11y-gate) ]] || die "rehearsal: gate-test left containers"
step "gate-clean failed" gate-clean
[[ ! -e $remote/gate && -d $remote/data ]] || die "rehearsal: gate-clean removed the wrong thing"
ok "rehearsal: gate-test passed and stopped its project, gate-clean removed only the gate directory"
