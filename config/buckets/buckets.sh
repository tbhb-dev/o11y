#!/bin/sh
# Creates the buckets the backends expect, with real S3 calls: a bucket also
# has metadata inside RustFS, which a bare directory lacks. Safe to repeat.
#
# For each bucket a signed HEAD decides: 200 means it exists and this key can
# use it; 404 means create it, which must return 200, and then HEAD must
# return 200. Any other answer fails the run. RustFS 1.0.1 answers a repeated
# create with 200, not 409, so the HEAD is what tells the two cases apart.
#
# The key reaches curl on stdin, never on a command line.
set -eu

# request <bucket> <curl method options...>: prints the HTTP status.
request() {
  bucket=$1
  shift
  printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" |
    curl -sS -K - -o /dev/null -w '%{http_code}' "$@" \
      --aws-sigv4 'aws:amz:us-east-1:s3' "http://rustfs:9000/$bucket"
}

for name in loki tempo mimir-blocks mimir-ruler; do
  code=$(request "$name" --head)
  case $code in
  200)
    echo "bucket $name exists"
    ;;
  404)
    code=$(request "$name" -X PUT)
    [ "$code" = 200 ] || {
      echo "bucket $name: create returned $code" >&2
      exit 1
    }
    code=$(request "$name" --head)
    [ "$code" = 200 ] || {
      echo "bucket $name: created, but HEAD returned $code" >&2
      exit 1
    }
    echo "bucket $name created"
    ;;
  *)
    echo "bucket $name: HEAD returned $code" >&2
    exit 1
    ;;
  esac
done
