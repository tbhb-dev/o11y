#!/usr/bin/env bash
# Print the devtools release tag the manifest pins, for example v0.10.0.
# Exactly one active (uncommented) bare devtools dependency must exist and
# its whole ref must be a plain vX.Y.Z tag, so a commented older pin never
# wins and a prerelease is rejected rather than truncated.
#
# Usage: devtools-pin.sh [manifest]   (default: apm.yml)
set -euo pipefail

manifest=${1:-apm.yml}
refs=$(grep -vE '^[[:space:]]*#' "$manifest" | grep -oE 'tbhb-dev/devtools#[^[:space:]"]+' || true)

if [[ -z $refs ]]; then
  echo "no active devtools pin found in $manifest" >&2
  exit 1
fi
if [[ $(printf '%s\n' "$refs" | wc -l) -ne 1 ]]; then
  echo "expected one active devtools pin in $manifest, found several" >&2
  exit 1
fi

ref=${refs#*#}
if [[ ! $ref =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "devtools pin '$ref' in $manifest is not a plain vX.Y.Z tag" >&2
  exit 1
fi
printf '%s\n' "$ref"
