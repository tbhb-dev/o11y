#!/usr/bin/env bash
# Boot test. Renders the stack with placeholder values, starts it from clean
# in its own Compose project on ports 13000, 14317 and 14318, and proves that
# it stores and returns telemetry through RustFS. One `ok` line per group;
# everything it created is removed on exit, pass or fail.
#
# The run seeds known sentinel values as the S3 key and the Grafana password
# and ends by searching everything it rendered, logged, ran or printed for
# them, so a secret that leaks into any of those fails the test.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck source=tools/lib.sh
source tools/lib.sh
pin_docker_api

project=o11y-smoke
out=$root/tmp/smoke
release=$out/release
grafana=http://127.0.0.1:13000
services=(rustfs loki tempo mimir alloy grafana)

isolate_environment
O11Y_DATA_DIR=$(test_data_dir smoke)
export O11Y_DATA_DIR O11Y_GRAFANA_ROOT_URL=$grafana/
export O11Y_GRAFANA_PORT=13000 O11Y_OTLP_GRPC_PORT=14317 O11Y_OTLP_HTTP_PORT=14318
# Compose itself reads s3.env, so the invoking user has to own it.
O11Y_SECRETS_OWNER=$(id -u):$(id -g)
export O11Y_SECRETS_OWNER

dc() {
  "$O11Y_COMPOSE" -p "$project" --env-file "$release/.env" "$@"
}

main() {
  dc -f "$release/compose.yaml" "$@"
}

s3probe() {
  dc -f "$release/compose.yaml" -f "$release/compose.tools.yaml" run --rm -T s3probe "$@"
}

# Sentinels have the length and character set init.sh accepts, so it keeps
# them. They are not secrets: this project is the only place they unlock.
sentinel_access=SENTINEL000000000000
sentinel_secret=SmokeSentinelSecretKeyNotARealSecret0000
sentinel_password=SmokeSentinelAdminPasswordNoReal

# The init file shares the project with the stack, whose containers Compose
# would otherwise report as orphans on every run.
init() {
  COMPOSE_IGNORE_ORPHANS=1 dc -f "$release/compose.init.yaml" run --rm -T init >/dev/null 2>&1 || return 1
  publish_s3_env "$util_image" "$out/s3.env"
}

# Runs a script as root in a utility container with the data directory at /d.
# These scripts handle the secret files, so the container keeps no log.
util() {
  docker run --rm --log-driver none --user 0:0 --network none --entrypoint /bin/sh \
    -v "$O11Y_DATA_DIR:/d" "$util_image" -c "$1"
}

cleanup() {
  main down -v --remove-orphans >/dev/null 2>&1 || true
  remove_test_data "$util_image" || true
  rm -rf "$out"
}

# In-network request from the rustfs container, which has curl. The backends
# publish no ports and their images have no HTTP client.
inside() {
  main exec -T rustfs curl -s -o /dev/null -w '%{http_code}' -m 10 "$@"
}

is_ready() {
  [[ $(inside "$1") == 200 ]]
}

