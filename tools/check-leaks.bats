#!/usr/bin/env bats
# The leak check against throwaway repositories. Every sample is built at
# run time from made-up values, so no real private value appears in this
# file, and the real O11Y_* environment is cleared before each case.
# cspell:ignore compgen gpgsign btrfs servicesx

setup() {
  checker="$BATS_TEST_DIRNAME/check-leaks.sh"
  # The scheme separator, kept out of the source so a search for it finds only real uses.
  op_slashes=/
  repo_root=$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)

  unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  unset PRE_COMMIT_FROM_REF PRE_COMMIT_TO_REF GITHUB_ACTIONS
  for name in $(compgen -v O11Y_); do unset "$name"; done

  export O11Y_SSH_HOST=zebra-host-01
  export O11Y_REMOTE_DIR=/zq/stash/dir
  export O11Y_REMOTE_TAILSCALE=/zq/bin/tsc
  export O11Y_TAILNET_DOMAIN=quokka-pond.ts.net
  export O11Y_NODE_ADDR=203.0.113.77
  export O11Y_PRIVATE_STRINGS="kestrel99, mango-secret"

  work=$(mktemp -d)
  cd "$work" || exit 1
  git init -q -b main .
  git config user.name tester
  git config user.email tester@example.invalid
  git config commit.gpgsign false
  git config tag.gpgsign false
  git config core.hooksPath /dev/null
  printf '%s\n' ignored.txt >.gitignore
  git add .gitignore
  git commit -q -m "chore: start"
  base=$(git rev-parse HEAD)
}

teardown() {
  rm -rf "$work"
}

# no_value: the output must not carry the value anywhere.
no_value() {
  [[ $output != *"$1"* ]]
}

# Every made-up value the cases plant. run_check asserts after each run
# that none of them appears in the output, so redaction is tested in every
# case, not only in the ones that remember to.
secrets=(zebra-host-01 /zq/stash/dir /zq/bin/tsc quokka-pond 203.0.113.77 kestrel99
  mango-secret 10.1.2.3 100.100.1.2 100.64.0.9 100.127.255.1 fd7a:115c:a1e0
  172.16.0.5 172.31.9.9 192.168.1.1 other-example box.other-net foo.ts.net)

no_secrets() {
  local v
  for v in "${secrets[@]}"; do
    if [[ $output == *"$v"* ]]; then
      echo "the output repeats a planted value (index of it: ${v:0:3}...)" >&2
      return 1
    fi
  done
}

run_check() {
  run bash "$checker" "$@"
  no_secrets
}

