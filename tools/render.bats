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
  unset O11Y_ALERT_EMAIL_TO O11Y_ALERT_SMTP_HOST O11Y_ALERT_SMTP_PORT O11Y_ALERT_SMTP_USER O11Y_ALERT_SMTP_FROM O11Y_ALERT_SMTP_SKIP_VERIFY
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
    grep -E '^(alloy|grafana|loki|mimir|rustfs|tempo) ' | sort)
  actual=$(jq -r '.panels[] | select(.title == "Resident memory against mem_limit") | .targets[].expr' "$dashboard" |
    sed -E -e 's#^process_resident_memory_bytes\{job="o11y/([a-z]+)"\} / ([0-9]+)$#\1 \2#' \
      -e 's#^max\(rustfs_system_process_resident_memory_bytes\{job="o11y/(rustfs)"\}\) / ([0-9]+)$#\1 \2#' | sort)
  [ "$(wc -l <<<"$expected")" -eq 6 ]
  [ "$actual" = "$expected" ]
  expected=$(awk -F'"' '/"job" = / { job = $8 } /^\tsample_limit / { sub(/.*= */, ""); print job, $0 }' "$root/config/alloy/config.alloy" | sort)
  actual=$(jq -r '.panels[] | select(.title == "Scraped samples against sample_limit") | .targets[].expr' "$dashboard" |
    sed -E 's#^scrape_samples_post_metric_relabeling\{job="(o11y/[a-z]+)"\} / ([0-9]+)$#\1 \2#' | sort)
  [ "$(wc -l <<<"$expected")" -eq 5 ]
  [ "$actual" = "$expected" ]
}

@test "the disk reserve renders into the alert rules, 50 GiB when unset, and renames only the Grafana directory" {
  unset O11Y_DISK_RESERVE_GB
  bash "$src/tools/render.sh" "$out/a"
  rules=$(echo "$out"/a/config/grafana-*/provisioning/alerting/rules.yaml)
  ! grep -q '@O11Y_' "$rules" || false
  grep -qF '< bool 53687091200)' "$rules"
  grep -qF '50 GiB or 10 percent free' "$rules"
  O11Y_DISK_RESERVE_GB=7 bash "$src/tools/render.sh" "$out/b"
  grep -qF '< bool 7516192768)' "$out"/b/config/grafana-*/provisioning/alerting/rules.yaml
  changed=$(diff <(ls "$out/a/config") <(ls "$out/b/config") | sed -n 's/^> \([a-z]*\)-.*/\1/p')
  [ "$changed" = grafana ]
}

@test "a disk reserve that isn't a whole number of GiB fails the render" {
  local reserve
  for reserve in 08 x 1.5 -1 1234567; do
    O11Y_DISK_RESERVE_GB=$reserve run bash "$src/tools/render.sh" "$out/a"
    [ "$status" -eq 1 ]
    [[ $output == *"O11Y_DISK_RESERVE_GB must be a whole number of GiB"* ]] || false
  done
}

email_on() {
  export O11Y_ALERT_EMAIL_TO=to@example.invalid O11Y_ALERT_SMTP_HOST=smtp.example.invalid O11Y_ALERT_SMTP_PORT=587
  export O11Y_ALERT_SMTP_USER=user@example.invalid O11Y_ALERT_SMTP_FROM=from@example.invalid
}

