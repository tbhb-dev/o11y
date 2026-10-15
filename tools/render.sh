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
      printf '%s  %s\n' "$(sha256 <"$file")" "$file"
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
  for dir in "$root"/config/*/; do
    name=$(basename "$dir")
    lines=$(manifest "$dir")
    target=$name-$(sha256 <<<"$lines" | cut -c1-12)
    if [[ ! -d $outdir/config/$target ]]; then
      cp -R "$dir" "$outdir/config/$target"
      echo "$lines" >"$outdir/config/$target/MANIFEST.sha256"
      # Containers running as other users read these after a transfer.
      chmod -R u=rwX,go=rX "$outdir/config/$target"
    fi
    printf 'O11Y_CONFIG_%s=%s\n' "$(tr '[:lower:]' '[:upper:]' <<<"$name")" "$config_root/$target"
  done
} >"$release/.env.validate"

# Compose resolves a relative env_file against the directory of the Compose
# file, so the dummy is found wherever the release ends up.
cp "$release/.env.validate" "$release/.env"
echo "O11Y_S3_ENV_FILE=dummy-s3.env" >>"$release/.env.validate"
echo "O11Y_S3_ENV_FILE=$O11Y_DATA_DIR/secrets/s3.env" >>"$release/.env"
manifest "$release" >"$release/MANIFEST.sha256"
