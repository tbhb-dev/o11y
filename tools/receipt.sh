#!/usr/bin/env bash
# Proves that one trace, one log and one metric sent now are stored and can be
# queried back with exact values. Every signal carries a fresh run id, so a
# stale or unrelated series cannot satisfy a check.
#
#   tools/receipt.sh [--signals <list>] [--state-file <file>] [--grpc -- <telemetrygen command...>]
#   tools/receipt.sh [--signals <list>] --recheck <file>
#
# Signals go to Alloy as OTLP/HTTP JSON. Queries go through Grafana's
# datasource proxy with no credentials, which also proves anonymous access
# and the provisioned datasources. --state-file records the run so --recheck
# can query the same three signals again later without sending anything,
# after a restart or once a backend has to answer from the object store.
#
# --signals limits the run to a comma-separated subset of traces, logs and
# metrics, such as traces,logs while Mimir is down. Only those are sent and
# checked. The default is all three.
#
# --grpc sends one more trace over OTLP gRPC. The caller supplies the
# telemetrygen command up to its endpoint flags, because how to reach the
# endpoint differs by place; it is run with `--traces 1 --service <name>`
# appended and the trace must then be found by that service name.
#
# Environment:
#   O11Y_CHECK_OTLP_URL     base URL of the OTLP/HTTP endpoint
#   O11Y_CHECK_GRAFANA_URL  base URL of Grafana
#   O11Y_CHECK_CURL         curl command, split on spaces (default: curl)
set -euo pipefail

: "${O11Y_CHECK_GRAFANA_URL:?}"
grafana=${O11Y_CHECK_GRAFANA_URL%/}
read -r -a curl_cmd <<<"${O11Y_CHECK_CURL:-curl}"

usage() {
  echo "usage: receipt.sh [--signals <list>] [--state-file <file>] [--grpc -- <telemetrygen command...>] | [--signals <list>] --recheck <file>" >&2
  exit 2
}

state=
recheck=
grpc=0
telemetrygen=()
signals=traces,logs,metrics
while [[ $# -gt 0 ]]; do
  case $1 in
  --signals)
    [[ $# -ge 2 && $2 =~ ^(traces|logs|metrics)(,(traces|logs|metrics))*$ ]] || usage
    signals=$2
    shift 2
    ;;
  --state-file)
    state=$2
    shift 2
    ;;
  --grpc)
    grpc=1
    shift
    ;;
  --recheck)
    recheck=$2
    shift 2
    ;;
  --)
    shift
    telemetrygen=("$@")
    break
    ;;
  *)
    usage
    ;;
  esac
