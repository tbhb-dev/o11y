#!/usr/bin/env bash
# Exercises RustFS on its own, before any backend depends on it: the start
# log, readiness with the console off, refusal of the default login, object
# round trips with multipart and a paginated listing, and recovery after the
# process is killed mid-write.
#
#   tools/rustfs-probe.sh
#   tools/rustfs-probe.sh --release <dir> --project <name> [-- <compose command...>]
#
# With no arguments it renders a throwaway release under tmp/probe, runs the
# probe in its own Compose project and removes everything afterwards. With
# --release it probes that rendered release through the given Compose
# command and leaves the project and its data in place; only the probe
# bucket is removed. In that mode Compose reads the S3 env file the release
# names, so run it where that file is readable: on the host that holds the
# data directory, or with O11Y_S3_ENV_FILE pointing at a readable copy.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# shellcheck source=tools/lib.sh
source tools/lib.sh

release=
project=o11y-probe
compose=()
while [[ $# -gt 0 ]]; do
  case $1 in
  --release)
    release=$2
    shift 2
    ;;
  --project)
    project=$2
    shift 2
    ;;
  --)
    shift
    compose=("$@")
    break
    ;;
  *)
    echo "usage: rustfs-probe.sh [--release <dir> --project <name> [-- <compose command...>]]" >&2
    exit 2
    ;;
  esac
done

dc() {
  "${compose[@]}" -p "$project" --env-file "$release/.env" "$@"
}

main() {
  dc -f "$release/compose.yaml" "$@"
}

tools() {
  dc -f "$release/compose.yaml" -f "$release/compose.tools.yaml" "$@"
}

s3probe() {
  tools run --rm -T s3probe "$@"
}

init() {
  COMPOSE_IGNORE_ORPHANS=1 dc -f "$release/compose.init.yaml" run --rm -T init >/dev/null
}

# Whatever way the script ends, stop the background writer of step 5 and
# remove the scratch directory. A local run also removes its project.
writer=
scratch=$(mktemp -d)
finish() {
  [[ -z $writer ]] || kill "$writer" 2>/dev/null || true
  rm -rf "$scratch"
  [[ $(type -t cleanup) != function ]] || cleanup
}
trap finish EXIT

if [[ -z $release ]]; then
  pin_docker_api
  isolate_environment
  compose=("$O11Y_COMPOSE")
  out=$root/tmp/probe
  release=$out/release
  O11Y_DATA_DIR=$(test_data_dir probe)
  O11Y_SECRETS_OWNER=$(id -u):$(id -g)
  export O11Y_DATA_DIR O11Y_SECRETS_OWNER O11Y_GRAFANA_ROOT_URL=http://127.0.0.1:13000/

  rm -rf "$out"
  tools/render.sh "$out"
  image=$(dc -f "$release/compose.init.yaml" config --format json | jq -er '.services.init.image')

  cleanup() {
    main down -v --remove-orphans >/dev/null 2>&1 || true
    remove_test_data "$image" || true
    rm -rf "$out"
  }

  # A run that was killed can leave its project and data behind.
  dc -f "$release/compose.init.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  remove_test_data "$image"
  init || die "init failed"
  publish_s3_env "$image" "$out/s3.env"
else
  if [[ ${#compose[@]} -eq 0 ]]; then
    pin_docker_api
    compose=("$O11Y_COMPOSE")
  fi
  init || die "init failed"
fi

ready() {
  [[ $(main exec -T rustfs curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/health/ready) == 200 ]]
}

main up -d rustfs >/dev/null 2>&1 || die "rustfs did not start"
poll 120 ready || die "rustfs did not become ready"

main logs --no-log-prefix rustfs 2>&1 | rustfs_log_ok || die "1: the rustfs start log shows a default login or an unsupported host"
ok "1: start log is clean and reports the console off"

# curl exits 7 when nothing accepts the connection.
status=0
main exec -T rustfs curl -s -o /dev/null -m 5 http://127.0.0.1:9001/ || status=$?
[[ $status -eq 7 ]] || die "2: something answers on the console port"
ok "2: ready on 9000 and nothing listens on 9001"

s3probe default-credentials || die "3: the default login was not refused"
ok "3: a request signed with the default login is refused"

s3probe objects || die "4: object round trips failed"
ok "4: 1 KiB, 10 MiB and multipart 100 MiB round trips match, 1,100 keys list across pages, delete empties the bucket"

crash_log=$scratch/crash.log
s3probe crash >"$crash_log" 2>&1 &
writer=$!
poll 120 grep -q 'probe: writing' "$crash_log" || die "5: the writer never started"
main kill rustfs >/dev/null 2>&1
sleep 2
main start rustfs >/dev/null 2>&1
if ! wait "$writer"; then
  cat "$crash_log" >&2
  die "5: an acknowledged write was lost or a listed key is unreadable after a kill"
fi
writer=
ok "5: $(grep -o '[0-9]* acknowledged writes survived' "$crash_log") a kill and restart, and every listed key is readable"

s3probe cleanup || die "6: the probe bucket could not be removed"
ok "6: probe bucket removed"