@test "a clean tree passes silently" {
  echo "nothing private here" >clean.md
  git add clean.md
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a hit for each leak-checked variable names the variable, not the value" {
  local pairs=(
    "O11Y_SSH_HOST|zebra-host-01"
    "O11Y_REMOTE_DIR|/zq/stash/dir"
    "O11Y_REMOTE_TAILSCALE|/zq/bin/tsc"
    "O11Y_TAILNET_DOMAIN|quokka-pond.ts.net"
    "O11Y_NODE_ADDR|203.0.113.77"
    "O11Y_PRIVATE_STRINGS entry 1|kestrel99"
    "O11Y_PRIVATE_STRINGS entry 2|mango-secret"
  )
  local pair name value
  for pair in "${pairs[@]}"; do
    name=${pair%%|*}
    value=${pair#*|}
    printf 'line one\nsee %s here\n' "$value" >leak.md
    git add leak.md
    run_check
    [ "$status" -eq 1 ]
    [[ $output == *"leak.md:2: private literal $name"* ]]
    no_value "$value"
  done
}

@test "the first label of the tailnet domain is checked on its own" {
  echo "ssh quokka-pond" >leak.md
  git add leak.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: private literal O11Y_TAILNET_DOMAIN (first label)"* ]]
  no_value "quokka-pond"
}

@test "literals match regardless of case" {
  echo "Host ZEBRA-Host-01" >leak.md
  git add leak.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: private literal O11Y_SSH_HOST"* ]]
  no_value "ZEBRA-Host-01"
}

@test "a value under four characters is skipped with a warning" {
  export O11Y_PRIVATE_STRINGS="ab,kestrel99"
  echo "ab is everywhere, abc too" >short.md
  git add short.md
  run_check
  [ "$status" -eq 0 ]
  [[ $output == *"O11Y_PRIVATE_STRINGS entry 1 is under 4 characters and is skipped"* ]]
}

@test "an empty private-strings list works" {
  export O11Y_PRIVATE_STRINGS=""
  echo "fine" >ok.md
  git add ok.md
  run_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo "zebra-host-01" >leak.md
  git add leak.md
  run_check
  [ "$status" -eq 1 ]
}

@test "each static pattern is a finding that prints no text" {
  local cases=(
    "op:$op_slashes/vault/item/field|password-manager reference"
    "ssh box.other-net.ts.net|tailnet host name"
    "peer 100.100.1.2 up|tailnet address"
    "peer 100.64.0.9 up|tailnet address"
    "peer 100.127.255.1 up|tailnet address"
    "addr fd7a:115c:a1e0::1|tailnet address"
    "gw 10.1.2.3|private IPv4 address"
    "gw 172.16.0.5|private IPv4 address"
    "gw 172.31.9.9|private IPv4 address"
    "gw 192.168.1.1|private IPv4 address"
    "dir /volume1/docker/x|NAS path"
    "dir /volume12/x|NAS path"
    "dir /var/services/web|NAS path"
    "bin /var/packages/Tailscale/target|NAS path"
  )
  local item text why
  unset O11Y_SSH_HOST O11Y_REMOTE_DIR O11Y_REMOTE_TAILSCALE O11Y_TAILNET_DOMAIN O11Y_NODE_ADDR
  for item in "${cases[@]}"; do
    text=${item%%|*}
    why=${item#*|}
    echo "$text" >leak.md
    git add leak.md
    run_check
    [ "$status" -eq 1 ]
    [[ $output == *"leak.md:1: pattern: $why"* ]]
    no_value "${text#* }"
  done
}

@test "addresses and paths outside the private shapes pass" {
  export O11Y_NODE_ADDR="" O11Y_PRIVATE_STRINGS=""
  printf '%s\n' "doc 192.0.2.10 and 198.51.100.4" "pub 100.63.0.1 and 100.128.0.1" \
    "pub 172.15.0.1 and 172.32.0.1 and 11.1.2.3" "dir /srv/o11y and /volume/x" >ok.md
  git add ok.md
  run_check
  [ "$status" -eq 0 ]
}

@test "example.ts.net and its subdomains are exempt, other tailnet names are not" {
  printf '%s\n' "https://grafana.example.ts.net and example.ts.net" >ok.md
  git add ok.md
  run_check
  [ "$status" -eq 0 ]
  echo "other-example.ts.net" >leak.md
  git add leak.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: pattern: tailnet host name"* ]]
}

@test "the owner-allowed Synology wording passes and a volume path fails" {
  echo "Synology DSM 7, Container Manager, btrfs, kernel 4.4" >ok.md
  git add ok.md
  run_check
  [ "$status" -eq 0 ]
  echo "mount /volume1/shared" >leak.md
  git add leak.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: pattern: NAS path"* ]]
}

@test "vendored trees are exempt from patterns but not from literals" {
  mkdir -p .devtools .claude/skills .vale .config/mise/conf.d tools
  local dir
  for dir in .devtools .claude/skills .vale .config/mise/conf.d; do
    echo "see 10.1.2.3 and op:$op_slashes/a/b/c and /volume1/x" >"$dir/vendored.md"
  done
  echo "pattern 10.1.2.3" >tools/check-leaks.bats
  git add -A
  run_check
  [ "$status" -eq 0 ]
  echo "host zebra-host-01" >.devtools/literal.md
  git add -A
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *".devtools/literal.md:1: private literal O11Y_SSH_HOST"* ]]
}

