#!/usr/bin/env bash
# Static validation: renders the stack with placeholder values, loads each
# Compose file with the pinned Compose, and runs each component's own config
# check from its pinned image. Every check also runs against a deliberately
# invalid file under tests/invalid/ and must reject it, which is what shows
# the check can fail at all. Grafana has no offline check; the boot test
# covers it.
#
#   tools/validate.sh           run every check
#   tools/validate.sh --model   print the resolved Compose models as JSON
#
# --model is the one safe way to look at a resolved model. Compose prints
# the contents of every env file a model loads, so `config` without -q
# against a deployment's env file prints the S3 key. Here the model loads a
# dummy env file, and nothing inherited from the environment can change that.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck source=tools/lib.sh
source tools/lib.sh
isolate_environment

out=$root/tmp/validate
rm -rf "$out"
trap 'rm -rf "$out"' EXIT
export O11Y_DATA_DIR=$out/data O11Y_GRAFANA_ROOT_URL=https://grafana.example.ts.net/
tools/render.sh "$out"

release=$out/release
log=$out/check.log
failed=0

# .env.validate points the S3 env file at the dummy in the release.
compose() {
  "$O11Y_COMPOSE" --env-file "$release/.env.validate" "$@"
}

if [[ ${1:-} == --model ]]; then
  for file in compose.yaml compose.init.yaml compose.tools.yaml; do
    compose --profile tools -f "$release/$file" config --format json
  done
  exit 0
fi

local_engine_only
pin_docker_api

for file in compose.yaml compose.init.yaml compose.tools.yaml; do
  if compose -f "$release/$file" config -q; then
    ok "compose model: $file loads"
  else
    echo "FAIL compose model: $file does not load" >&2
    failed=1
  fi
done

# Image references and config paths come from the rendered model, so they
# are never repeated here.
model=$(compose -f "$release/compose.yaml" config --format json)

image() {
  jq -er --arg s "$1" '.services[$s].image' <<<"$model"
}

# Read once, here, where a failed read stops the script, rather than inside
# each docker run's arguments.
config_lines=$(grep '^O11Y_CONFIG_' "$release/.env")

config_dir() {
  sed -n "s/^O11Y_CONFIG_$1=//p" <<<"$config_lines"
}

# run_image <service> <config dir> <mount point> <args...>
run_image() {
  local service=$1 dir=$2 mount=$3
  shift 3
  # shellcheck disable=SC2312 # jq -e prints the image only when it succeeds, and a missing one fails docker run
  docker run --rm --network none \
    -e AWS_ACCESS_KEY_ID=validate -e AWS_SECRET_ACCESS_KEY=validate \
    -v "$dir:$mount:ro" -v "$root/tests/invalid:/invalid:ro" \
    "$(image "$service")" "$@" >"$log" 2>&1
}

# Alloy validates at the stability level the stack runs it at.
alloy_stability=$(jq -er '.services.alloy.command[] | select(startswith("--stability.level="))' <<<"$model") ||
  die "alloy: compose.yaml runs Alloy without --stability.level"

# validator <component> valid|invalid: runs the component's own config check
# on its real config or on its fixture under tests/invalid/.
# shellcheck disable=SC2312 # config_dir only reads config_lines, read above with its status
validator() {
  local real=/etc/$1/config.yaml fixture=/invalid/$1.yaml file
  if [[ $1 == alloy ]]; then
    real=/etc/alloy/config.alloy fixture=/invalid/config.alloy
  fi
  file=$real
  [[ $2 == valid ]] || file=$fixture
  case $1 in
  loki)
    run_image loki "$(config_dir LOKI)" /etc/loki "-config.file=$file" -config.expand-env=true -verify-config
    ;;
  tempo)
    run_image tempo "$(config_dir TEMPO)" /etc/tempo -target=all "-config.file=$file" -config.verify=true
    ;;
  # -modules loads and validates the config, prints the module list and
  # exits.
  mimir)
    run_image mimir "$(config_dir MIMIR)" /etc/mimir "-config.file=$file" -config.expand-env=true -modules
    ;;
  alloy)
    run_image alloy "$(config_dir ALLOY)" /etc/alloy validate "$alloy_stability" "$file"
    ;;
  esac
}

# What each component must say when it rejects its fixture: the broken key,
# or the undefined component, that the fixture contains.
rejection() {
  case $1 in
  loki) echo "field not_a_loki_section not found" ;;
  tempo) echo "field not_a_tempo_section not found" ;;
  mimir) echo "field not_a_mimir_section not found" ;;
  alloy) echo 'component "otelcol.exporter.otlp.missing.input" does not exist' ;;
  esac
}

for component in loki tempo mimir alloy; do
  if ! validator "$component" valid; then
    echo "FAIL $component: the real config was rejected" >&2
    cat "$log" >&2
    failed=1
    continue
  fi
  # Only the component's own rejection counts. Docker exits 125 to 127 when
  # a container cannot start, and above 128 on a signal; neither shows that
  # the validator ran, so neither may pass for a rejection.
  status=0
  validator "$component" invalid || status=$?
  # shellcheck disable=SC2312 # rejection only echoes
  if [[ $status -eq 0 ]]; then
    echo "FAIL $component: no coverage, the invalid fixture was accepted" >&2
    failed=1
  elif [[ $status -ge 125 ]]; then
    echo "FAIL $component: the validator did not run on the invalid fixture (exit $status)" >&2
    cat "$log" >&2
    failed=1
  elif ! grep -qF -- "$(rejection "$component")" "$log"; then
    echo "FAIL $component: the invalid fixture failed without naming what is broken in it" >&2
    cat "$log" >&2
    failed=1
  else
    ok "$component: valid accepted, invalid rejected"
  fi
