#!/usr/bin/env bats
# tools/check-curl-fail.sh on small scripts: every curl carries a fail
# option as an argument of its own, or an allow comment with a reason on the
# line before.

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

@test "a curl piped into jq without a fail option fails and names the line" {
  script 'x=1' 'curl -s "$url" | jq -r .uid'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:3: curl without a fail option"* ]]
}

@test "a curl inside a command substitution fails" {
  script 'body=$(curl -sS -m 15 "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a curl on its own line inside a multi-line substitution fails" {
  script 'body=$(' '  curl -sS -m 15 "$url" |' '    jq -r .status' ')'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:3:"* ]]
}

@test "a curl in a function whose output is captured later fails" {
  script 'fetch() {' '  curl -s "$1"' '}' 'body=$(fetch "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:3:"* ]]
}

@test "a curl that writes a file jq reads afterwards fails" {
  script 'curl -s "$url" >"$out"' 'jq -r .status "$out"'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "a fail option on a continued line counts, and its absence still fails" {
  script 'curl -s -m 15 "$url" \' '  -f | jq -r .status' 'curl -s -m 15 "$url" \' '  --data "q=up" | jq -r .status'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "$dir/t.sh:4: curl without a fail option; add -f, or put # lint-curl: allow <reason> on the line before" ]
}

@test "-f, --fail, --fail-with-body, a bundle with f and a quoted '--fail' pass" {
  script 'a=$(curl -f "$url")' 'b=$(curl --fail "$url")' 'c=$(curl --fail-with-body "$url")' 'curl -fsSL "$url" | sh' "d=\$(curl '--fail' \"\$url\")" 'e="$(curl -s "--fail" "$url")"'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--fail inside a quoted header is not a fail option" {
  script "curl -s -H 'X-Mode: --fail ' \"\$url\" | jq ."
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "%{http_code} inside a URL exempts nothing" {
  script 'curl -s "$url/%{http_code}" | jq .'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "-w '%{http_code}' alone exempts nothing; it takes an allow comment" {
  script "code=\$(curl -s -o /dev/null -w '%{http_code}' \"\$url\")"
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "an -f that belongs to the next command does not count" {
  script "sum=\$(curl -sSL \"\$url\" | cut -d' ' -f1)"
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}

@test "names that merely contain curl, and curl inside a quoted string, pass" {
  script 'x=$(bash tools/nas.sh in-network-curl "$id" | jq .)' 'O11Y_CHECK_CURL=curl tools/receipt.sh' 'remote "docker exec -i $id curl -s $url"'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 0 ]
}

@test "an apostrophe in a comment or a heredoc doesn't hide the next curl" {
  script "# it doesn't matter" 'cat <<EOF' "it's text" 'EOF' 'curl -s "$url" | jq .'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [[ $output == "$dir/t.sh:6:"* ]]
}

@test "an allow comment with a reason exempts the next command only" {
  script '# lint-curl: allow the body is an error page we assert on' 'body=$(curl -s "$url")' 'again=$(curl -s "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "$dir/t.sh:4: curl without a fail option; add -f, or put # lint-curl: allow <reason> on the line before" ]
}

@test "an allow comment without a reason exempts nothing" {
  script '# lint-curl: allow' 'body=$(curl -s "$url")'
  run bash "$check" "$dir/t.sh"
  [ "$status" -eq 1 ]
}