@test "--staged catches a private value staged while the working file is clean" {
  echo "zebra-host-01" >leak.md
  git add leak.md
  : >leak.md
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: private literal O11Y_SSH_HOST"* ]]
  no_value "zebra-host-01"
  # The tree scan reads the working file, so it is the staged scan that matters.
  run_check
  [ "$status" -eq 0 ]
}

@test "--staged ignores a private value that is only in the working file" {
  echo "fine" >leak.md
  git add leak.md
  echo "zebra-host-01" >leak.md
  run_check --staged
  [ "$status" -eq 0 ]
  run_check
  [ "$status" -eq 1 ]
}

@test "--staged scans only staged changes" {
  echo "zebra-host-01" >old.md
  git add old.md
  git commit -q -m "chore: old"
  echo "fine" >new.md
  git add new.md
  run_check --staged
  [ "$status" -eq 0 ]
}

@test "untracked files count, ignored files do not" {
  echo "zebra-host-01" >ignored.txt
  run_check
  [ "$status" -eq 0 ]
  echo "zebra-host-01" >untracked.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"untracked.md:1:"* ]]
  [[ $output != *"ignored.txt"* ]]
}

@test "a tracked file deleted from the working tree does not break the scan" {
  echo "fine" >gone.md
  git add gone.md
  git commit -q -m "chore: gone"
  rm gone.md
  run_check
  [ "$status" -eq 0 ]
}

@test "binary files are searched as raw bytes, staged and in a range" {
  printf 'head\000zebra-host-01\000tail' >blob.bin
  printf '\000gw 10.1.2.3\000' >net.bin
  git add blob.bin net.bin
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output == *"blob.bin:binary: private literal O11Y_SSH_HOST"* ]]
  [[ $output == *"net.bin:binary: pattern: private IPv4 address"* ]]
  git commit -q -m "chore: add binaries"
  run_check --range "$base..HEAD"
  [ "$status" -eq 1 ]
  [[ $output == *"blob.bin:binary: private literal O11Y_SSH_HOST"* ]]
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"blob.bin:binary: private literal O11Y_SSH_HOST"* ]]
}

@test "a clean binary file passes" {
  printf 'head\000tail\001' >blob.bin
  git add blob.bin
  run_check --staged
  [ "$status" -eq 0 ]
}

@test "--range catches a private value in an added line" {
  echo "fine" >a.md
  git add a.md
  git commit -q -m "chore: add a"
  printf 'fine\nline two zebra-host-01\n' >a.md
  git commit -q -am "chore: edit a"
  run_check --range "$base..HEAD"
  [ "$status" -eq 1 ]
  [[ $output == *"a.md:2: private literal O11Y_SSH_HOST"* ]]
  no_value "zebra-host-01"
}

@test "--range catches a private value in a commit message" {
  echo "fine" >a.md
  git add a.md
  git commit -q -m "chore: add a" -m "the box is zebra-host-01 on the tailnet"
  run_check --range "$base..HEAD"
  [ "$status" -eq 1 ]
  [[ $output == *"message:3: private literal O11Y_SSH_HOST"* ]]
  no_value "zebra-host-01"
}

@test "--range catches a ts.net host name in a commit message" {
  echo "fine" >a.md
  git add a.md
  git commit -q -m "chore: reach foo.ts.net"
  run_check --range "$base..HEAD"
  [ "$status" -eq 1 ]
  [[ $output == *"message:1: pattern: tailnet host name"* ]]
}

@test "--range ignores removed lines and lines outside the range" {
  echo "zebra-host-01" >a.md
  git add a.md
  git commit -q -m "chore: old leak"
  old=$(git rev-parse HEAD)
  echo "fine" >a.md
  git commit -q -am "chore: clean it"
  run_check --range "$old..HEAD"
  [ "$status" -eq 0 ]
}

@test "--range reports a bad range as misuse" {
  run_check --range missing..HEAD
  [ "$status" -eq 2 ]
}

