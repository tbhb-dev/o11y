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
  rm -rf "$out"
  exit 0
fi

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

config_dir() {
  grep "^O11Y_CONFIG_$1=" "$release/.env" | cut -d= -f2-
}

# run_image <service> <config dir> <mount point> <args...>
run_image() {
  local service=$1 dir=$2 mount=$3
  shift 3
  docker run --rm --network none \
    -e AWS_ACCESS_KEY_ID=validate -e AWS_SECRET_ACCESS_KEY=validate \
    -v "$dir:$mount:ro" -v "$root/tests/invalid:/invalid:ro" \
    "$(image "$service")" "$@" >"$log" 2>&1
}

# validator <component> valid|invalid: runs the component's own config check
# on its real config or on its fixture under tests/invalid/.
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
    run_image alloy "$(config_dir ALLOY)" /etc/alloy validate "$file"
    ;;
  esac
}

for component in loki tempo mimir alloy; do
  if ! validator "$component" valid; then
    echo "FAIL $component: the real config was rejected" >&2
    cat "$log" >&2
    failed=1
  elif validator "$component" invalid; then
    echo "FAIL $component: no coverage, the invalid fixture was accepted" >&2
    failed=1
  else
    ok "$component: valid accepted, invalid rejected"
  fi
done

# Formatting only: the invalid Alloy fixture is well formed, so this has no
# reject case.
if run_image alloy "$(config_dir ALLOY)" /etc/alloy fmt --test /etc/alloy/config.alloy; then
  ok "alloy: formatted"
else
  echo "FAIL alloy: config.alloy is not formatted" >&2
  failed=1
fi

if jq -e '[.services[].ports[]?.host_ip] | length > 0 and all(. == "127.0.0.1")' <<<"$model" >/dev/null; then
  ok "published ports: all bound to 127.0.0.1"
else
  echo "FAIL published ports: a port is not bound to 127.0.0.1" >&2
  failed=1
fi

rm -rf "$out"
exit "$failed"
