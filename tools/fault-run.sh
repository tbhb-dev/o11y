#!/usr/bin/env bash
# The recorded fault run the self-monitoring plan asks for once before a
# host deploy: Mimir stopped for five minutes under client load. Boots the
# stack from clean in its own Compose project, o11y-fault, on ports 43000,
# 44317 and 44318, and removes it on exit, pass or fail.
#
#   tools/fault-run.sh
#   tools/fault-run.sh --check-peaks <peaks file>
#   tools/fault-run.sh --check-load <inspect status> <inspect output>
#   tools/fault-run.sh --check-samples <samples file>
#
# Client load is telemetrygen at 50 items a second per signal through the
# published ports. During the outage, the receipt check for traces and logs
# must pass at 1, 3 and 5 minutes, and once Mimir is back, the one for
# metrics. No container may be OOM-killed or restarted. This run's copy of
# the Alloy config shrinks the self exporter's queue to 200 items, so the
# outage overflows it: Alloy must count the RustFS points it could not
# queue, while the client receipts still pass. A helper container
# that mounts /sys/fs/cgroup read-only records each container's raw cgroup v2
# memory files every 5 seconds, so the engine must run on Linux with cgroup
# v2, as Docker Desktop's VM does.
#
# The record stays in tmp/fault-run/: samples.tsv (raw), checks.log (what
# each check reported) and summary.txt (peaks per container, and whether
# anon stayed under 70 percent of its limit). It holds placeholder values
# only. --check-peaks, --check-load and --check-samples run only the memory
# verdict, the load generator verdict or the sampler verdict, which is how
# tools/fault-run.bats tests them.
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

# samples_ok <samples file>: every line is a sample of eight tab-separated
# fields for one of the six services, every number a whole number, and each
# service has at least 10 samples. Anything else, an ERROR line from the
# sampler or a shell message among them, fails.
samples_ok() {
  awk -F '\t' '
    BEGIN { split("rustfs loki tempo mimir alloy grafana", w, " "); for (i in w) known[w[i]] = 1 }
    {
      good = NF == 8 && ($2 in known)
      for (i = 1; good && i <= NF; i++) if (i != 2 && $i !~ /^[0-9]+$/) good = 0
      if (!good) bad = 1
      else count[$2]++
    }
    END { for (s in known) if (count[s] < 10) bad = 1; exit bad }' "$1"
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
--check-samples)
  samples_ok "$2"
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
  # lint-curl: allow the caller compares the status code it prints
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

mimir_query() {
  curl -fsS -m 15 -G --data-urlencode "query=$1" "$grafana/api/datasources/proxy/uid/mimir/api/v1/query"
}

rustfs_pushed() {
  local body
  body=$(mimir_query 'rustfs_start_total{job="o11y/rustfs"}') || return 1
  jq -e '.data.result | length == 1' <<<"$body" >/dev/null
}

rm -rf "$out"
mkdir -p "$out"
tools/render.sh "$work" >/dev/null
alloy_config=$(grep '^O11Y_CONFIG_ALLOY=' "$release/.env" | cut -d= -f2-)/config.alloy
sed -i.orig '/^otelcol.exporter.otlphttp "mimir_self"/,/^}/s/queue_size = [0-9]*/queue_size = 200/' "$alloy_config"
! cmp -s "$alloy_config" "$alloy_config.orig" || die "the self exporter's queue could not be shrunk for this run"
rm "$alloy_config.orig"
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
check "RustFS's metrics arrive through the shrunk self queue on the healthy stack" poll 120 rustfs_pushed

# Raw cgroup v2 files of every container, every 5 seconds, as one
# tab-separated line each: time, service, memory.current, memory.peak, anon,
# file, oom and oom_kill from memory.events. Container ids are not secret.
targets=
for service in "${services[@]}"; do
  container=$(main ps -q "$service")
  id=$(docker inspect -f '{{.Id}}' "$container")
  targets+="$service:$id "
done
# Each value is read on its own and must be a whole number. A read that
# fails while the container's directory still exists prints an ERROR line,
# which fails the verdict; a container stopped in between just has no line.
# shellcheck disable=SC2016 # the helper's shell expands these
docker run -d --name "$project-sampler" --cgroupns=host --network none --user 0:0 --entrypoint /bin/sh \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro -e "TARGETS=$targets" "$util_image" -c '
num() { case $1 in "" | *[!0-9]*) return 1 ;; esac; }
field() { awk -v k="$1" "\$1 == k { print \$2; found = 1 } END { exit !found }" "$2"; }
while :; do
  now=$(date +%s) || now=
  for t in $TARGETS; do
    s=${t%%:*}
    # cgroupfs and systemd drivers name the directory differently. A
    # stopped container has none.
    d=/sys/fs/cgroup/docker/${t#*:}
    [ -d "$d" ] || d=/sys/fs/cgroup/system.slice/docker-${t#*:}.scope
    [ -d "$d" ] || continue
    if cur=$(cat "$d/memory.current") && peak=$(cat "$d/memory.peak") &&
      anon=$(field anon "$d/memory.stat") && file=$(field file "$d/memory.stat") &&
      oom=$(field oom "$d/memory.events") && kills=$(field oom_kill "$d/memory.events") &&
      num "$now" && num "$cur" && num "$peak" && num "$anon" && num "$file" && num "$oom" && num "$kills"; then
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$now" "$s" "$cur" "$peak" "$anon" "$file" "$oom" "$kills"
    elif [ -d "$d" ]; then
      printf "ERROR\t%s\ta cgroup memory file could not be read or held no whole number\n" "$s"
    fi
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
self_overflowed() {
  local body
  body=$(mimir_query 'max_over_time(otelcol_exporter_enqueue_failed_metric_points_total{job="o11y/alloy", component_id="otelcol.exporter.otlphttp.mimir_self"}[15m])') || return 1
  jq -e '.data.result | length == 1 and (.[0].value[1] | tonumber) > 0' <<<"$body" >/dev/null
}
check "the shrunk self queue overflowed during the outage, and Alloy counted the points it could not queue" poll 180 self_overflowed
sleep 60

for signal in traces logs metrics; do
  status=0
  state=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$project-load-$signal") || status=$?
  load_ok "$status" "$state" || die "the $signal load generator failed or could not be inspected (${state:-no state})"
done
sampler=$(docker inspect -f '{{.State.Status}}' "$project-sampler") || die "the sampler could not be inspected"
[[ $sampler == running ]] || die "the sampler stopped before the end of the run"
docker logs "$project-sampler" >"$out/samples.tsv" 2>&1 || die "the sampler's record could not be read"
docker rm -f "$project-sampler" >/dev/null
check "the sampler read every cgroup memory file it tried, with at least 10 samples per container" samples_ok "$out/samples.tsv"

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
  NF != 8 || !($2 in limit) { next }  # samples_ok has failed the run on these already
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
