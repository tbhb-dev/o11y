#!/usr/bin/env bash
# Local rehearsal of the deploy host tasks: tools/nas.sh, unchanged, against
# this machine's Docker engine. A stub ssh runs each remote command here
# under sh, a stub sudo allows only `sudo -n` on the docker and
# docker-compose paths, and tailscale is a stub. The run works on a copy of
# the tree, so a git stub names the commit for the release id. Every O11Y_* value is a
# placeholder, and a scratch directory stands in for O11Y_REMOTE_DIR.
#
#   tools/nas-rehearsal.sh [base]
#
# Runs preflight, stage, a first deploy of the base release through the
# health gate and the receipt check, status, logs, a second deploy of this
# tree, rollback --previous to the base and down, then gate-test and
# gate-clean. The base is a commit, origin/main unless named, exported with
# git archive; the base's tasks deploy it, this tree's do the rest. It takes several minutes and needs
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
  local_engine_only
  base=${1:-origin/main}
  base_commit=$(git rev-parse --short "$base^{commit}") || die "the base $base is not a commit"
  [[ -z $(leftovers) ]] ||
    die "a container, network or volume of project o11y or o11y-gate exists on this engine; the rehearsal uses those names and leaves them alone"
  util_image=$(sed -n 's/^ *image: \(rustfs\/rustfs:.*\)$/\1/p' compose.yaml | head -n 1)
  base_dir=$root/tmp/rehearsal-base
  remove_scratch() {
    rm -rf "$base_dir"
    docker run --rm --network none --user 0:0 --entrypoint /bin/sh -v /var/lib:/l "$util_image" \
      -c 'rm -rf /l/o11y-nas-rehearsal' || echo "FAIL the scratch directory $scratch could not be removed" >&2
  }
  remove_scratch
  trap remove_scratch EXIT
  mkdir -p "$base_dir"
  git archive "$base_commit" | tar -x -C "$base_dir"
  head_commit=$(git rev-parse --short HEAD)
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$scratch:$scratch" -v "$root:/src:ro" -v "$base_dir:/base:ro" \
    -e "REHEARSAL_COMMIT=$head_commit" -e "REHEARSAL_BASE_COMMIT=$base_commit" -e "REHEARSAL_ENGINE=$engine_identity" "$cli_image" \
    sh -c 'apk add --no-cache bash coreutils curl findutils jq tar >/dev/null && exec bash /src/tools/nas-rehearsal.sh --inside'
  [[ -z $(leftovers) ]] || die "the rehearsal left a container, network or volume behind"
  ok "rehearsal: nothing of projects o11y and o11y-gate is left on the engine"
  exit
fi

# --- inside the container -------------------------------------------------

# Only the outside run starts this half, in its container, and hands it the
# engine it verified. Run any other way, it stops before any engine call.
[[ -f /.dockerenv && -n ${REHEARSAL_ENGINE:-} ]] ||
  die "rehearsal: --inside runs only in the container the rehearsal starts"
local_engine_only "$REHEARSAL_ENGINE"

work=/work
base_work=/base-work
remote=$scratch/o11y
stubs=$scratch/stubs
compose=$scratch/docker-compose-$compose_version
mkdir -p "$stubs" "$work" "$base_work"

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
# The deploy host's dockerd refuses to create a missing bind mount source,
# where this engine creates it. So before a Compose run or up, every bind
# source of the model must already exist. The words before the subcommand
# are Compose's own options, none of which holds a space.
stub sudo <<'STUB'
[ "$1" = -n ] || exit 97
shift
case $1 in
"$O11Y_REMOTE_DOCKER") exec "$@" ;;
"$O11Y_REMOTE_COMPOSE")
  options=
  for word; do
    case $word in run | up) break ;; esac
    options="$options $word"
  done
  if [ "$word" = run ] || [ "$word" = up ]; then
    # shellcheck disable=SC2086 # the options split on spaces
    model=$($options config --format json) || exit 1
    sources=$(printf '%s' "$model" | jq -r '.services[].volumes[]? | select(.type == "bind") | .source') || exit 1
    for source in $sources; do
      [ -e "$source" ] || {
        echo "Bind mount failed: '$source' does not exist" >&2
        exit 1
      }
    done
  fi
  exec "$@"
  ;;
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
tar -C /base -cf - . | tar -C "$base_work" -xf -
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

