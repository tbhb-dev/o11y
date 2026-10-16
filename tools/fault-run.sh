#!/usr/bin/env bash
# The recorded fault run the self-monitoring plan asks for once before a
# host deploy: Mimir stopped for five minutes under client load. Boots the
# stack from clean in its own Compose project, o11y-fault, on ports 43000,
# 44317 and 44318, and removes it on exit, pass or fail.
#
#   tools/fault-run.sh
#   tools/fault-run.sh --check-peaks <peaks file>
#   tools/fault-run.sh --check-load <inspect status> <inspect output>
#
# Client load is telemetrygen at 50 items a second per signal through the
# published ports. During the outage, the receipt check for traces and logs
# must pass at 1, 3 and 5 minutes, and once Mimir is back, the one for
# metrics. No container may be OOM-killed or restarted. A helper container
# that mounts /sys/fs/cgroup read-only records each container's raw cgroup v2
# memory files every 5 seconds, so the engine must run on Linux with cgroup
# v2, as Docker Desktop's VM does.
#
# The record stays in tmp/fault-run/: samples.tsv (raw), checks.log (what
# each check reported) and summary.txt (peaks per container, and whether
# anon stayed under 70 percent of its limit). It holds placeholder values
# only. --check-peaks and --check-load run only the memory verdict or the
# load generator verdict, which is how tools/fault-run.bats tests them.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck source=tools/lib.sh
source tools/lib.sh

# peaks_ok <peaks file>: one line per container, six of them, each with ten
# fields, and anon under 70 percent of the limit (field 7) in every one.
peaks_ok() {
  # shellcheck disable=SC2016 # awk's own fields
  awk 'NF != 10 || $7 + 0 >= 70 { bad = 1 } END { exit bad || NR != 6 }' "$1"
}

# load_ok <inspect status> <inspect output>: the inspect of a load generator
# succeeded, and the generator is running or exited 0.
load_ok() {
  [[ $1 -eq 0 && ($2 == "running 0" || $2 == "exited 0") ]]
}

case ${1:-} in
--check-peaks)
  peaks_ok "$2"
  exit
  ;;
--check-load)
  load_ok "$2" "$3"
  exit
  ;;
esac

local_engine_only
pin_docker_api

project=o11y-fault
out=$root/tmp/fault-run
work=$out/work
release=$work/release
grafana=http://127.0.0.1:43000
services=(rustfs loki tempo mimir alloy grafana)
outage=300

isolate_environment
O11Y_DATA_DIR=$(test_data_dir fault-run)
export O11Y_DATA_DIR O11Y_GRAFANA_ROOT_URL=$grafana/
export O11Y_GRAFANA_PORT=43000 O11Y_OTLP_GRPC_PORT=44317 O11Y_OTLP_HTTP_PORT=44318
uid=$(id -u)
gid=$(id -g)
O11Y_SECRETS_OWNER=$uid:$gid
export O11Y_SECRETS_OWNER

cgroup_version=$(docker info --format '{{.CgroupVersion}}') || die "the engine could not be asked for its cgroup version"
[[ $cgroup_version == 2 ]] || die "the engine does not use cgroup v2, so the raw memory files can't be read; run this on a Linux engine that does"

main() {
  "$O11Y_COMPOSE" -p "$project" --env-file "$release/.env" -f "$release/compose.yaml" "$@"
}

inside() {
  main exec -T rustfs curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"
}

is_ready() {
  local code
  code=$(inside "$1") || return 1
  [[ $code == 200 ]]
}

wait_ready() {
  local url
  case $1 in
  rustfs) url=http://127.0.0.1:9000/health/ready ;;
  loki) url=http://loki:3100/ready ;;
  tempo) url=http://tempo:3200/ready ;;
  mimir) url=http://mimir:8080/ready ;;
  alloy) url=http://alloy:12345/-/ready ;;
  grafana) url=http://grafana:3000/api/health ;;
  esac
  poll 180 is_ready "$url" || die "$1 did not become ready"
}

cleanup() {
  docker rm -f "$project-sampler" "$project-load-traces" "$project-load-logs" "$project-load-metrics" >/dev/null 2>&1 || true
  main down -v --remove-orphans >/dev/null 2>&1 || true
  remove_test_data "$util_image" || true
  rm -rf "$work"
}

# check <text> <command...>: runs a check, records its outcome, and stops
# the run when it fails.
check() {
  local what=$1
  shift
  if "$@" >>"$out/checks.log" 2>&1; then
    echo "ok $what" | tee -a "$out/checks.log"
  else
    echo "FAIL $what" | tee -a "$out/checks.log" >&2
    exit 1
  fi
}

export O11Y_CHECK_OTLP_URL=http://127.0.0.1:44318 O11Y_CHECK_GRAFANA_URL=$grafana
receipt() {
  tools/receipt.sh --signals "$1"
}

rm -rf "$out"
mkdir -p "$out"
tools/render.sh "$work" >/dev/null
model=$("$O11Y_COMPOSE" -p "$project" --profile tools --env-file "$release/.env.validate" \
  -f "$release/compose.yaml" -f "$release/compose.tools.yaml" -f "$release/compose.init.yaml" config --format json)
util_image=$(jq -er '.services.init.image' <<<"$model")
telemetrygen_image=$(jq -er '.services.telemetrygen.image' <<<"$model")
"$O11Y_COMPOSE" -p "$project" --env-file "$release/.env.validate" -f "$release/compose.yaml" \
  down -v --remove-orphans >/dev/null 2>&1 || true