# A repository with a leaking commit on top of the base, and remotes to push
# it to: origin already has the base, second has nothing.
push_fixture() {
  git remote add origin "$work/origin.git"
  git remote add second "$work/second.git"
  git update-ref refs/remotes/origin/main "$base"
  echo "clean" >a.md
  git add a.md
  git commit -q -m "chore: clean"
  clean=$(git rev-parse HEAD)
  echo "line zebra-host-01" >b.md
  git add b.md
  git commit -q -m "chore: leaky"
  tip=$(git rev-parse HEAD)
  zero=0000000000000000000000000000000000000000
}

# pushes REMOTE LINE...: feed ref-update lines to --pre-push as git does.
pushes() {
  local remote=$1
  shift
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/tuples"
  run bash "$checker" --pre-push "$remote" <"$BATS_TEST_TMPDIR/tuples"
  no_secrets
}

@test "--pre-push scans a new branch from what the remote has" {
  push_fixture
  pushes origin "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 1 ]
  [[ $output == *"b.md:1: private literal O11Y_SSH_HOST"* ]]
  no_value "zebra-host-01"
}

@test "--pre-push skips commits the destination already has" {
  push_fixture
  git update-ref refs/remotes/origin/f "$tip"
  pushes origin "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 0 ]
}

@test "--pre-push scans in full a branch published to a remote other than the tracking one" {
  push_fixture
  git update-ref refs/remotes/origin/f "$tip"
  pushes second "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 1 ]
  [[ $output == *"b.md:1: private literal O11Y_SSH_HOST"* ]]
}

@test "--pre-push maps a push to a remote's URL back to that remote" {
  push_fixture
  git update-ref refs/remotes/origin/f "$tip"
  pushes "$work/origin.git" "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 0 ]
  pushes "$work/second.git" "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 1 ]
}

@test "--pre-push scans only what an existing remote branch lacks" {
  push_fixture
  pushes origin "refs/heads/f $tip refs/heads/f $tip"
  [ "$status" -eq 0 ]
  pushes origin "refs/heads/f $tip refs/heads/f $clean"
  [ "$status" -eq 1 ]
  pushes origin "refs/heads/f $clean refs/heads/f $base"
  [ "$status" -eq 0 ]
}

@test "--pre-push treats a remote sha it doesn't have as unknown, not as a reason to skip" {
  push_fixture
  pushes second "refs/heads/f $tip refs/heads/f 1234567890123456789012345678901234567890"
  [ "$status" -eq 1 ]
}

@test "--pre-push scans every ref in one push and ignores a deletion" {
  push_fixture
  pushes second "(delete) $zero refs/heads/gone 1234567890123456789012345678901234567890"
  [ "$status" -eq 0 ]
  pushes second "(delete) $zero refs/heads/gone 1234567890123456789012345678901234567890" \
    "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 1 ]
}

@test "--pre-push falls back to the variables prek sets" {
  push_fixture
  PRE_COMMIT_REMOTE_NAME=second PRE_COMMIT_TO_REF=$tip run_check --pre-push </dev/null
  [ "$status" -eq 1 ]
  # The remote's own refs decide what it has, not the from-ref prek reports.
  git update-ref refs/remotes/second/main "$tip"
  PRE_COMMIT_REMOTE_NAME=second PRE_COMMIT_TO_REF=$tip run_check --pre-push </dev/null
  [ "$status" -eq 0 ]
}

@test "--pre-push by hand scans what no remote has" {
  push_fixture
  run_check --pre-push </dev/null
  [ "$status" -eq 1 ]
  git update-ref refs/remotes/origin/main "$tip"
  run_check --pre-push </dev/null
  [ "$status" -eq 0 ]
}

@test "a private string in a tracked file name is a finding" {
  echo "clean content" >zebra-host-01.md
  git add zebra-host-01.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_SSH_HOST ]]
}

@test "a staged empty or binary file with a private name is a finding" {
  : >empty-zebra-host-01.txt
  printf '\000\001' >bin-kestrel99.bin
  git add empty-zebra-host-01.txt bin-kestrel99.bin
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_SSH_HOST ]]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_PRIVATE_STRINGS\ entry\ 1 ]]
  no_value "zebra-host-01"
  no_value "kestrel99"
}