is_healthy() {
  [[ $(docker inspect -f '{{.State.Health.Status}}' "$(main ps -q "$1")") == healthy ]]
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

# Status code of a request to Grafana with no credentials.
grafana_status() {
  curl -s -o /dev/null -w '%{http_code}' -m 15 "$@"
}

container_ids() {
  local service
  for service in "${services[@]}"; do
    echo "$service $(main ps -q "$service")"
  done
}

rm -rf "$out"
mkdir -p "$out"
# Everything printed from here on is kept for the sentinel search.
exec > >(tee "$out/transcript.log") 2>&1
tools/render.sh "$out"

# The first start happens the way a deploy does it: the models load before
# any generated file exists, then init runs on an empty directory, then up.
for file in compose.yaml compose.init.yaml compose.tools.yaml; do
  "$O11Y_COMPOSE" -p "$project" --env-file "$release/.env.validate" -f "$release/$file" config -q ||
    die "$file does not load without the generated secrets"
done
model=$("$O11Y_COMPOSE" -p "$project" --profile tools --env-file "$release/.env.validate" \
  -f "$release/compose.yaml" -f "$release/compose.tools.yaml" -f "$release/compose.init.yaml" config --format json)
util_image=$(jq -er '.services.init.image' <<<"$model")
telemetrygen_image=$(jq -er '.services.telemetrygen.image' <<<"$model")
# A run that was killed can leave its project behind.
"$O11Y_COMPOSE" -p "$project" --env-file "$release/.env.validate" -f "$release/compose.yaml" \
  down -v --remove-orphans >/dev/null 2>&1 || true
remove_test_data "$util_image"
trap cleanup EXIT

# 1. Init.
seed() {
  util "mkdir -p /d/secrets && rm -f /d/secrets/$1 && printf '%s\n' '$2' >/d/secrets/$1"
}
truncate_secret() {
  util "rm -f /d/secrets/$1 && : >/d/secrets/$1"
}
seeded() {
  util "[ \"\$(cat /d/secrets/rustfs.access_key)\" = '$sentinel_access' ] &&
    [ \"\$(cat /d/secrets/rustfs.secret_key)\" = '$sentinel_secret' ] &&
    [ \"\$(cat /d/secrets/grafana_admin_password)\" = '$sentinel_password' ]"
}
# s3.env must be exactly what the two key files say.
consistent() {
  # shellcheck disable=SC2016 # the container's shell expands these
  util 'cd /d/secrets && [ "$(cat s3.env)" = "AWS_ACCESS_KEY_ID=$(cat rustfs.access_key)
AWS_SECRET_ACCESS_KEY=$(cat rustfs.secret_key)" ]'
}
# Owners, modes, times and checksums of the secrets; compared, never printed.
fingerprint() {
  util "cd /d && { ls -A secrets; stat -c '%n %u:%g %a' * secrets/s3.env;
    stat -c '%n %u:%g %a %Y' secrets/rustfs.* secrets/grafana_admin_password; sha256sum secrets/*; } | sha256sum"
}
seed rustfs.access_key "$sentinel_access"
seed rustfs.secret_key "$sentinel_secret"
seed grafana_admin_password "$sentinel_password"
init || die "1: init failed"
seeded || die "1: init replaced a valid existing secret"
consistent || die "1: s3.env does not match the key files"
expected="alloy 0:0 750
grafana 472:472 750
loki 10001:10001 750
mimir 0:0 750
rustfs 10001:10001 750
secrets 0:0 755
tempo 10001:10001 750
secrets/grafana_admin_password 472:472 400 33
secrets/rustfs.access_key 10001:10001 400 21
secrets/rustfs.secret_key 10001:10001 400 41
secrets/s3.env $O11Y_SECRETS_OWNER 600 102"
[[ $(util "cd /d && stat -c '%n %u:%g %a' * && stat -c '%n %u:%g %a %s' secrets/*") == "$expected" ]] ||
  die "1: owners, modes or sizes differ from the layout"
before=$(fingerprint)
init || die "1: the second init failed"
[[ $(fingerprint) == "$before" ]] || die "1: a second init changed a file"
# A first run interrupted after the keys were written, before s3.env was,
# with a temporary file left behind.
util 'rm /d/secrets/s3.env && : >/d/secrets/.tmp.s3.env'
init || die "1: init did not recover from an interrupted run"
[[ $(fingerprint) == "$before" ]] || die "1: recovery changed a key or left a stray file"
# A truncated key while the store is still empty is generated afresh.
truncate_secret rustfs.access_key
init || die "1: init did not replace a truncated key in an empty store"
consistent || die "1: s3.env does not match the regenerated key"
! seeded || die "1: a truncated key was left in place"
seed rustfs.access_key "$sentinel_access"
{ init && seeded && consistent; } || die "1: the sentinel key could not be restored"
ok "1: init creates the layout and secrets, keeps valid ones, and completes an interrupted or truncated first run"

# 2. Start, buckets, credentials.
main up -d >"$out/up.log" 2>&1 || {
  cat "$out/up.log"
  die "2: up failed"
}
bucket_log() {
  tr -d '\r' | grep '^bucket ' | sort | tr '\n' ';'
}
[[ $(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$(main ps -a -q s3-buckets)") == "exited 0" ]] ||
  die "2: s3-buckets did not exit 0"
[[ $(main logs --no-log-prefix s3-buckets 2>&1 | bucket_log) == "bucket loki created;bucket mimir-blocks created;bucket mimir-ruler created;bucket tempo created;" ]] ||
  die "2: the first run did not create the four buckets"
buckets=$(s3probe buckets | sort)
[[ $(main run --rm -T s3-buckets 2>&1 | bucket_log) == "bucket loki exists;bucket mimir-blocks exists;bucket mimir-ruler exists;bucket tempo exists;" ]] ||
  die "2: a second run did not find the four buckets"
[[ $(s3probe buckets | sort) == "$buckets" ]] || die "2: a second run recreated a bucket"
s3probe delete-bucket mimir-ruler
[[ $(main run --rm -T s3-buckets 2>&1 | bucket_log) == "bucket loki exists;bucket mimir-blocks exists;bucket mimir-ruler created;bucket tempo exists;" ]] ||
  die "2: a run after a partial bootstrap did not create exactly the missing bucket"
[[ $(s3probe buckets | sort | grep -v '^mimir-ruler') == "$(grep -v '^mimir-ruler' <<<"$buckets")" ]] ||
  die "2: completing a partial bootstrap recreated an existing bucket"
# A missing dependency can still boot by luck, so the model is checked too.
jq -e '[.services["loki", "tempo", "mimir"].depends_on["s3-buckets"].condition] == ["service_completed_successfully", "service_completed_successfully", "service_completed_successfully"]
  and .services["s3-buckets"].depends_on.rustfs.condition == "service_healthy"' <<<"$model" >/dev/null ||
  die "2: a backend does not wait for the buckets, or the buckets for rustfs"
main logs --no-log-prefix rustfs 2>&1 | rustfs_log_ok || die "2: the rustfs start log shows a default login or an unsupported host"
s3probe default-credentials || die "2: the default login was not refused as an unknown access key"
# Once the store holds data, a damaged key must stop init, not be replaced.
truncate_secret rustfs.secret_key
before=$(fingerprint)
# Only init's own refusal counts, not a run that never started.
if COMPOSE_IGNORE_ORPHANS=1 dc -f "$release/compose.init.yaml" run --rm -T init >"$out/init.log" 2>&1; then
  die "2: init replaced a damaged key of a store that holds data"
fi
grep -qF 'rustfs.secret_key is missing or damaged and /data/rustfs/.rustfs.sys already exists' "$out/init.log" ||
  die "2: init failed, but not by refusing to replace the damaged key"
[[ $(fingerprint) == "$before" ]] || die "2: a refused init still changed a file"
seed rustfs.secret_key "$sentinel_secret"
{ init && seeded; } || die "2: the sentinel key could not be restored"
ok "2: up succeeds, buckets are created once and completed after a partial run, rustfs refuses the default login, init refuses to replace a key in use"

# 3. Readiness.
for service in "${services[@]}"; do
  wait_ready "$service"
done
for service in rustfs tempo alloy grafana; do
  poll 120 is_healthy "$service" || die "3: $service is not healthy"
done
ok "3: all six services are ready, and the four with a healthcheck report healthy"

# 4. Grafana access model.
[[ $(grafana_status "$grafana/api/org") == 200 ]] || die "4: anonymous access is off"
[[ $(grafana_status -X POST -H 'Content-Type: application/json' \
  -d '{"dashboard":{"uid":"o11y-smoke","title":"o11y smoke"},"overwrite":true}' "$grafana/api/dashboards/db") == 200 ]] ||
  die "4: an anonymous user cannot save a dashboard"
[[ $(grafana_status -X DELETE "$grafana/api/dashboards/uid/o11y-smoke") == 200 ]] || die "4: the test dashboard could not be deleted"
[[ $(grafana_status -X POST -H 'Content-Type: application/json' \
  -d '{"name":"smoke","type":"prometheus","access":"proxy","url":"http://127.0.0.1"}' "$grafana/api/datasources") == 403 ]] ||
  die "4: an anonymous user can add a datasource"
# The password reaches curl on stdin, as a real one would have to.
[[ $(printf 'user = "admin:%s"\n' "$sentinel_password" | grafana_status -K - "$grafana/api/admin/settings") == 200 ]] ||
  die "4: the admin password from the file does not work"
# With anonymous access on, Grafana treats a failed login as an anonymous
# request, and the admin API forbids the anonymous Editor: 403, where the
# generated password above got 200. The request has to complete and say
# exactly that, or an outage would pass for a refusal.
printf 'user = "admin:%s"\n' admin | expect_status 403 -K - "$grafana/api/admin/settings" ||
  die "4: the default admin password was not refused"
[[ $(curl -s -m 15 "$grafana/api/datasources" | jq -c '[.[].uid] | sort') == '["loki","mimir","tempo"]' ]] ||
  die "4: the provisioned datasources are not the expected three"
[[ $(curl -s -m 15 "$grafana/api/dashboards/uid/o11y-stack-health" | jq -r '.meta.provisioned') == true ]] ||
  die "4: the provisioned dashboard is missing"
# The call deploy makes on every run (home_cmd in tools/nas.sh), until the
# Grafana pin has the fix for grafana/grafana#131876.
[[ $(printf 'user = "admin:%s"\n' "$sentinel_password" | grafana_status -K - -X PUT -H 'Content-Type: application/json' \
  -d '{"homeDashboardUID":"o11y-stack-health"}' "$grafana/api/org/preferences") == 200 ]] ||
  die "4: the home dashboard could not be set"
[[ $(printf 'user = "admin:%s"\n' "$sentinel_password" | curl -s -m 15 -K - "$grafana/api/org/preferences" | jq -r '.homeDashboardUID') == o11y-stack-health ]] ||
  die "4: the org preferences do not name the provisioned dashboard as home"
# An anonymous user gets the org preferences, so its home is that dashboard.
[[ $(curl -s -m 15 "$grafana/api/dashboards/home" | jq -r '.redirectUri') == /d/o11y-stack-health/* ]] ||
  die "4: the anonymous home is not the provisioned dashboard"
main logs --no-log-prefix grafana >"$out/grafana.log" 2>&1 || die "4: the Grafana log could not be read"
# A log without provisioning lines would pass the error check vacuously.
grep -qi 'provisioning' "$out/grafana.log" || die "4: the Grafana log shows no provisioning at all"
! grep -i 'provisioning' "$out/grafana.log" | grep -qiE 'level=(error|warn)' ||
  die "4: the Grafana log has a provisioning error"
ok "4: anonymous Editor can save dashboards but not datasources, only the generated admin password works, the home dashboard is set, provisioning is clean"

# 5. Exact receipt of one trace, log and metric over OTLP/HTTP, plus one
# trace over gRPC. Both go through the published ports. A container reaches
# the host's loopback through the host network on Linux and through
# host.docker.internal on Docker Desktop.
export O11Y_CHECK_OTLP_URL=http://127.0.0.1:14318 O11Y_CHECK_GRAFANA_URL=$grafana
if [[ $(uname -s) == Linux ]]; then
  telemetrygen=(docker run --rm --network host "$telemetrygen_image" traces --otlp-endpoint 127.0.0.1:14317 --otlp-insecure)
else
  telemetrygen=(docker run --rm "$telemetrygen_image" traces --otlp-endpoint host.docker.internal:14317 --otlp-insecure)
fi
receipt() {
  tools/receipt.sh --state-file "$1" --grpc -- "${telemetrygen[@]}"
}
receipt "$out/receipt" || die "5: receipt failed"
ok "5: receipt over OTLP/HTTP and gRPC through the published ports"

# 6. Read back from the object store. A backend whose container is removed
# and whose local directory is emptied can only answer from its bucket.
has_objects() {
  [[ $(s3probe count "$1") -ge 1 ]]
}
[[ $(inside -X POST http://loki:3100/flush) == 204 ]] || die "6: Loki's flush endpoint failed"
[[ $(inside -X POST http://mimir:8080/ingester/flush) == 204 ]] || die "6: Mimir's flush endpoint failed"
poll 120 has_objects loki || die "6: the loki bucket is empty after a flush"
poll 120 has_objects mimir-blocks || die "6: the mimir-blocks bucket is empty after a flush"
# Tempo cuts a block every 30 seconds by default and has no flush endpoint.
poll 240 has_objects tempo || die "6: the tempo bucket is still empty"
# Loki ships its index on a graceful stop, so with its local data emptied it
# can answer only from the bucket.
main rm -sf loki >/dev/null 2>&1 || die "6: loki could not be removed"
util "rm -rf /d/loki/* /d/loki/.[!.]*"
main up -d loki >"$out/up.log" 2>&1 || die "6: loki could not be created again"
wait_ready loki
tools/receipt.sh --recheck "$out/receipt" >/dev/null || die "6: loki lost the receipt once its local data was emptied"
# Tempo and Mimir are only shown to keep the receipt across a restart, with
# their local data in place. Mimir answers a query this fresh from its
# ingester alone: the store is consulted only for samples older than 12
# hours. Tempo cannot be made to wait for the upload of this trace's block
# through its public API: a lookup with mode=blocks reaches the query
# frontend, and at v3.1.0 modules/frontend/traceid_sharder.go
# (buildShardedRequests, from line 157) overwrites mode on every sub-request,
# with an ingester job first and then mode=blocks for each block shard. So an
# emptied local directory could lose a trace whose block was still local.
for service in tempo mimir; do
  main restart "$service" >/dev/null 2>&1 || die "6: $service did not restart"
  wait_ready "$service"
  tools/receipt.sh --recheck "$out/receipt" >/dev/null || die "6: the receipt is gone after restarting $service"
done
ok "6: the three buckets hold objects, Loki returns the receipt from the bucket alone, Tempo and Mimir keep it across a restart"

# 7. Self-monitoring.
all_up() {
  [[ $(curl -s -m 15 "$grafana/api/datasources/proxy/uid/mimir/api/v1/query?query=up%3D%3D1" |
    jq -c '[.data.result[].metric.job] | sort') == '["alloy","grafana","loki","mimir","tempo"]' ]]
}
poll 180 all_up || die "7: up is not 1 for the five scraped jobs"
ok "7: up is 1 for alloy, grafana, loki, mimir and tempo"

# 8. A release only recreates what changed. The same tree rendered again
# must leave every container alone. One changed byte in Loki's config must
# recreate Loki, and with it Alloy and Grafana: this Compose version also
# recreates the services that depend on a recreated one. The other backends
# and the object store must stay untouched.
before=$(container_ids)
tools/render.sh "$out/again" --config-root "$out/config"
release=$out/again/release
main up -d >"$out/up.log" 2>&1 || die "8: up from an identical release failed"
[[ $(container_ids) == "$before" ]] || die "8: an identical release recreated a container"
mkdir -p "$out/src/tools"
cp -R compose.yaml compose.init.yaml compose.tools.yaml config "$out/src/"
cp tools/render.sh "$out/src/tools/"
echo "#" >>"$out/src/config/loki/config.yaml"
"$out/src/tools/render.sh" "$out"
release=$out/release
main up -d >"$out/up.log" 2>&1 || die "8: up from the changed release failed"
changed=$({ diff <(echo "$before") <(container_ids) || true; } | sed -n 's/^> \([a-z]*\) .*/\1/p' | tr '\n' ' ')
[[ $changed == "loki alloy grafana " ]] || die "8: a changed Loki config recreated: $changed"
for service in loki alloy grafana; do
  wait_ready "$service"
done
ok "8: an identical release changes no container, a changed Loki config recreates only Loki and its dependents"

# 9. Restarts that bypass `up`, where depends_on orders nothing and the
# one-shots do not run again: a Compose restart, then what a daemon or host
# restart does, every container started at once, dependents first.
main restart >/dev/null 2>&1 || die "9: restart failed"
for service in "${services[@]}"; do
  wait_ready "$service"
done
ids=()
for service in grafana alloy tempo mimir loki rustfs; do
  ids+=("$(main ps -q "$service")")
done
docker stop "${ids[@]}" >/dev/null
docker start "${ids[@]}" >/dev/null
for service in "${services[@]}"; do
  wait_ready "$service"
done
receipt "$out/receipt-restarted" >/dev/null || die "9: receipt failed after a restart without up"
ok "9: the stack recovers from a Compose restart and from a stop and start of every container, and passes the receipt again"

# 10. Sentinel search. The process arguments are a snapshot of what is
# running now: a command that took a key as an argument and has since exited
# is not in it, so this is not evidence about the whole run.
# Self-test of the search itself: O11Y_SMOKE_LEAK=log, args or rendered
# leaks the secret key sentinel into one searched place, and the run must
# then fail here and name that place.
case ${O11Y_SMOKE_LEAK:-} in
log) main exec -T rustfs sh -c "echo $sentinel_secret >/proc/1/fd/1" ;;
args) main exec -d -T rustfs sh -c 'while :; do sleep 5; done' "$sentinel_secret" ;;
rendered) echo "$sentinel_secret" >>"$release/.env" ;;
esac
for service in "${services[@]}"; do
  docker top "$(main ps -q "$service")" >>"$out/processes.log"
done
main logs --no-color >"$out/containers.log" 2>&1
# The one sanctioned way to print a resolved model, run here with the real
# env file named in the environment, which it must ignore.
O11Y_S3_ENV_FILE=${O11Y_S3_ENV_FILE:-$O11Y_DATA_DIR/secrets/s3.env} tools/validate.sh --model >"$out/model.log" ||
  die "10: the resolved model could not be printed"
for sentinel in "$sentinel_access" "$sentinel_secret" "$sentinel_password"; do
  sentinel_absent "$sentinel" "the rendered release=$out/release" "the rendered release=$out/again" \
    "the rendered source copy=$out/src" "the rendered config=$out/config" \
    "a container log=$out/containers.log" "a process argument=$out/processes.log" \
    "the printed Compose model=$out/model.log" \
    "this script's output=$out/transcript.log" || die "10: a sentinel secret leaked"
done
ok "10: no sentinel secret in the rendered output, container logs, process arguments or test output"

# 11. Delta temporality. Claude Code and Codex send delta sums, which Mimir
# rejects over OTLP and counts as otlp_parse_error; Alloy turns them into
# cumulative ones. Two deltas, 3 then 4, must arrive as one series at 7, a
# cumulative sum of 5 beside them must arrive as 5, and Mimir must have
# discarded nothing. Its counter is read from Mimir itself, not from the
# scraped copy, which lags by a scrape interval.
discarded() {
  main exec -T rustfs curl -sS --fail -m 10 http://mimir:8080/metrics | otlp_parse_discards
}
# sum_point <name> <temporality: 1 delta, 2 cumulative> <value> <start> <end>
sum_point() {
  printf '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"o11y-smoke-delta"}}]},"scopeMetrics":[{"scope":{"name":"o11y-smoke"},"metrics":[{"name":"%s","sum":{"aggregationTemporality":%s,"isMonotonic":true,"dataPoints":[{"asInt":"%s","startTimeUnixNano":"%s000000000","timeUnixNano":"%s000000000","attributes":[{"key":"run_id","value":{"stringValue":"%s"}}]}]}}]}]}]}' \
    "$1" "$2" "$3" "$4" "$5" "$delta_run"
}
send_point() {
  sum_point "$@" | expect_status 200 -H 'Content-Type: application/json' --data-binary @- "$O11Y_CHECK_OTLP_URL/v1/metrics"
}
# The value of the run's one series of that name, or "none". A query that
# fails fails this too.
mimir_value() {
  curl -sS --fail -m 15 "$grafana/api/datasources/proxy/uid/mimir/api/v1/query" \
    --data-urlencode "query=$1{run_id=\"$delta_run\"}" | jq -er '.data.result | if length == 1 then .[0].value[1] else "none" end'
}
# Each poll keeps what it saw, for the failure message.
seen_delta=unread seen_cumulative=unread
arrived() {
  seen_delta=$(mimir_value o11y_smoke_delta_total) || return 1
  seen_cumulative=$(mimir_value o11y_smoke_cumulative_total) || return 1
  [[ $seen_delta == 7 && $seen_cumulative == 5 ]]
}
# Groups 3 and 5 already show this Alloy starting and ingesting; this shows
# it does so at the stability level the processor needs.
alloy_id=$(main ps -q alloy) || die "11: the Alloy container could not be found"
alloy_args=$(docker inspect -f '{{json .Args}}' "$alloy_id") || die "11: the Alloy container could not be inspected"
[[ $alloy_args == *'"--stability.level=experimental"'* ]] || die "11: Alloy runs without --stability.level=experimental"
delta_run=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
before=$(discarded) || die "11: Mimir's discarded samples could not be read"
now=$(date +%s)
send_point o11y_smoke_delta 1 3 "$((now - 20))" "$((now - 10))" || die "11: Alloy refused the first delta point"
send_point o11y_smoke_delta 1 4 "$((now - 10))" "$now" || die "11: Alloy refused the second delta point"
send_point o11y_smoke_cumulative 2 5 "$((now - 20))" "$now" || die "11: Alloy refused the cumulative point"
poll 60 arrived || die "11: Mimir holds delta $seen_delta and cumulative $seen_cumulative, not 7 and 5"
after=$(discarded) || die "11: Mimir's discarded samples could not be read"
[[ $after == "$before" ]] || die "11: Mimir discarded $((after - before)) samples as otlp_parse_error"
# The conversion's state is in memory, so after a restart the same stream
# starts again from its next delta: 2, not 9.
delta_after_restart() {
  seen_delta=$(mimir_value o11y_smoke_delta_total) || return 1
  [[ $seen_delta == 2 ]]
}
# Alloy's readiness doesn't cover its OTLP receiver, which may still be
# starting, so the measured point waits until an empty request is accepted.
otlp_listening() {
  expect_status 200 -H 'Content-Type: application/json' --data-binary '{}' "$O11Y_CHECK_OTLP_URL/v1/metrics" 2>/dev/null
}
main restart alloy >/dev/null 2>&1 || die "11: alloy did not restart"
wait_ready alloy
poll 60 otlp_listening || die "11: Alloy's OTLP receiver did not accept a request after its restart"
now=$(date +%s)
send_point o11y_smoke_delta 1 2 "$((now - 5))" "$now" || die "11: Alloy refused the delta point after its restart"
poll 60 delta_after_restart || die "11: after a restart Mimir holds delta $seen_delta, not 2"
after=$(discarded) || die "11: Mimir's discarded samples could not be read"
[[ $after == "$before" ]] || die "11: Mimir discarded $((after - before)) samples as otlp_parse_error after Alloy restarted"
ok "11: two delta points arrive in Mimir as one cumulative series at their sum, a cumulative point as itself, a restarted Alloy starts the series again, and Mimir discards none"
