#!/bin/sh
# S3 checks against RustFS, run inside the aws-cli image with the stack's own
# key in the environment. tools/rustfs-probe.sh and tools/smoke.sh pick the
# subcommand. The SDK's default request checksums stay on throughout, since
# those are what S3-compatible stores most often get wrong.
set -eu

bucket=o11y-probe
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "probe: $*" >&2
  exit 1
}

# Two hashes that both failed would compare equal, so a failure stops the
# probe.
sha() {
  sum=$(sha256sum "$1") || fail "$1 could not be hashed"
  echo "${sum%% *}"
}

# Puts a file of the given size and requires the same bytes back.
round_trip() {
  key=$1 size=$2
  shift 2
  head -c "$size" /dev/urandom >"$work/$key"
  "$@" "$work/$key" "s3://$bucket/$key" >/dev/null
  aws s3api get-object --bucket "$bucket" --key "$key" "$work/$key.back" >/dev/null
  sent=$(sha "$work/$key")
  back=$(sha "$work/$key.back")
  [ "$back" = "$sent" ] || fail "$key came back with different content"
  rm -f "$work/$key" "$work/$key.back"
}

# list_keys <bucket> [prefix]: writes every key, one per line, to $work/keys.
# Text output prints one line per listing page, and "None" for an empty one.
# A listing that fails stops the probe: it must never read as an empty
# bucket.
list_keys() {
  aws s3api list-objects-v2 --bucket "$1" --prefix "${2:-}" --query 'Contents[].Key' --output text \
    >"$work/listing" || fail "listing $1 failed"
  tr '\t' '\n' <"$work/listing" | { grep -vx -e None -e '' || true; } >"$work/keys"
}

# Every key listed under crash/ must be readable.
read_listed_keys() {
  list_keys "$bucket" crash/
  while read -r key; do
    aws s3api get-object --bucket "$bucket" --key "$key" "$work/back" >/dev/null ||
      fail "listed key $key is unreadable"
  done <"$work/keys"
}

case ${1:-} in
# A request signed with the RustFS default login must be refused as an
# unknown access key, which RustFS answers with 403 InvalidAccessKeyId,
# while the same request with the generated key succeeds. Matching the
# error code keeps an outage from passing as a refusal.
default-credentials)
  aws s3api list-buckets >/dev/null || fail "the generated key was refused"
  if AWS_ACCESS_KEY_ID=rustfsadmin AWS_SECRET_ACCESS_KEY=rustfsadmin aws s3api list-buckets >"$work/out" 2>&1; then
    fail "the default login was accepted"
  fi
  grep -q 'An error occurred (InvalidAccessKeyId)' "$work/out" ||
    fail "the default login failed, but not as an unknown access key"
  ;;

objects)
  aws s3api create-bucket --bucket "$bucket" >/dev/null
  round_trip 1k 1024 aws s3 cp --only-show-errors
  round_trip 10m 10485760 aws s3 cp --only-show-errors
  # 100 MiB is far above the CLI's 8 MiB threshold, so this is multipart.
  head -c 104857600 /dev/urandom >"$work/100m"
  aws s3 cp --only-show-errors "$work/100m" "s3://$bucket/100m"
  etag=$(aws s3api head-object --bucket "$bucket" --key 100m --query ETag --output text)
  case $etag in *-*) ;; *) fail "the 100 MiB upload was not multipart" ;; esac
  aws s3api get-object --bucket "$bucket" --key 100m "$work/100m.back" >/dev/null
  sent=$(sha "$work/100m")
  back=$(sha "$work/100m.back")
  [ "$back" = "$sent" ] || fail "100m came back with different content"
  rm -f "$work/100m" "$work/100m.back"

  # More keys than one listing page holds. A store that truncates the
  # first page without a continuation token breaks Tempo's block poller.
  mkdir "$work/many"
  i=1
  while [ "$i" -le 1100 ]; do
    echo "$i" >"$work/many/$i"
    i=$((i + 1))
  done
  aws s3 cp --only-show-errors --recursive "$work/many" "s3://$bucket/many/"
  # Paged by hand, so the CLI cannot hide a missing token by paging itself.
  page() {
    query=$1
    shift
    aws s3api list-objects-v2 --bucket "$bucket" --prefix many/ --no-paginate --max-keys 1000 \
      --query "$query" --output text "$@"
  }
  token=$(page NextContinuationToken)
  [ -n "$token" ] && [ "$token" != None ] || fail "the first listing page has no continuation token"
  first=$(page 'length(Contents)')
  second=$(page 'length(Contents)' --continuation-token "$token")
  [ "$first" = 1000 ] && [ "$second" = 100 ] || fail "listed $first and then $second keys, not 1000 and 100"
  last=$(page NextContinuationToken --continuation-token "$token")
  [ "$last" = None ] || fail "the last listing page is truncated"

  aws s3 rm --only-show-errors --recursive "s3://$bucket/"
  list_keys "$bucket"
  [ ! -s "$work/keys" ] || fail "keys remain after deleting everything"
  ;;

# Writes until the store goes away, which the caller arranges by killing
# RustFS mid-loop, then waits for it to return and requires every write it
# acknowledged to be intact and every listed key to be readable.
crash)
  export AWS_MAX_ATTEMPTS=1
  acked=$work/acked
  : >"$acked"
  i=1
  while :; do
    [ "$i" -le 2000 ] || fail "the store never went away"
    head -c 4096 /dev/urandom >"$work/obj"
    if aws s3api put-object --bucket "$bucket" --key "crash/$i" --body "$work/obj" \
      --cli-connect-timeout 2 --cli-read-timeout 5 >/dev/null 2>&1; then
      sent=$(sha "$work/obj")
      echo "$i $sent" >>"$acked"
      # The caller waits for this line before it kills the store.
      [ "$i" -ne 5 ] || echo "probe: writing"
    else
      break
    fi
    i=$((i + 1))
  done
  [ -s "$acked" ] || fail "no write was acknowledged before the store went away"

  tries=0
  until aws s3api list-buckets --cli-connect-timeout 2 >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -le 90 ] || fail "the store did not come back"
    sleep 2
  done

  while read -r n want; do
    aws s3api get-object --bucket "$bucket" --key "crash/$n" "$work/back" >/dev/null ||
      fail "acknowledged key crash/$n is unreadable"
    back=$(sha "$work/back")
    [ "$back" = "$want" ] || fail "acknowledged key crash/$n has different content"
  done <"$acked"
  read_listed_keys
  # shellcheck disable=SC2312 # the count is only reported
  echo "probe: $(wc -l <"$acked") acknowledged writes survived"
  ;;

cleanup)
  aws s3 rb --force "s3://$bucket" >/dev/null
  ;;

# Prints the number of objects in a bucket.
count)
  list_keys "$2"
  wc -l <"$work/keys" | tr -d ' '
  ;;

# The listing half of the crash check on its own.
listed-keys)
  read_listed_keys
  ;;

delete-bucket)
  aws s3 rb "s3://$2" >/dev/null
  ;;

# Prints each bucket with its creation time, one per line.
buckets)
  aws s3api list-buckets --query 'Buckets[].[Name,CreationDate]' --output text
  ;;

*)
  fail "unknown subcommand: ${1:-}"
  ;;
esac