@test "a directory name counts and a path pattern applies to it" {
  mkdir -p volume1 dir
  echo x >volume1/a.md
  echo x >dir/10.1.2.3.md
  git add volume1 dir
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ pattern:\ NAS\ path ]]
  [[ $output =~ path#[0-9a-f]{8}:path:\ pattern:\ private\ IPv4\ address ]]
  no_value "10.1.2.3"
}

@test "a rename that changes no line still shows its new name in a range" {
  echo "some content" >plain.md
  git add plain.md
  git commit -q -m "chore: add plain"
  before=$(git rev-parse HEAD)
  git mv plain.md zebra-host-01.md
  git commit -q -m "chore: rename"
  run_check --range "$before..HEAD"
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_SSH_HOST ]]
  no_value "zebra-host-01"
}

@test "a mode change or an empty file in a range still shows its path" {
  : >kestrel99.txt
  git add kestrel99.txt
  git commit -q -m "chore: empty file"
  run_check --range "$base..HEAD"
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_PRIVATE_STRINGS\ entry\ 1 ]]
  no_value "kestrel99"
}

@test "vendored paths skip the patterns but not the literals" {
  mkdir -p .devtools
  : >.devtools/10.1.2.3.md
  : >.devtools/zebra-host-01.md
  git add .devtools
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal ]]
  [[ $output != *"pattern"* ]]
  [[ $output != *"10.1.2.3"* ]]
}

@test "file arguments scan exactly those files" {
  echo "zebra-host-01" >leak.md
  echo "fine" >ok.md
  git add ok.md
  run_check ok.md
  [ "$status" -eq 0 ]
  run_check ok.md leak.md
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: private literal O11Y_SSH_HOST"* ]]
  [[ $output != *"ok.md:"* ]]
  run_check missing.md
  [ "$status" -eq 2 ]
}

@test "a commit message file is scanned like any file" {
  printf 'feat: add thing\n\nreaches foo.ts.net\n' >msg
  run_check msg
  [ "$status" -eq 1 ]
  [[ $output == *"msg:3: pattern: tailnet host name"* ]]
}

@test "with no private values loaded it says so and checks the patterns only" {
  for name in $(compgen -v O11Y_); do unset "$name"; done
  echo "zebra-host-01" >ok.md
  git add ok.md
  run_check
  [ "$status" -eq 0 ]
  [[ $output == *"no private values loaded"* ]]
  [[ $output == *"only the publishable patterns are checked"* ]]
  echo "op:$op_slashes/a/b/c" >leak.md
  git add leak.md
  run_check
  [ "$status" -eq 1 ]
  [[ $output == *"leak.md:1: pattern: password-manager reference"* ]]
}

@test "in GitHub Actions the static-only notice is also an annotation" {
  for name in $(compgen -v O11Y_); do unset "$name"; done
  GITHUB_ACTIONS=true run_check
  [ "$status" -eq 0 ]
  [[ $output == *"::notice title=leak check::no private values loaded"* ]]
}

@test "a partly loaded environment names the variables it could not check" {
  unset O11Y_NODE_ADDR
  run_check
  [ "$status" -eq 0 ]
  [[ $output == *"unset, so not checked: O11Y_NODE_ADDR"* ]]
}

@test "the repository's own policy text and example file raise no finding" {
  run_check "$repo_root/AGENTS.md" "$repo_root/mise.local.toml.example" "$repo_root/README.md"
  [ "$status" -eq 0 ]
  for name in $(compgen -v O11Y_); do unset "$name"; done
  run_check "$repo_root/AGENTS.md" "$repo_root/mise.local.toml.example" "$repo_root/README.md"
  [ "$status" -eq 0 ]
}

@test "an unknown option is misuse" {
  run_check --bogus
  [ "$status" -eq 2 ]
}