done

# below_ga <log>: the components Alloy's log names as below generally
# available, one per line. It fails unless every error line is either such a
# diagnostic, in Alloy's exact wording, or the closing "validation failed",
# and the closing line is there.
below_ga() {
  awk '
    $0 == "Error: validation failed" { closed = 1; next }
    /^Error: / {
      if ($0 ~ /^Error: [^ ]+: component "[^"]+" is at stability level "[a-z-]+", which is below the minimum allowed stability level "generally-available"\. Use --stability\.level command-line flag to enable "[a-z-]+" features$/) {
        split($0, part, "\"")
        print part[2]
      } else {
        unknown = 1
      }
    }
    END { exit (unknown || !closed) }
  ' "$1"
}

# The stability level is process-wide, so it would admit any experimental
# component. At the default level Alloy exits 1 and names every component
# below it, and the one it names must be the one the level was lowered for.
status=0
# shellcheck disable=SC2312 # config_dir only reads config_lines, read above with its status
run_image alloy "$(config_dir ALLOY)" /etc/alloy validate /etc/alloy/config.alloy || status=$?
if [[ $status -eq 0 ]]; then
  echo "FAIL alloy: config.alloy passes at the default stability level, so $alloy_stability is not needed" >&2
  failed=1
elif [[ $status -ne 1 ]]; then
  echo "FAIL alloy: the check at the default stability level did not run (exit $status)" >&2
  cat "$log" >&2
  failed=1
elif ! below=$(below_ga "$log" | sort -u); then
  echo "FAIL alloy: Alloy's output at the default stability level holds an error this check doesn't recognize" >&2
  cat "$log" >&2
  failed=1
elif [[ $below != otelcol.processor.deltatocumulative ]]; then
  echo "FAIL alloy: config.alloy uses a component below generally available other than otelcol.processor.deltatocumulative" >&2
  cat "$log" >&2
  failed=1
else
  ok "alloy: otelcol.processor.deltatocumulative is the only component below generally available"
fi

# Formatting only: the invalid Alloy fixture is well formed, so this has no
# reject case.
# shellcheck disable=SC2312 # config_dir only reads config_lines, read above with its status
if run_image alloy "$(config_dir ALLOY)" /etc/alloy fmt --test /etc/alloy/config.alloy; then
  ok "alloy: formatted"
else
  echo "FAIL alloy: config.alloy is not formatted" >&2
  failed=1
fi

# bounded <config.alloy>: every scrape sets all three of its limits, and the
# one remote write has a queue_config and a wal block.
bounded() {
  awk '
    /^prometheus\.scrape "/ { scrape = 1; scrapes++; s = l = b = 0; next }
    scrape && /^\tsample_limit / { s = 1 }
    scrape && /^\tlabel_limit / { l = 1 }
    scrape && /^\tbody_size_limit / { b = 1 }
    scrape && /^}/ { scrape = 0; if (!(s && l && b)) bad = 1 }
    /^prometheus\.remote_write "/ { write = 1; writes++ }
    write && /^\t\tqueue_config \{/ { queue = 1 }
    write && /^\twal \{/ { wal = 1 }
    write && /^}/ { write = 0 }
    END { exit !(scrapes > 0 && !bad && writes == 1 && queue && wal) }' "$1"
}

alloy_dir=$(config_dir ALLOY)
if bounded "$alloy_dir/config.alloy"; then
  ok "alloy: every scrape has its sample, label and body limits, and the remote write a queue and a WAL bound"
else
  echo "FAIL alloy: a scrape lacks a limit, or the remote write lacks queue_config or wal" >&2
  failed=1
fi

# The self path: its exporter's queue is bounded in items, and its
# receiver accepts no gRPC.
self_path=$(sed -n '/^otelcol.receiver.otlp "self"/,/^}/p; /^otelcol.exporter.otlphttp "mimir_self"/,/^}/p' "$alloy_dir/config.alloy")
if grep -qE '^\t\tsizer += "items"$' <<<"$self_path" && grep -qE '^\t\tqueue_size += [0-9]+$' <<<"$self_path" && ! grep -q 'grpc' <<<"$self_path"; then
  ok "alloy: the self receiver is HTTP only, and its exporter's queue is bounded in items"
else
  echo "FAIL alloy: the self receiver takes gRPC, or its exporter's queue is not bounded in items" >&2
  failed=1
fi

if jq -e '.services.alloy | (.environment.GOMEMLIMIT | length > 0) and (.stop_grace_period | length > 0)' <<<"$model" >/dev/null; then
  ok "alloy: the container sets GOMEMLIMIT and a stop grace period"
else
  echo "FAIL alloy: the container lacks GOMEMLIMIT or stop_grace_period" >&2
  failed=1
fi

if jq -e '[.services[].ports[]?.target] | index(4320) == null' <<<"$model" >/dev/null; then
  ok "alloy: the self receiver on 4320 is not published"
else
  echo "FAIL alloy: the self receiver on 4320 is published" >&2
  failed=1
fi

if jq -e '[.services[].ports[]?.host_ip] | length > 0 and all(. == "127.0.0.1")' <<<"$model" >/dev/null; then
  ok "published ports: all bound to 127.0.0.1"
else
  echo "FAIL published ports: a port is not bound to 127.0.0.1" >&2
  failed=1
fi

exit "$failed"