done
[[ $grpc -eq 0 || ${#telemetrygen[@]} -gt 0 ]] || usage
[[ $grpc -eq 0 || ,$signals, == *,traces,* ]] || usage

# wanted <signal>: the run covers it.
wanted() {
  [[ ,$signals, == *,$1,* ]]
}

die() {
  echo "FAIL receipt: $*" >&2
  exit 1
}

http() {
  "${curl_cmd[@]}" -sS -m 15 "$@"
}

poll() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

uri() {
  jq -rn --arg v "$1" '$v | @uri'
}

# The body goes to curl on stdin, so it survives a curl that runs through
# another shell.
post() {
  local code
  code=$(printf '%s' "$2" | http -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary @- "${O11Y_CHECK_OTLP_URL%/}$1")
  [[ $code == 200 ]] || die "POST $1 returned $code"
}

trace_found() {
  local body
  body=$(http "$grafana/api/datasources/proxy/uid/tempo/api/traces/$trace_id") || return 1
  jq -e --arg s "$service" \
    '[.batches[]?.resource.attributes[]? | select(.key == "service.name") | .value.stringValue] == [$s]' \
    <<<"$body" >/dev/null 2>&1
}

# Exactly one line with the exact body, timestamped at or after $1 (epoch
# seconds), in a window that starts a minute before the send.
log_found() {
  local body
  body=$(http "$grafana/api/datasources/proxy/uid/loki/loki/api/v1/query_range?query=$(uri "{service_name=\"$service\"}")&start=$((sent - 60))000000000&end=$(($(date +%s) + 60))000000000&limit=10") || return 1
  jq -e --arg b "o11y-check $run_id" --argjson min "$1" \
    '[.data.result[].values[]] | length == 1 and .[0][1] == $b and (.[0][0] | tonumber) >= $min * 1e9' \
    <<<"$body" >/dev/null 2>&1
}

mimir() {
  http "$grafana/api/datasources/proxy/uid/mimir/api/v1/$1"
}

# Exactly one series whose sample equals the value sent and is no older than
# two minutes.
metric_fresh() {
  local selector body
  selector=$(uri "o11y_check_value{run_id=\"$run_id\"}")
  body=$(mimir "query?query=$selector") || return 1
  jq -e --arg v "$value" '.data.result | length == 1 and .[0].value[1] == $v' <<<"$body" >/dev/null 2>&1 || return 1
  body=$(mimir "query?query=timestamp($selector)") || return 1
  jq -e --argjson now "$(date +%s)" '.data.result[0].value[1] | tonumber >= $now - 120' <<<"$body" >/dev/null 2>&1
}

# A range query from a minute before the send until now holds a sample equal
# to the value sent.
metric_stored() {
  local body
  body=$(mimir "query_range?query=$(uri "o11y_check_value{run_id=\"$run_id\"}")&start=$((sent - 60))&end=$(date +%s)&step=15") || return 1
  jq -e --arg v "$value" '.data.result | length == 1 and any(.[0].values[]; .[1] == $v)' <<<"$body" >/dev/null 2>&1
}

grpc_found() {
  local body
  body=$(http "$grafana/api/datasources/proxy/uid/tempo/api/search?q=$(uri "{resource.service.name=\"$grpc_service\"}")&limit=5") || return 1
  jq -e '.traces | length >= 1' <<<"$body" >/dev/null 2>&1
}

if [[ -n $recheck ]]; then
  read -r run_id trace_id value sent <"$recheck"
  service=o11y-check-$run_id
  ! wanted traces || poll 60 trace_found || die "trace $trace_id is no longer returned"
  ! wanted logs || poll 60 log_found 0 || die "the log line of run $run_id is no longer returned"
  ! wanted metrics || poll 60 metric_stored || die "the metric sample of run $run_id is no longer returned"
  echo "ok receipt: run $run_id still returns its ${signals//,/, }"
  exit 0
fi

: "${O11Y_CHECK_OTLP_URL:?}"
run_id=$(hex 8)
trace_id=$(hex 16)
span_id=$(hex 8)
value=$((RANDOM * 32768 + RANDOM))
sent=$(date +%s)
service=o11y-check-$run_id
resource='{"attributes":[{"key":"service.name","value":{"stringValue":"'$service'"}}]}'
scope='{"name":"o11y-check"}'

! wanted traces || post /v1/traces '{"resourceSpans":[{"resource":'"$resource"',"scopeSpans":[{"scope":'"$scope"',"spans":[{"traceId":"'"$trace_id"'","spanId":"'"$span_id"'","name":"o11y-check","kind":1,"startTimeUnixNano":"'"$sent"'000000000","endTimeUnixNano":"'"$sent"'500000000"}]}]}]}'
! wanted logs || post /v1/logs '{"resourceLogs":[{"resource":'"$resource"',"scopeLogs":[{"scope":'"$scope"',"logRecords":[{"timeUnixNano":"'"$sent"'000000000","severityText":"INFO","body":{"stringValue":"o11y-check '"$run_id"'"}}]}]}]}'
! wanted metrics || post /v1/metrics '{"resourceMetrics":[{"resource":'"$resource"',"scopeMetrics":[{"scope":'"$scope"',"metrics":[{"name":"o11y_check_value","gauge":{"dataPoints":[{"asInt":"'"$value"'","timeUnixNano":"'"$sent"'000000000","attributes":[{"key":"run_id","value":{"stringValue":"'"$run_id"'"}}]}]}}]}]}]}'

if wanted traces; then
  poll 60 trace_found || die "trace $trace_id was not returned by Tempo"
  echo "ok receipt: trace $trace_id found in Tempo with service $service"
fi
if wanted logs; then
  poll 60 log_found "$((sent - 60))" || die "Loki did not return exactly the one log line of run $run_id"
  echo "ok receipt: exactly one log line with the run's body found in Loki"
fi
if wanted metrics; then
  poll 60 metric_fresh || die "Mimir did not return one fresh sample equal to $value for run $run_id"
  echo "ok receipt: one fresh sample equal to $value found in Mimir"
fi

if [[ $grpc -eq 1 ]]; then
  grpc_service=o11y-check-grpc-$run_id
  "${telemetrygen[@]}" --traces 1 --service "$grpc_service" >/dev/null 2>&1 ||
    die "telemetrygen could not send a trace over gRPC"
  # Tempo hides the newest 30 seconds from search.
  poll 120 grpc_found || die "no trace for service $grpc_service was found"
  echo "ok receipt: gRPC trace found in Tempo by service $grpc_service"
fi

[[ -z $state ]] || echo "$run_id $trace_id $value $sent" >"$state"
