#!/usr/bin/env bash
# Renders a release: content-addressed copies of each config directory plus
# the Compose files and the env file that points Compose at them.
#
#   tools/render.sh <outdir> [--config-root <absolute path>]
#
# Writes <outdir>/config/<name>-<sha12>/ for each directory under config/ and
# <outdir>/release/ with the three Compose files and a .env. The env file
# names each config directory under --config-root, which defaults to
# <outdir>/config and is the remote config directory for a deploy. An edited
# config renders to a new directory name, so `up -d` recreates only the
# service that mounts it.
#
# The release also gets .env.validate, the same file with the S3 env file
# pointed at a dummy beside it, so the Compose model loads on a machine that
# has no generated secrets. Rendered output never holds a credential. Each
# directory carries a MANIFEST.sha256 for an upload to verify.
#
# Config files may carry @O11Y_DISK_RESERVE_GB@ and @O11Y_DISK_RESERVE_BYTES@,
# which become the disk reserve deploy enforces (O11Y_DISK_RESERVE_GB, 50 GiB
# when unset), and lines between two `# @O11Y_ALERT_EMAIL@` markers, which
# are kept when O11Y_ALERT_EMAIL_TO is set and dropped when it isn't. The
# directory name hashes the files after that, so a changed reserve or a
# change to email renders a new one.
#
# Email needs O11Y_ALERT_SMTP_HOST, _PORT, _USER and _FROM as well, and
# they go to the env file only then. O11Y_ALERT_SMTP_SKIP_VERIFY is for the
# boot test's stub alone.
#
# Needs no Docker and no network. Never add `set -x`: the env file holds
# deployment paths.
set -euo pipefail
umask 077

required=(O11Y_DATA_DIR O11Y_GRAFANA_ROOT_URL)
optional=(O11Y_GRAFANA_PORT O11Y_OTLP_GRPC_PORT O11Y_OTLP_HTTP_PORT O11Y_SECRETS_OWNER O11Y_CLUSTER O11Y_HOST_NAME O11Y_ENVIRONMENT)