@test "the notice says when mise.local.toml is present but its values did not load" {
  for name in $(compgen -v O11Y_); do unset "$name"; done
  run_check
  [[ $output != *"mise.local.toml exists"* ]]
  : >mise.local.toml
  run_check
  [ "$status" -eq 0 ]
  [[ $output == *"mise.local.toml exists here but its values are not in the environment"* ]]
}

# --- the hook as git and prek run it ---------------------------------------

# hook_fixture: a repository with a bare origin, and the repository's real
# pre-push hook entry installed through prek.
hook_fixture() {
  command -v prek >/dev/null
  local entry
  entry=$(awk '/id: leaks-outgoing/ { f = 1 } f && /entry:/ { sub(/.*entry: /, ""); print; exit }' \
    "$repo_root/.pre-commit-config.yaml")
  [[ $entry == "mise run lint-leaks -- --pre-push" ]]
  entry="bash $checker --pre-push"
  git init -q --bare "$work/origin.git"
  git remote add origin "$work/origin.git"
  cat >.pre-commit-config.yaml <<YAML
---
repos:
  - repo: local
    hooks:
      - id: leaks-outgoing
        name: leak check (outgoing commits)
        entry: $entry
        language: system
        stages: [pre-push]
        always_run: true
        pass_filenames: false
YAML
  git add .pre-commit-config.yaml
  git commit -q -m "chore: hook"
  git push -q origin main 2>/dev/null
  git config --unset core.hooksPath
  prek install -t pre-push >/dev/null 2>&1
  git branch clean-branch
  git switch -q clean-branch
  echo "fine" >c.md
  git add c.md
  git commit -q -m "chore: clean"
  git switch -q -c leaky-branch main
  echo "host zebra-host-01" >l.md
  git add l.md
  git commit -q -m "chore: leaky"
}

@test "the real pre-push hook rejects a push of two refs when only one leaks, in either order" {
  hook_fixture
  run git push origin clean-branch leaky-branch
  [ "$status" -ne 0 ]
  [[ $output == *"private literal O11Y_SSH_HOST"* ]]
  no_secrets
  run git push origin leaky-branch clean-branch
  [ "$status" -ne 0 ]
  [[ $output == *"private literal O11Y_SSH_HOST"* ]]
  [ -z "$(git ls-remote origin refs/heads/clean-branch refs/heads/leaky-branch)" ]
}

@test "the real pre-push hook lets a clean push through once nothing local leaks" {
  hook_fixture
  git branch -q -D leaky-branch 2>/dev/null || { git switch -q clean-branch && git branch -q -D leaky-branch; }
  run git push origin clean-branch
  [ "$status" -eq 0 ]
  [ -n "$(git ls-remote origin refs/heads/clean-branch)" ]
}

@test "the real pre-push hook blocks a push of a clean branch while another local branch leaks" {
  hook_fixture
  run git push origin clean-branch
  [ "$status" -ne 0 ]
  [[ $output == *"private literal O11Y_SSH_HOST"* ]]
}

@test "the real pre-push hook scans an annotated tag sent with new commits" {
  hook_fixture
  git switch -q main
  git branch -q -D leaky-branch
  git tag -a -m "release for zebra-host-01" v1 main
  run git push origin clean-branch v1
  [ "$status" -ne 0 ]
  [[ $output == *"tag "*"private literal O11Y_SSH_HOST"* ]]
  no_secrets
  [ -z "$(git ls-remote origin refs/tags/v1)" ]
}

# prek skips the pre-push stage when a push brings no new commits, so a push
# of only a tag on a commit the remote already has never reaches the check.
# AGENTS.md lists this as a limit; this test keeps it from going unnoticed.
@test "known limit: prek doesn't run the pre-push stage for a tag-only push" {
  hook_fixture
  git switch -q main
  git tag -a -m "release for zebra-host-01" v1 main
  run git push origin v1
  [ "$status" -eq 0 ]
}

# --- destinations -----------------------------------------------------------

@test "a new branch sent to a remote that lacks the commit is scanned though origin has it" {
  push_fixture
  git update-ref refs/remotes/origin/main "$tip"
  pushes second "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 1 ]
  [[ $output == *"b.md:1: private literal O11Y_SSH_HOST"* ]]
}