@test "with no recipient the email receiver and the SMTP settings stay out, and with one both render" {
  O11Y_ALERT_SMTP_HOST=smtp.example.invalid bash "$src/tools/render.sh" "$out/a"
  alerting=$(echo "$out"/a/config/grafana-*/provisioning/alerting/alerting.yaml)
  ! grep -qE '@O11Y_|o11y-email|type: email' "$alerting" || false
  grep -qF 'uid: o11y-discord' "$alerting"
  ! grep -q 'O11Y_ALERT_' "$out/a/release/.env" || false
  email_on
  bash "$src/tools/render.sh" "$out/b"
  alerting=$(echo "$out"/b/config/grafana-*/provisioning/alerting/alerting.yaml)
  ! grep -q '@O11Y_' "$alerting" || false
  grep -qF 'addresses: $__env{O11Y_ALERT_EMAIL_TO}' "$alerting"
  grep -qF 'uid: o11y-discord' "$alerting"
  # The recipient reaches Grafana's environment, never its config files.
  ! grep -rqF '@example.invalid' "$out"/b/config || false
  [ "$(grep '^O11Y_ALERT_' "$out/b/release/.env")" = "O11Y_ALERT_EMAIL_TO=to@example.invalid
O11Y_ALERT_SMTP_HOST=smtp.example.invalid
O11Y_ALERT_SMTP_PORT=587
O11Y_ALERT_SMTP_USER=user@example.invalid
O11Y_ALERT_SMTP_FROM=from@example.invalid
O11Y_ALERT_SMTP_ENABLED=true" ]
  changed=$(diff <(ls "$out/a/config") <(ls "$out/b/config") | sed -n 's/^> \([a-z]*\)-.*/\1/p')
  [ "$changed" = grafana ]
}

@test "a recipient without every SMTP setting fails the render, naming each missing variable and no value" {
  export O11Y_ALERT_EMAIL_TO=to@example.invalid O11Y_ALERT_SMTP_PORT=99999 O11Y_ALERT_SMTP_FROM='bad from'
  run bash "$src/tools/render.sh" "$out/a"
  [ "$status" -eq 1 ]
  [[ $output == *"O11Y_ALERT_SMTP_HOST must be a host name"* ]] || false
  [[ $output == *"O11Y_ALERT_SMTP_PORT must be a port"* ]] || false
  [[ $output == *"O11Y_ALERT_SMTP_USER must be a login"* ]] || false
  [[ $output == *"O11Y_ALERT_SMTP_FROM must be one email address"* ]] || false
  [[ $output != *"to@example.invalid"* && $output != *"bad from"* ]] || false
  email_on
  O11Y_ALERT_EMAIL_TO='to@example.invalid,other@example.invalid' run bash "$src/tools/render.sh" "$out/a"
  [ "$status" -eq 1 ]
  [[ $output == *"O11Y_ALERT_EMAIL_TO must be one email address"* ]] || false
}

# Grafana reads the webhook URL and the SMTP password from the files
# compose.yaml mounts, and the RustFS memory rule divides by the mem_limit it
# can't read at run time.
@test "Grafana reads the mounted webhook and SMTP password files, and the RustFS memory rule matches its mem_limit" {
  grep -qF 'url: $__file{/run/o11y/alert_discord_webhook_url}' "$root/config/grafana/provisioning/alerting/alerting.yaml"
  grep -qF -- '- ${O11Y_DATA_DIR:?}/secrets/alert_discord_webhook_url:/run/o11y/alert_discord_webhook_url:ro' "$root/compose.yaml"
  grep -qF -- '- ${O11Y_DATA_DIR:?}/secrets/alert_smtp_password:/run/o11y/alert_smtp_password:ro' "$root/compose.yaml"
  grep -qF 'GF_SMTP_PASSWORD__FILE: /run/o11y/alert_smtp_password' "$root/compose.yaml"
  limit=$(awk '/^  rustfs:$/ { s = 1; next } /^  [a-z0-9-]+:$/ { s = 0 } s && /^    mem_limit: / { n = $2 + 0; u = substr($2, length($2)); print n * (u == "g" ? 1073741824 : 1048576) }' "$root/compose.yaml")
  [ -n "$limit" ]
  grep -qE "rustfs_system_process_resident_memory_bytes\{job=\"o11y/rustfs\"\}\) / $limit\$" "$root/config/grafana/provisioning/alerting/rules.yaml"
}

# The first file of the first manifest fails to hash and every later call
# works, so only a manifest line can lose its checksum.
@test "a file that can't be hashed fails the render, rather than leaving its manifest line without a checksum" {
  mkdir "$out/bin"
  real=$(command -v sha256sum || true)
  {
    echo '#!/bin/sh'
    echo "[ -e '$out/bin/failed' ] || { : >'$out/bin/failed'; exit 1; }"
    if [[ -n $real ]]; then echo "exec '$real' \"\$@\""; else echo 'exec shasum -a 256 "$@"'; fi
  } >"$out/bin/sha256sum"
  chmod +x "$out/bin/sha256sum"
  PATH="$out/bin:$PATH" run bash "$src/tools/render.sh" "$out/a"
  [ "$status" -ne 0 ]
}