remove_test_data "$util_image"
trap cleanup EXIT

COMPOSE_IGNORE_ORPHANS=1 "$O11Y_COMPOSE" -p "$project" --env-file "$release/.env" -f "$release/compose.init.yaml" \
  run --rm -T init >/dev/null 2>&1 || die "init failed"
publish_s3_env "$util_image" "$work/s3.env"
main up -d >"$out/up.log" 2>&1 || die "up failed"
for service in "${services[@]}"; do
  wait_ready "$service"
done
check "the receipt check passes on the healthy stack" receipt traces,logs,metrics

# Raw cgroup v2 files of every container, every 5 seconds, as one
# tab-separated line each: time, service, memory.current, memory.peak, anon,
# file, oom and oom_kill from memory.events. Container ids are not secret.
targets=
for service in "${services[@]}"; do
  container=$(main ps -q "$service")
  id=$(docker inspect -f '{{.Id}}' "$container")
  targets+="$service:$id "
done
# shellcheck disable=SC2016 # the helper's shell expands these
docker run -d --name "$project-sampler" --cgroupns=host --network none --user 0:0 --entrypoint /bin/sh \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro -e "TARGETS=$targets" "$util_image" -c '
while :; do
  now=$(date +%s)
  for t in $TARGETS; do
    # cgroupfs and systemd drivers name the directory differently. A
    # stopped container has none.
    d=/sys/fs/cgroup/docker/${t#*:}
    [ -d "$d" ] || d=/sys/fs/cgroup/system.slice/docker-${t#*:}.scope
    [ -d "$d" ] || continue
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$now" "${t%%:*}" "$(cat "$d/memory.current")" "$(cat "$d/memory.peak")" \
      "$(awk "\$1 == \"anon\" { print \$2 }" "$d/memory.stat")" "$(awk "\$1 == \"file\" { print \$2 }" "$d/memory.stat")" \
      "$(awk "\$1 == \"oom\" { print \$2 }" "$d/memory.events")" "$(awk "\$1 == \"oom_kill\" { print \$2 }" "$d/memory.events")"
  done
  sleep 5
done' >/dev/null

# The load runs from before the outage until well after Mimir is back.
if host_is_linux; then
  load=(--network host "$telemetrygen_image")
  endpoint=127.0.0.1:44317
else
  load=("$telemetrygen_image")
  endpoint=host.docker.internal:44317
fi
for signal in traces logs metrics; do
  docker run -d --name "$project-load-$signal" "${load[@]}" "$signal" --otlp-endpoint "$endpoint" --otlp-insecure \
    --rate 50 --duration "$((outage + 300))s" >/dev/null
done
sleep 60

main stop mimir >/dev/null 2>&1 || die "mimir could not be stopped"
stopped=$SECONDS
for minute in 1 3 5; do
  sleep $((stopped + minute * 60 - SECONDS))
  check "minute $minute of the Mimir outage: the receipt check passes for traces and logs" receipt traces,logs
done
sleep $((stopped + outage - SECONDS > 0 ? stopped + outage - SECONDS : 0))
main start mimir >/dev/null 2>&1 || die "mimir could not be started again"
wait_ready mimir
check "Mimir is back: the receipt check passes for metrics" receipt metrics
sleep 60

for signal in traces logs metrics; do
  status=0
  state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$project-load-$signal") || status=$?
  load_ok "$status" "$state" || die "the $signal load generator failed or could not be inspected (${state:-no state})"
done
docker logs "$project-sampler" >"$out/samples.tsv" 2>&1
docker rm -f "$project-sampler" >/dev/null

flags() {
  local service
  for service in "${services[@]}"; do
    container=$(main ps -q "$service") || return 1
    state=$(docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}} {{.HostConfig.Memory}}' "$container") || return 1
    echo "$service $state"
  done
}
flags >"$out/flags.txt"
# shellcheck disable=SC2016 # awk's own fields
check "no container was OOM-killed or restarted" awk '$2 != "false" || $3 != 0 { bad = 1 } END { exit bad }' "$out/flags.txt"

# Peaks per container, against the container's memory limit.
awk 'NR == FNR { limit[$1] = $4; next }
  NF != 8 || !($2 in limit) { next }
  { if ($3 > cur[$2]) cur[$2] = $3; if ($4 > peak[$2]) peak[$2] = $4; if ($5 > anon[$2]) anon[$2] = $5
    if ($6 > file[$2]) file[$2] = $6; oom[$2] = $7; kill[$2] = $8; n[$2]++ }
  END {
    mib = 1048576
    for (s in n) printf "%-8s %7.0fM %8.0fM %8.0fM %8.0fM %8.0fM %7.1f%% %4d %9d %d\n", s, limit[s] / mib, cur[s] / mib, peak[s] / mib, anon[s] / mib, file[s] / mib, 100 * anon[s] / limit[s], oom[s], kill[s], n[s]
  }' "$out/flags.txt" FS='\t' "$out/samples.tsv" | sort >"$out/peaks.txt"
{
  echo "service  limit current peak anon file anon/limit oom oom_kill samples"
  cat "$out/peaks.txt"
} >"$out/summary.txt"
cat "$out/summary.txt"
check "anon stayed under 70 percent of the limit in every container" peaks_ok "$out/peaks.txt"
