#!/usr/bin/env bats
# tools/check-curl-fail.sh on small scripts: a curl whose body something
# reads must use --fail, or report its status through -w, or be allowed with
# a reason.

setup() {
  dir=$(mktemp -d)
  check="$BATS_TEST_DIRNAME/check-curl-fail.sh"
}

teardown() {
  rm -rf "$dir"
}

# script <lines...>: writes the lines to $dir/t.sh.
script() {
  printf '%s\n' '#!/usr/bin/env bash' "$@" >"$dir/t.sh"
}

@test "a curl piped into jq without --fail fails and names the line" {
  script 'x=1' 'curl -s "$url" | jq -r .uid'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:3: curl output is read without --fail"* ]]
}

@test "a curl inside a command substitution without --fail fails" {
  script 'body=$(curl -sS -m 15 "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a curl inside a test fails, the way a remote smoke check once passed on a timed-out curl" {
  script '[[ $(curl -sS -m 15 "$url" | jq -r .redirectUri) == /d/* ]] || exit 1'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a pipe continued on the next line still counts" {
  script 'curl -sS -m 10 http://mimir:8080/metrics |' "  awk '{ n += \$NF } END { print n + 0 }'"
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:2:"* ]]
}

@test "arguments continued with a backslash still count" {
  script 'curl -s -m 15 "$url" \' '  --data "query=up" | jq -r .status'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "-f, --fail, --fail-with-body and a bundle with f pass" {
  script 'a=$(curl -f "$url")' 'b=$(curl --fail "$url")' 'c=$(curl --fail-with-body "$url")' 'curl -fsSL "$url" | sh'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a status code read through -w passes" {
  script "code=\$(curl -s -o /dev/null -w '%{http_code}' -m 10 \"\$url\")"
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "a curl whose output nothing reads passes" {
  script 'curl -s -o "$file" "$url"' 'curl -s "$url" >/dev/null' 'curl -s "$url" || true'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "an -f that belongs to the next command does not count" {
  script "sum=\$(curl -sSL \"\$url\" | cut -d' ' -f1)"
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "names that merely contain curl pass" {
  script 'curl_cmd=(curl)' 'x=$(bash tools/nas.sh in-network-curl "$id" | jq .)' 'O11Y_CHECK_CURL=curl tools/receipt.sh'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "an allow comment with a reason exempts the next command only" {
  script '# lint-curl: allow the body is an error page we assert on' 'body=$(curl -s "$url")' 'again=$(curl -s "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:4:"* ]]
  [[ $output != *"t.sh:3:"* ]]
}

@test "an allow comment without a reason exempts nothing" {
  script '# lint-curl: allow' 'body=$(curl -s "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}