@test "--pre-push takes the destination from the prek variables when no argument is given" {
  push_fixture
  git update-ref refs/remotes/origin/main "$tip"
  PRE_COMMIT_REMOTE_NAME=second PRE_COMMIT_TO_REF=$tip run_check --pre-push </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"b.md:1: private literal O11Y_SSH_HOST"* ]]
  PRE_COMMIT_REMOTE_NAME=origin PRE_COMMIT_TO_REF=$tip run_check --pre-push </dev/null
  [ "$status" -eq 0 ]
}

@test "a destination that matches no configured remote is assumed to have nothing" {
  push_fixture
  git update-ref refs/remotes/origin/main "$tip"
  pushes "$work/unknown.git" "refs/heads/f $tip refs/heads/f $zero"
  [ "$status" -eq 1 ]
}

@test "a local sha git can't read fails the check instead of passing it" {
  push_fixture
  pushes second "refs/heads/f 1234567890123456789012345678901234567890 refs/heads/f $zero"
  [ "$status" -eq 2 ]
  [[ $output == *"incomplete"* ]]
}

# --- tags ---------------------------------------------------------------

@test "--pre-push scans an annotated tag's message and its target" {
  push_fixture
  git update-ref refs/remotes/origin/main "$tip"
  git tag -a -m "tag for zebra-host-01" t1 "$clean"
  tag_sha=$(git rev-parse t1)
  pushes origin "refs/tags/t1 $tag_sha refs/tags/t1 $zero"
  [ "$status" -eq 1 ]
  [[ $output == *"tag "*"private literal O11Y_SSH_HOST"* ]]
  PRE_COMMIT_REMOTE_NAME=origin run_check --pre-push </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"tag "*"private literal O11Y_SSH_HOST"* ]]
}

@test "--pre-push scans a tag that points at a blob" {
  push_fixture
  git update-ref refs/remotes/origin/main "$tip"
  blob=$(echo "inside zebra-host-01" | git hash-object -w --stdin)
  git tag -a -m "clean message" tb "$blob"
  PRE_COMMIT_REMOTE_NAME=origin run_check --pre-push </dev/null
  [ "$status" -eq 1 ]
  [[ $output == *"private literal O11Y_SSH_HOST"* ]]
}

# --- merges and type changes -------------------------------------------

@test "--range scans what a merge adds beyond its parents" {
  printf 'one\ntwo\nthree\n' >m.md
  git add m.md
  git commit -q -m "chore: m"
  start=$(git rev-parse HEAD)
  git switch -q -c side
  printf 'one\ntwo\nthree\nside\n' >m.md
  git commit -q -am "chore: side"
  git switch -q main
  printf 'top\none\ntwo\nthree\n' >m.md
  git commit -q -am "chore: top"
  git merge -q --no-commit --no-ff side
  printf 'top\none\ntwo\nzebra-host-01\nthree\nside\n' >m.md
  git add m.md
  git commit -q -m "chore: merge"
  run_check --range "$start..HEAD"
  [ "$status" -eq 1 ]
  [[ $output == *"m.md:4: private literal O11Y_SSH_HOST"* ]]
}

@test "--range passes a clean merge" {
  printf 'one\n' >m.md
  git add m.md
  git commit -q -m "chore: m"
  start=$(git rev-parse HEAD)
  git switch -q -c side
  echo side >s.md
  git add s.md
  git commit -q -m "chore: side"
  git switch -q main
  echo top >t.md
  git add t.md
  git commit -q -m "chore: top"
  git merge -q --no-ff -m "chore: merge" side
  run_check --range "$start..HEAD"
  [ "$status" -eq 0 ]
}

@test "a regular file replaced by a symlink to a private value is caught staged and in a range" {
  echo "plain" >l
  git add l
  git commit -q -m "chore: plain"
  before=$(git rev-parse HEAD)
  rm l
  ln -s zebra-host-01 l
  git add l
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output == *"l:1: private literal O11Y_SSH_HOST"* ]]
  git commit -q -m "chore: link"
  run_check --range "$before..HEAD"
  [ "$status" -eq 1 ]
  [[ $output == *"l:1: private literal O11Y_SSH_HOST"* ]]
}