# on_base <step arguments>: the step, run by the base tree's own tasks with
# the base's commit as the release id.
on_base() {
  (cd "$base_work" && REHEARSAL_COMMIT=$REHEARSAL_BASE_COMMIT step "$@") || exit 1
}

# up_panels <jq test>: every Up panel of the Stack health dashboard, as the
# running Grafana provisioned it, run as the instant query the panel makes.
# The test applies to the sorted job and value of every series they return.
up_panels() {
  local rustfs dashboard exprs expr query body results=()
  rustfs=$(docker ps -q --filter label=com.docker.compose.project=o11y --filter label=com.docker.compose.service=rustfs) || return 1
  [[ -n $rustfs ]] || return 1
  # Each request's output is kept only once the request has succeeded.
  dashboard=$(docker exec "$rustfs" curl -fsS -m 15 http://grafana:3000/api/dashboards/uid/o11y-stack-health) || return 1
  exprs=$(jq -er '.dashboard.panels[] | select(.title == "Up" or (.title | startswith("Up: "))) | .targets[] | select(.instant == true) | .expr' <<<"$dashboard") || return 1
  while IFS= read -r expr; do
    query=$(jq -rn --arg v "$expr" '$v | @uri') || return 1
    body=$(docker exec "$rustfs" curl -fsS -m 15 \
      "http://grafana:3000/api/datasources/proxy/uid/mimir/api/v1/query?query=$query") || return 1
    body=$(jq -ce 'select(.status == "success") | [.data.result[] | [.metric.job, .value[1]]]' <<<"$body") || return 1
    results+=("$body")
  done <<<"$exprs"
  ((${#results[@]} > 0)) || return 1
  printf '%s\n' "${results[@]}" | jq -se "add | sort | $1" >/dev/null
}

# seed: one up of 1, stamped now, under a job no release scrapes,
# o11y/rehearsal-seed, written through Alloy's OTLP receiver. Kept fresh
# while the panels are read, it fails an Up panel that keeps the freshness
# filter but loses its job selector.
seed() {
  local rustfs now
  now=$(date +%s) || return 1
  rustfs=$(docker ps -q --filter label=com.docker.compose.project=o11y --filter label=com.docker.compose.service=rustfs) || return 1
  [[ -n $rustfs ]] || return 1
  printf '%s' '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"rehearsal-seed"}},{"key":"service.namespace","value":{"stringValue":"o11y"}}]},"scopeMetrics":[{"metrics":[{"name":"up","gauge":{"dataPoints":[{"asDouble":1,"timeUnixNano":"'"$now"'000000000"}]}}]}]}]}' |
    docker exec -i "$rustfs" curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Content-Type: application/json' \
      --data-binary @- http://alloy:4318/v1/metrics | grep -qx 200
}

# seeded: the seed series is in Mimir and fresh, so the check above means
# something.
seeded() {
  local rustfs query body
  rustfs=$(docker ps -q --filter label=com.docker.compose.project=o11y --filter label=com.docker.compose.service=rustfs) || return 1
  query=$(jq -rn '"up{job=\"o11y/rehearsal-seed\"} and time() - timestamp(up{job=\"o11y/rehearsal-seed\"}) < 90" | @uri') || return 1
  [[ -n $rustfs ]] || return 1
  body=$(docker exec "$rustfs" curl -fsS -m 15 "http://grafana:3000/api/datasources/proxy/uid/mimir/api/v1/query?query=$query") || return 1
  jq -e '.data.result | length == 1' <<<"$body" >/dev/null
}

seed_and_read() {
  seed && seeded && up_panels "$1"
}

on_base "preflight failed" preflight
on_base "stage failed" stage
first=releases/$(cat "$base_work/tmp/deploy/staged")
on_base "the first deploy failed" deploy
current=$(pointer current) || die "rehearsal: the current pointer could not be read"
[[ $current == "$first" && ! -e $remote/previous ]] || die "rehearsal: the first deploy did not make the base release current"
ok "rehearsal: the first deploy, of the base, is current"

status=$(step "status failed" status)
[[ $(grep -c ' ready$' <<<"$status") -eq 6 ]] || die "rehearsal: status does not report all six services ready"
grep -q "(release ${first#releases/}) Up" <<<"$status" || die "rehearsal: status does not name the running release"
ok "rehearsal: status reports six ready services and the running release"
[[ -n $(bash tools/nas.sh logs loki) ]] || die "rehearsal: logs printed nothing"
ok "rehearsal: logs prints Loki's log"

sleep 1
step "the second deploy failed" deploy
second=releases/$(cat tmp/deploy/staged)
[[ $second != "$first" && $(pointer current) == "$second" && $(pointer previous) == "$first" ]] ||
  die "rehearsal: the second deploy did not move previous and current"
ok "rehearsal: second deploy, of this tree, is current, the base is previous"

poll 120 seed || die "rehearsal: the seed series could not be written"
step "rollback --previous failed" rollback --previous
grep -q "(release ${first#releases/}) Up" <<<"$(bash tools/nas.sh status)" ||
  die "rehearsal: after rollback --previous the containers do not run the base release"
ok "rehearsal: rollback --previous runs the base release again"
# This tree's release wrote series of its own, which stay in Mimir after the
# rollback, and the seed adds a fresh one under another o11y/* job. The
# base's Up panels must show exactly the jobs the base scrapes, each up.
# With Alloy stopped and Mimir still answering, the last samples age, and
# the panels must drop them rather than show the jobs up.
base_up=$(grep -o '"job" = "[^"]*"' "$base_work/config/alloy/config.alloy" | cut -d'"' -f4 | jq -Rsc 'split("\n") | map(select(. != "")) | map([., "1"]) | sort')
poll 180 seed_and_read ". == $base_up" || die "rehearsal: after rollback --previous, with a fresh seed series in Mimir, the Up panels do not show exactly the base's jobs up"
docker stop "$(docker ps -q --filter label=com.docker.compose.project=o11y --filter label=com.docker.compose.service=alloy)" >/dev/null
poll 180 up_panels '. == []' || die "rehearsal: with Alloy stopped the Up panels still return their last samples"
docker start "$(docker ps -aq --filter label=com.docker.compose.project=o11y --filter label=com.docker.compose.service=alloy)" >/dev/null
poll 180 up_panels ". == $base_up" || die "rehearsal: once Alloy is back the Up panels do not show the base's jobs up"
ok "rehearsal: after rollback --previous the Up panels show exactly the base's jobs up, not a fresh seed series, and nothing once their samples are stale"

step "down failed" down
[[ -z $(docker ps -aq --filter label=com.docker.compose.project=o11y) ]] || die "rehearsal: down left containers"
[[ -d $remote/data/secrets && -L $remote/current ]] || die "rehearsal: down removed more than the containers"
ok "rehearsal: down removed the containers and kept data, secrets and releases"

# A probe that fails early leaves a stopped one-off s3probe container, which
# Compose's plain `down` keeps. Plant one in the gate project and show that,
# so gate-test's own teardown has to remove it.
one_offs() {
  docker ps -aq --filter label=com.docker.compose.project=o11y-gate --filter label=com.docker.compose.oneoff=True
}
planted=$remote/$first
"$compose" -p o11y-gate --env-file "$planted/.env.validate" -f "$planted/compose.yaml" -f "$planted/compose.tools.yaml" \
  run -T --entrypoint /bin/true s3probe >/dev/null 2>&1 || die "rehearsal: the one-off s3probe container could not be planted"
"$compose" -p o11y-gate --env-file "$planted/.env.validate" -f "$planted/compose.yaml" down >/dev/null 2>&1
[[ -n $(one_offs) ]] || die "rehearsal: a plain down removed the one-off container, so the planted leftover proves nothing"
ok "rehearsal: a plain down keeps a stopped one-off s3probe container in o11y-gate"

step "gate-test failed" gate-test
[[ -z $(one_offs) ]] || die "rehearsal: gate-test left a one-off container behind"
[[ -z $(docker ps -aq --filter label=com.docker.compose.project=o11y-gate) ]] || die "rehearsal: gate-test left containers"
step "gate-clean failed" gate-clean
[[ ! -e $remote/gate && -d $remote/data ]] || die "rehearsal: gate-clean removed the wrong thing"
ok "rehearsal: gate-test passed and stopped its project, gate-clean removed only the gate directory"
