#!/usr/bin/env bats
# tools/render.sh: what a release contains and how its names are derived.

setup() {
  src=$(mktemp -d)
  out=$(mktemp -d)
  root="$BATS_TEST_DIRNAME/.."
  mkdir "$src/tools"
  cp -R "$root/compose.yaml" "$root/compose.init.yaml" "$root/compose.tools.yaml" "$root/config" "$src/"
  cp "$root/tools/render.sh" "$src/tools/"
  export O11Y_DATA_DIR=/srv/o11y/data O11Y_GRAFANA_ROOT_URL=https://grafana.example.ts.net/
  unset O11Y_GRAFANA_PORT O11Y_OTLP_GRPC_PORT O11Y_OTLP_HTTP_PORT O11Y_SECRETS_OWNER O11Y_CLUSTER
}

teardown() {
  rm -rf "$src" "$out"
}

# Paths and checksums of everything rendered, relative to the output root.
listing() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$(cksum <"$file")" "$file"
  done)
}

mode() {
  if stat -c %a "$1" 2>/dev/null; then return; fi
  stat -f %Lp "$1"
}

@test "two renders of the same tree are identical" {
  run bash "$src/tools/render.sh" "$out/a" --config-root /srv/o11y/config
  [ "$status" -eq 0 ]
  bash "$src/tools/render.sh" "$out/b" --config-root /srv/o11y/config
  [ "$(listing "$out/a")" = "$(listing "$out/b")" ]
}

@test "a changed file renames only its own config directory" {
  bash "$src/tools/render.sh" "$out/a"
  echo "#" >>"$src/config/loki/config.yaml"
  bash "$src/tools/render.sh" "$out/b"
  before=$(ls "$out/a/config")
  after=$(ls "$out/b/config")
  [ "$(grep -v '^loki-' <<<"$before")" = "$(grep -v '^loki-' <<<"$after")" ]
  [ "$(grep '^loki-' <<<"$before")" != "$(grep '^loki-' <<<"$after")" ]
}

@test "an unset required variable fails and is named" {
  unset O11Y_GRAFANA_ROOT_URL
  run bash "$src/tools/render.sh" "$out/a"
  [ "$status" -eq 1 ]
  [[ $output == *O11Y_GRAFANA_ROOT_URL* ]]
  [[ $output != *O11Y_DATA_DIR* ]]
}

@test "the release is private and the config trees are world-readable" {
  bash "$src/tools/render.sh" "$out/a"
  [ "$(mode "$out/a/release")" = 700 ]
  for file in "$out/a/release"/* "$out/a/release"/.env*; do
    [ "$(mode "$file")" = 600 ]
  done
  [ "$(mode "$out/a/config")" = 700 ]
  for dir in "$out/a/config"/*/; do
    [ "$(mode "$dir")" = 755 ]
  done
  [ -z "$(find "$out/a/config" -mindepth 2 -type f ! -perm -044)" ]
  [ -z "$(find "$out/a/config" -mindepth 2 -type d ! -perm -055)" ]
}

@test "the env files name every config directory and differ only in the S3 env file" {
  bash "$src/tools/render.sh" "$out/a" --config-root /srv/o11y/config
  env=$out/a/release/.env
  for dir in "$out/a/config"/*/; do
    grep -q "=/srv/o11y/config/$(basename "$dir")\$" "$env"
  done
  grep -qx 'O11Y_S3_ENV_FILE=/srv/o11y/data/secrets/s3.env' "$env"
  grep -qx 'O11Y_S3_ENV_FILE=dummy-s3.env' "$env.validate"
  [ "$(grep -v '^O11Y_S3_ENV_FILE=' "$env")" = "$(grep -v '^O11Y_S3_ENV_FILE=' "$env.validate")" ]
}

@test "port and owner overrides reach the env file only when set" {
  bash "$src/tools/render.sh" "$out/a"
  run grep -q '^O11Y_GRAFANA_PORT=' "$out/a/release/.env"
  [ "$status" -eq 1 ]
  O11Y_GRAFANA_PORT=13000 O11Y_SECRETS_OWNER=1000:1000 bash "$src/tools/render.sh" "$out/b"
  grep -qx 'O11Y_GRAFANA_PORT=13000' "$out/b/release/.env"
  grep -qx 'O11Y_SECRETS_OWNER=1000:1000' "$out/b/release/.env"
}

@test "the cluster label reaches the env file only when set" {
  bash "$src/tools/render.sh" "$out/a"
  run grep -q '^O11Y_CLUSTER=' "$out/a/release/.env"
  [ "$status" -eq 1 ]
  O11Y_CLUSTER=site-a bash "$src/tools/render.sh" "$out/b"
  grep -qx 'O11Y_CLUSTER=site-a' "$out/b/release/.env"
}

@test "every manifest matches the files beside it" {
  bash "$src/tools/render.sh" "$out/a"
  for dir in "$out/a/release" "$out/a/config"/*/; do
    (cd "$dir" && if command -v sha256sum >/dev/null; then sha256sum -c --quiet MANIFEST.sha256; else shasum -a 256 -c MANIFEST.sha256 >/dev/null; fi)
    [ "$(wc -l <"$dir/MANIFEST.sha256")" -eq "$(find "$dir" -type f ! -name MANIFEST.sha256 | wc -l)" ]
  done
}

# The Stack health dashboard divides by each job's mem_limit and
# sample_limit, which it can't read at run time, so they are written into it.
@test "the dashboard's memory and sample limits match compose.yaml and config.alloy" {
  local dashboard=$root/config/grafana/dashboards/stack-health.json expected actual
  expected=$(awk '/^  [a-z0-9-]+:$/ { service = substr($1, 1, length($1) - 1) }
    /^    mem_limit: / { n = $2 + 0; u = substr($2, length($2)); print service, n * (u == "g" ? 1073741824 : 1048576) }' "$root/compose.yaml" |
    grep -E '^(alloy|grafana|loki|mimir|tempo) ' | sort)
  actual=$(jq -r '.panels[] | select(.title == "Resident memory against mem_limit") | .targets[].expr' "$dashboard" |
    sed -E 's#^process_resident_memory_bytes\{job="o11y/([a-z]+)"\} / ([0-9]+)$#\1 \2#' | sort)
  [ "$(wc -l <<<"$expected")" -eq 5 ]
  [ "$actual" = "$expected" ]
  expected=$(awk -F'"' '/"job" = / { job = $8 } /^\tsample_limit / { sub(/.*= */, ""); print job, $0 }' "$root/config/alloy/config.alloy" | sort)
  actual=$(jq -r '.panels[] | select(.title == "Scraped samples against sample_limit") | .targets[].expr' "$dashboard" |
    sed -E 's#^scrape_samples_post_metric_relabeling\{job="(o11y/[a-z]+)"\} / ([0-9]+)$#\1 \2#' | sort)
  [ "$(wc -l <<<"$expected")" -eq 5 ]
  [ "$actual" = "$expected" ]
}