usage() {
  echo "usage: render.sh <outdir> [--config-root <absolute path>]" >&2
  exit 2
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

[[ $# -ge 1 ]] || usage
outdir=$1
shift
config_root=
while [[ $# -gt 0 ]]; do
  case $1 in
  --config-root)
    [[ $# -ge 2 ]] || usage
    config_root=$2
    shift 2
    ;;
  *) usage ;;
  esac
done

missing=0
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "render: $name is not set" >&2
    missing=1
  fi
done
[[ $missing -eq 0 ]] || exit 1
reserve_gb=${O11Y_DISK_RESERVE_GB:-50}
# No leading zero, as nas.sh requires, so both read the same number.
if [[ ! $reserve_gb =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
  echo "render: O11Y_DISK_RESERVE_GB must be a whole number of GiB, with no leading zero" >&2
  exit 1
fi
reserve_bytes=$((reserve_gb * 1073741824))

# Email is on only with a recipient, and then every SMTP setting must hold.
# A message names the variable, never its value.
email=()
if [[ -n ${O11Y_ALERT_EMAIL_TO:-} ]]; then
  # Plain characters only: the env file holds them unquoted.
  address='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$'
  label='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
  bad() {
    echo "render: $1" >&2
    missing=1
  }
  [[ $O11Y_ALERT_EMAIL_TO =~ $address ]] || bad "O11Y_ALERT_EMAIL_TO must be one email address"
  [[ ${O11Y_ALERT_SMTP_HOST:-} =~ ^$label(\.$label)*$ ]] || bad "O11Y_ALERT_SMTP_HOST must be a host name, since O11Y_ALERT_EMAIL_TO is set"
  if [[ ! ${O11Y_ALERT_SMTP_PORT:-} =~ ^[1-9][0-9]{0,4}$ ]] || ((O11Y_ALERT_SMTP_PORT > 65535)); then
    bad "O11Y_ALERT_SMTP_PORT must be a port from 1 to 65535, since O11Y_ALERT_EMAIL_TO is set"
  fi
  [[ ${O11Y_ALERT_SMTP_USER:-} =~ ^[A-Za-z0-9._%+@-]+$ ]] ||
    bad "O11Y_ALERT_SMTP_USER must be a login of letters, digits and ._%+@-, since O11Y_ALERT_EMAIL_TO is set"
  [[ ${O11Y_ALERT_SMTP_FROM:-} =~ $address ]] || bad "O11Y_ALERT_SMTP_FROM must be one email address, since O11Y_ALERT_EMAIL_TO is set"
  [[ ${O11Y_ALERT_SMTP_SKIP_VERIFY:-false} =~ ^(true|false)$ ]] || bad "O11Y_ALERT_SMTP_SKIP_VERIFY must be true or false"
  [[ $missing -eq 0 ]] || exit 1
  email=(O11Y_ALERT_EMAIL_TO O11Y_ALERT_SMTP_HOST O11Y_ALERT_SMTP_PORT O11Y_ALERT_SMTP_USER O11Y_ALERT_SMTP_FROM)
  [[ -z ${O11Y_ALERT_SMTP_SKIP_VERIFY:-} ]] || email+=(O11Y_ALERT_SMTP_SKIP_VERIFY)
  email_lines='/# @O11Y_ALERT_EMAIL@ /d'
else
  email_lines='/# @O11Y_ALERT_EMAIL@ begin/,/# @O11Y_ALERT_EMAIL@ end/d'
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$outdir/config"
outdir=$(cd "$outdir" && pwd)
[[ -n $config_root ]] || config_root=$outdir/config
[[ $config_root == /* ]] || usage

# manifest <dir>: sha256sum-format lines for every file in it, sorted.
manifest() {
  (
    cd "$1"
    find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | while IFS= read -r file; do
      sum=$(sha256 <"$file") || exit 1
      printf '%s  %s\n' "$sum" "$file"
    done
  )
}

release=$outdir/release
rm -rf "$release"
mkdir "$release"
cp "$root/compose.yaml" "$root/compose.init.yaml" "$root/compose.tools.yaml" "$release/"
printf 'AWS_ACCESS_KEY_ID=dummy-not-a-secret\nAWS_SECRET_ACCESS_KEY=dummy-not-a-secret\n' >"$release/dummy-s3.env"

{
  for name in "${required[@]}"; do
    printf '%s=%s\n' "$name" "${!name}"
  done
  for name in "${optional[@]}"; do
    [[ -z ${!name:-} ]] || printf '%s=%s\n' "$name" "${!name}"
  done
  for name in ${email[@]+"${email[@]}"}; do
    printf '%s=%s\n' "$name" "${!name}"
  done
  [[ ${#email[@]} -eq 0 ]] || echo O11Y_ALERT_SMTP_ENABLED=true
  for dir in "$root"/config/*/; do
    name=$(basename "$dir")
    copy=$outdir/config/.incoming-$name
    rm -rf "$copy"
    cp -R "$dir" "$copy"
    # grep exits 1 when no file has a token, 2 when it can't search.
    files=$(grep -rlF '@O11Y_' "$copy") || [[ $? -eq 1 ]] || exit 1
    for file in $files; do
      sed -e "s/@O11Y_DISK_RESERVE_GB@/$reserve_gb/g" -e "s/@O11Y_DISK_RESERVE_BYTES@/$reserve_bytes/g" \
        -e "$email_lines" "$file" >"$file.new"
      mv "$file.new" "$file"
    done
    lines=$(manifest "$copy")
    target=$name-$(sha256 <<<"$lines" | cut -c1-12)
    if [[ -d $outdir/config/$target ]]; then
      rm -rf "$copy"
    else
      mv "$copy" "$outdir/config/$target"
      echo "$lines" >"$outdir/config/$target/MANIFEST.sha256"
      # Containers running as other users read these after a transfer.
      chmod -R u=rwX,go=rX "$outdir/config/$target"
    fi
    # shellcheck disable=SC2312 # tr over a word doesn't fail
    printf 'O11Y_CONFIG_%s=%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$name")" "$config_root/$target"
  done
} >"$release/.env.validate"

# Compose resolves a relative env_file against the directory of the Compose
# file, so the dummy is found wherever the release ends up.
cp "$release/.env.validate" "$release/.env"
echo "O11Y_S3_ENV_FILE=dummy-s3.env" >>"$release/.env.validate"
echo "O11Y_S3_ENV_FILE=$O11Y_DATA_DIR/secrets/s3.env" >>"$release/.env"
manifest "$release" >"$release/MANIFEST.sha256"