# --- paths --------------------------------------------------------------

@test "both sides of a rename are scanned in a staged change" {
  echo "some content" >zebra-host-01.txt
  git add zebra-host-01.txt
  git commit -q -m "chore: old name"
  git mv zebra-host-01.txt clean-name.txt
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_SSH_HOST ]]
}

@test "a staged rename to a private name is caught" {
  echo "some content" >plain.txt
  git add plain.txt
  git commit -q -m "chore: plain"
  git mv plain.txt zebra-host-01.txt
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_SSH_HOST ]]
}

@test "filenames with newlines or spaces can't corrupt the scan" {
  echo x >"$(printf 'a\nzebra-host-01')"
  echo x >"clean name with spaces.md"
  echo x >"$(printf 'b\nclean')"
  git add .
  run_check --staged
  [ "$status" -eq 1 ]
  [ "$(grep -c 'private literal' <<<"$output")" -eq 1 ]
  rm -f a* b*
  git rm -q --cached -f a* b* 2>/dev/null || true
  run_check --staged
  [ "$status" -eq 0 ]
}

@test "a clean newline filename passes in tree and range modes" {
  echo x >"$(printf 'b\nclean')"
  git add .
  git commit -q -m "chore: odd name"
  run_check
  [ "$status" -eq 0 ]
  run_check --range "$base..HEAD"
  [ "$status" -eq 0 ]
}

# --- disclosure ---------------------------------------------------------

@test "a path that matches a rule is replaced by an opaque identifier" {
  echo "gw 10.1.2.3" >zebra-host-01.txt
  git add zebra-host-01.txt
  run_check --staged
  [ "$status" -eq 1 ]
  [[ $output =~ path#[0-9a-f]{8}:path:\ private\ literal\ O11Y_SSH_HOST ]]
  [[ $output =~ path#[0-9a-f]{8}:1:\ pattern:\ private\ IPv4\ address ]]
  [[ $output != *".txt"* ]]
}

@test "errors don't repeat the argument that caused them" {
  run_check missing-zebra-host-01.md
  [ "$status" -eq 2 ]
  run_check --zebra-host-01
  [ "$status" -eq 2 ]
  run_check --range zebra-host-01..HEAD
  [ "$status" -eq 2 ]
}

# --- failures -----------------------------------------------------------

@test "a corrupt index fails the staged check instead of passing it" {
  echo "fine" >a.md
  git add a.md
  echo "junk" >.git/index
  run_check --staged
  [ "$status" -eq 2 ]
  [[ $output == *"incomplete"* ]]
}

@test "outside a git repository the check fails" {
  cd "$BATS_TEST_TMPDIR"
  run_check --staged
  [ "$status" -eq 2 ]
}

# --- the NAS roots ------------------------------------------------------

@test "NAS roots match as well as the paths under them" {
  local text
  for text in "at /volume1" "at /volume1." "mount /volume2:/data" "cd /var/services" "ls /var/packages)" "/volume1/x"; do
    echo "$text" >leak.md
    git add leak.md
    run_check --staged
    [ "$status" -eq 1 ]
    [[ $output == *"leak.md:1: pattern: NAS path"* ]]
  done
}

@test "names that only start like a NAS root pass" {
  printf '%s\n' "/volume1alpha" "/var/servicesx" "/var/packages-old" "/volume" >ok.md
  git add ok.md
  run_check --staged
  [ "$status" -eq 0 ]
}

@test "an unreadable file fails the check without printing its name" {
  echo "fine" >zebra-host-01.txt
  chmod 000 zebra-host-01.txt
  run_check zebra-host-01.txt
  # A superuser can read it anyway, which leaves nothing to fail.
  [ "$status" -ne 0 ] || [ -r zebra-host-01.txt ]
}
