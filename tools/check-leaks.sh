#!/usr/bin/env bash
# check-leaks.sh -- keep private values out of a public repository.
#
# Two rule sets run over the same text:
#
#   1. Private literals. The values of the leak-checked O11Y_* variables,
#      the first label of the tailnet domain, and each entry of
#      O11Y_PRIVATE_STRINGS, matched case-insensitively as fixed strings.
#      The values live in the gitignored mise.local.toml, so this set runs
#      only where that file is loaded.
#   2. Publishable patterns. Shapes that identify a private network
#      whatever the value: password-manager references, tailnet host
#      names, tailnet and RFC 1918 addresses, NAS path shapes. This set
#      needs no private values, so it is the only one CI can run.
#
# What is scanned: file contents (binary files too, as raw bytes), file
# paths on their own (both sides of a rename), commit messages, and the
# messages and targets of annotated tags a push would send.
#
# A finding gives a location and the variable or rule, never the matched
# text. A location that itself matches a rule, such as a path with a
# private name in it, is replaced by an opaque identifier. Error messages
# never repeat an argument.
#
# Usage:
#   check-leaks.sh                 scan the working tree: tracked files and
#                                  untracked files git does not ignore
#   check-leaks.sh --staged        scan the index blobs of staged files
#   check-leaks.sh --range A..B    scan the added lines, the paths and the
#                                  message of every commit in the range
#                                  (a merge: what it adds beyond its parents)
#   check-leaks.sh --pre-push [REMOTE]
#                                  scan what a push would send that the
#                                  destination lacks. Fed ref-update lines
#                                  on stdin, as git feeds a hook, it scans
#                                  each. prek does not pass them on, so it
#                                  scans every commit and annotated tag
#                                  reachable from any local branch or tag
#                                  that the destination's remote-tracking
#                                  refs lack. That can include local work
#                                  the push does not send; it is the narrow
#                                  set that is safe without the tuples.
#   check-leaks.sh FILE...         scan exactly those files
#
# Exit status: 0 clean, 1 findings, 2 misuse, or a git or read failure.
#
# Known limits, none of which this tries to solve: a value that is
# URL-encoded, base64-encoded or otherwise transformed is not found; a
# value split across lines is not found; a literal under four characters is
# skipped; and an entry of O11Y_PRIVATE_STRINGS cannot contain a comma.
# cspell:ignore numstat getline tolower RSTART RLENGTH ACMRT quotepath gitlinks sprintf objecttype objectname
set -euo pipefail
export LC_ALL=C

# The exit handler reports on a saved copy of stderr: bash 3.2 can run it
# while a command's own redirection of fd 2 is still in force.
exec 3>&2

# git runs quietly: its own messages can repeat a path or a ref.
git() { command git "$@" 2>/dev/null; }

# Rule set 2 skips these paths: vendored and deployed trees answer to
# their upstream, and the checker's own files spell out the patterns.
pattern_exempt='^(\.claude/|\.agents/|\.devtools/|\.config/mise/conf\.d/|\.vale/|tools/check-leaks\.(sh|bats)$)'

finished=
die() {
  echo "check-leaks: $*" >&2
  finished=1
  exit 2
}

tmp=$(mktemp -d)
# Any other early exit is a git or read failure under set -e. Say so and
# fail, so an unreadable index or object never reads as a clean result.
# shellcheck disable=SC2329 # runs through the EXIT trap below
on_exit() {
  local rc=$?
  rm -rf "$tmp"
  if [[ -z $finished && $rc -ne 0 ]]; then
    echo "check-leaks: could not read something the scan needs; the result is incomplete" >&3
    exit 2
  fi
}
trap on_exit EXIT
needles=$tmp/needles
: >"$needles"

loaded=0
notes=""

# add_needle NAME VALUE: queue one private literal. Values under four
# characters match too much to be useful, so they are skipped, loudly.
add_needle() {
  local name=$1 value=$2
  if [[ -z $value ]]; then
    return 0
  fi
  if ((${#value} < 4)); then
    echo "check-leaks: warning: $name is under 4 characters and is skipped" >&2
    return 0
  fi
  printf '%s\t%s\n' "$name" "$value" >>"$needles"
  loaded=$((loaded + 1))
}

# Variables whose whole value is private.
for name in O11Y_SSH_HOST O11Y_REMOTE_DIR O11Y_REMOTE_TAILSCALE O11Y_NODE_ADDR; do
  if [[ -z ${!name-} ]]; then
    notes="$notes $name"
  fi
  add_needle "$name" "${!name-}"
done

# The tailnet domain, and its first label on its own: the label is what
# a stray host name or URL carries.
if [[ -z ${O11Y_TAILNET_DOMAIN-} ]]; then
  notes="$notes O11Y_TAILNET_DOMAIN"
else
  add_needle O11Y_TAILNET_DOMAIN "$O11Y_TAILNET_DOMAIN"
  add_needle "O11Y_TAILNET_DOMAIN (first label)" "${O11Y_TAILNET_DOMAIN%%.*}"
fi

# The list may be empty. An empty list is a valid choice, not a gap.
IFS=',' read -r -a entries <<<"${O11Y_PRIVATE_STRINGS-}"
index=0
for entry in "${entries[@]+"${entries[@]}"}"; do
  index=$((index + 1))
  entry=${entry#"${entry%%[![:space:]]*}"}
  entry=${entry%"${entry##*[![:space:]]}"}
  add_needle "O11Y_PRIVATE_STRINGS entry $index" "$entry"
done

if ((loaded == 0)); then
  msg="no private values loaded (O11Y_* unset); only the publishable patterns are checked, so a host name, login or path outside those shapes passes"
  # On a machine that has the settings file, the values just didn't reach
  # this process. Say so, because that is a local setup mistake, not CI.
  top=$(git rev-parse --show-toplevel || true)
  if [[ -n $top && -f $top/mise.local.toml ]]; then
    msg="$msg. mise.local.toml exists here but its values are not in the environment; run the check through mise (mise run lint-leaks) so it can read them"
  fi
  echo "check-leaks: $msg" >&2
  if [[ ${GITHUB_ACTIONS-} == true ]]; then
    echo "::notice title=leak check::$msg"
  fi
elif [[ -n $notes ]]; then
  echo "check-leaks: warning: unset, so not checked:$notes" >&2
fi

# scan reads the record stream the producers write and prints findings.
# A record starting with \001 opens a file (the rest is its label), one
# starting with \002 is a path to scan as text of its own, and every other
# record is "<line number or "binary"><TAB><text>".
scan() {
  PATTERN_EXEMPT=$pattern_exempt NEEDLES=$needles awk '
    BEGIN {
      nf = ENVIRON["NEEDLES"]
      while ((getline l < nf) > 0) {
        t = index(l, "\t")
        nn++
        name[nn] = substr(l, 1, t - 1)
        needle[nn] = tolower(substr(l, t + 1))
      }
      close(nf)
      exempt = ENVIRON["PATTERN_EXEMPT"]
      for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
      # Split so a search for the literal finds only real uses of it.
      op_ref = "op:" "//"
      oct = "(25[0-5]|2[0-4][0-9]|[01]?[0-9]?[0-9])"
      dot = "\\."
      pre = "(^|[^0-9.])"
      ip10 = "10" dot oct dot oct dot oct
      ip172 = "172" dot "(1[6-9]|2[0-9]|3[01])" dot oct dot oct
      ip192 = "192" dot "168" dot oct dot oct
      ip_tailnet = "100" dot "(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])" dot oct dot oct
      re_ip = pre "(" ip10 "|" ip172 "|" ip192 ")"
      re_tailnet = pre ip_tailnet
      re_ts = "([a-z0-9-]+\\.)+ts\\.net"
      # NAS roots: the directory itself or anything under it, but not a
      # longer name that merely starts the same way.
      re_nas = "/(volume[0-9]+|var/services|var/packages)([^a-z0-9_-]|$)"
    }
    # An opaque stand-in for a location that must not be printed.
    function opaque(s,    i, h) {
      h = 5381
      for (i = 1; i <= length(s); i++) h = (h * 33 + ord[substr(s, i, 1)]) % 4294967296
      return sprintf("path#%08x", h)
    }
    function report(why) {
      if (quiet) { hits++; return }
      printf "%s:%s: %s\n", label, lineno, why
      findings++
    }
    function foreign_ts(s,    m) {
      while (match(s, re_ts)) {
        m = substr(s, RSTART, RLENGTH)
        if (m != "example.ts.net" && m !~ /\.example\.ts\.net$/) return 1
        s = substr(s, RSTART + RLENGTH)
      }
      return 0
    }
    function check(low, skip_patterns,    i) {
      for (i = 1; i <= nn; i++) {
        if (index(low, needle[i])) report("private literal " name[i])
      }
      if (skip_patterns) return
      if (index(low, op_ref)) report("pattern: password-manager reference")
      if (foreign_ts(low)) report("pattern: tailnet host name")
      if (low ~ re_tailnet || index(low, "fd7a:115c:a1e0")) report("pattern: tailnet address")
      if (low ~ re_ip) report("pattern: private IPv4 address")
      if (low ~ re_nas) report("pattern: NAS path")
    }
    # Name a location: as given, unless the name itself matches a rule.
    function locate(full,    n) {
      quiet = 1; hits = 0
      # Exemptions silence findings, never the sanitizing of a location.
      check(tolower("/" full), 0)
      quiet = 0
      return hits ? opaque(full) : full
    }
    /^\001/ { full = substr($0, 2); label = locate(full); skip = (full ~ exempt); next }
    /^\002/ {
      full = substr($0, 2)
      label = locate(full)
      lineno = "path"
      # The leading slash lets the path patterns see a top-level directory.
      check(tolower("/" full), (full ~ exempt))
      next
    }
    {
      t = index($0, "\t")
      lineno = substr($0, 1, t - 1)
      check(tolower(substr($0, t + 1)), skip)
    }
    END { if (findings) printf "check-leaks: %d finding(s); values are not printed\n", findings > "/dev/stderr"; exit findings ? 1 : 0 }
  '
}

# esc makes a path safe for the line-based record stream: git hands paths
# over NUL-delimited, and a newline or a backslash in one is escaped here.
esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# has_nul FILE: true when the file holds a NUL byte.
has_nul() {
  # fd 2 goes first so a failed open of the file can't print its name.
  (($(tr -d '\0' 2>/dev/null <"$1" | wc -c) != $(wc -c 2>/dev/null <"$1")))
}

# emit_body FILE: the file's content as numbered records. NULs become
# line breaks so a binary blob is searched as raw bytes, and its lines are
# marked "binary" because their numbers mean nothing.
emit_body() {
  local mark=
  if has_nul "$1"; then mark=binary; fi
  tr '\0' '\n' 2>/dev/null <"$1" | awk -v mark="$mark" '{ print (mark == "" ? NR : mark) "\t" $0 }'
}

# emit_path PATH: a path as text of its own.
emit_path() {
  printf '\002%s\n' "$(esc "$1")"
}

# emit_file LABEL FILE: a path and the file's content.
emit_file() {
  emit_path "$1"
  printf '\001%s\n' "$(esc "$1")"
  emit_body "$2"
}

# emit_text LABEL: stdin as records.
emit_text() {
  printf '\001%s\n' "$1"
  awk '{ print NR "\t" $0 }'
}

# emit_blob LABEL OBJECT: a blob as a file.
emit_blob() {
  git cat-file blob "$2" >"$tmp/blob"
  emit_file "$1" "$tmp/blob"
}

emit_tree() {
  local f
  git ls-files -z --cached --others --exclude-standard >"$tmp/list"
  while IFS= read -r -d '' f; do
    if [[ -f $f && ! -L $f ]]; then
      emit_file "$f" "$f"
    elif [[ -L $f ]]; then
      readlink "$f" >"$tmp/link"
      emit_file "$f" "$tmp/link"
    elif [[ -e $f ]]; then
      emit_path "$f"
    fi
  done <"$tmp/list"
}

# emit_raw FILE MODE: the paths of a `diff --raw -z -M` listing, with both
# sides of a rename or copy. With MODE content it also emits each new blob
# whole; with any other MODE, only the paths.
emit_raw() {
  local meta st p1 p2 p
  local -a m
  while IFS= read -r -d '' meta; do
    read -r -a m <<<"${meta#:}"
    st=${m[4]}
    IFS= read -r -d '' p1
    p=$p1
    if [[ $st == R* || $st == C* ]]; then
      emit_path "$p1"
      IFS= read -r -d '' p2
      p=$p2
    fi
    if [[ ${m[1]} == 160000 ]]; then
      emit_path "$p"
      continue
    fi
    if [[ $2 == content ]]; then
      emit_blob "$p" "${m[3]}"
    else
      emit_path "$p"
    fi
  done <"$1"
}

emit_staged() {
  git diff --cached --raw -z -M --diff-filter=ACMRT >"$tmp/raw"
  emit_raw "$tmp/raw" content
}

# emit_added: the added lines of a unified or combined diff on stdin, with
# the new file's line numbers. In a combined diff (a merge) a line counts
# only when it is new against every parent.
emit_added() {
  awk '
    /^diff --cc / { hunk = 0; cc = 1; printf "\001%s\n", substr($0, 11); next }
    /^diff --git / { hunk = 0; cc = 0; next }
    !hunk && !cc && /^\+\+\+ / { p = substr($0, 5); sub(/^b\//, "", p); if (p != "/dev/null") printf "\001%s\n", p; next }
    /^@@/ {
      match($0, /^@+/)
      k = RLENGTH
      hunk = 1
      width = k - 1
      plus = ""
      for (i = 0; i < width; i++) plus = plus "+"
      split(substr($(k + 1), 2), a, ",")
      n = a[1] + 0
      next
    }
    hunk && substr($0, 1, width) ~ /\+/ {
      if (substr($0, 1, width) == plus) print n "\t" substr($0, width + 1)
      n++
    }
  '
}

# emit_suppressed COMMIT FILE: whole new blobs for the files whose text
# git won't diff. A binary file, a file marked -diff in .gitattributes, or
# one whose old version was binary all show as "-" in numstat, and the
# patch then holds no lines to scan. A blob with a NUL that git still
# diffs as text gets the same treatment.
emit_suppressed() {
  local t rest p
  while IFS= read -r -d '' t; do
    rest=${t#*$'\t'}
    p=${rest#*$'\t'}
    if [[ -z $p ]]; then
      # A rename lists its old and new names as separate fields.
      IFS= read -r -d '' _
      IFS= read -r -d '' p
    fi
    if git cat-file -e "$1:$p"; then
      git cat-file blob "$1:$p" >"$tmp/blob"
      if [[ ${t%%$'\t'*} == - ]] || has_nul "$tmp/blob"; then
        printf '\001%s\n' "$(esc "$p")"
        emit_body "$tmp/blob"
      fi
    fi
  done <"$2"
}

# emit_commits: the commits named on stdin, in the order given. Each
# contributes its message, its paths, and its added lines, plus the whole
# new blob of any file whose diff git suppresses.
emit_commits() {
  local c parents p
  while IFS= read -r c; do
    git log -1 --format=%B "$c" | emit_text "commit ${c:0:7} message"
    parents=$(git rev-list --parents -n 1 "$c")
    if [[ $parents == *" "*" "* ]]; then
      # A merge: scan the whole result of every file it changed against
      # all parents. That is more than the lines it adds, but it also covers
      # a file whose textual diff git suppresses.
      git diff-tree --cc -r --name-only -z --no-commit-id "$c" >"$tmp/names"
      while IFS= read -r -d '' p; do
        emit_path "$p"
        # A path the merge deleted has no blob; one that exists must read.
        if git cat-file -e "$c:$p"; then
          git cat-file blob "$c:$p" >"$tmp/blob"
          printf '\001%s\n' "$(esc "$p")"
          emit_body "$tmp/blob"
        fi
      done <"$tmp/names"
    else
      git diff-tree --root -r -M --raw -z --no-commit-id --diff-filter=ACMRT "$c" >"$tmp/raw"
      emit_raw "$tmp/raw" paths
      git -c core.quotepath=off diff-tree --root -r -M -p -U0 --no-color --no-ext-diff \
        --diff-filter=ACMRT --no-commit-id "$c" | emit_added
      git diff-tree --root -r -M --numstat -z --no-commit-id --diff-filter=ACMRT "$c" >"$tmp/stat"
      emit_suppressed "$c" "$tmp/stat"
    fi
  done
}

emit_range() {
  git rev-list "$1" >/dev/null
  git rev-list --reverse "$1" >"$tmp/commits"
  emit_commits <"$tmp/commits"
}

# emit_tag OBJECT: an annotated tag's own text, then what it points at.
# A tag can point at another tag, a commit, a tree or a blob.
emit_tag() {
  local obj=$1 kind rec path sha
  kind=$(git cat-file -t "$obj")
  while [[ $kind == tag ]]; do
    git cat-file tag "$obj" | emit_text "tag ${obj:0:7}"
    obj=$(git cat-file tag "$obj" | awk '/^object /{ print $2; exit }')
    kind=$(git cat-file -t "$obj")
  done
  case $kind in
  commit) git rev-list --no-walk "$obj" | emit_commits ;;
  blob) emit_blob "tagged blob ${obj:0:7}" "$obj" ;;
  tree)
    git ls-tree -r -z "$obj" >"$tmp/tree"
    while IFS= read -r -d '' rec; do
      path=${rec#*$'\t'}
      sha=${rec%%$'\t'*}
      sha=${sha#* * }
      emit_blob "$path" "$sha"
    done <"$tmp/tree"
    ;;
  esac
}

# emit_pre_push [REMOTE]: what the push would send that the destination
# remote lacks. See the usage note at the top for the two input paths.
#
# The destination decides what it already has: the remote-tracking refs of
# the remote this push goes to, plus the remote sha git reports. When the
# destination can't be matched to a configured remote, nothing is assumed
# to be there and everything reachable is scanned. An upstream or
# origin/main never stands in for it.
emit_pre_push() {
  local remote=${1:-${PRE_COMMIT_REMOTE_NAME-}} url=${2:-${PRE_COMMIT_REMOTE_URL-}}
  local name='' manual='' r local_sha remote_sha u
  local -a args
  : >"$tmp/tuples"
  if [[ ! -t 0 ]]; then
    while IFS=' ' read -r _ local_sha _ remote_sha || [[ -n ${local_sha-} ]]; do
      if [[ -n $local_sha ]]; then printf '%s %s\n' "$local_sha" "${remote_sha:-0}" >>"$tmp/tuples"; fi
      local_sha=
    done
  fi
  if [[ -z $remote ]]; then manual=1; fi
  if [[ -n $remote ]]; then
    git remote >"$tmp/remotes"
    while IFS= read -r r; do
      if [[ $r == "$remote" || $(git remote get-url "$r") == "$remote" || $(git remote get-url "$r") == "$url" ]]; then
        name=$r
        break
      fi
    done <"$tmp/remotes"
  fi
  # A remote's tracking refs describe what it fetches from. If pushes go
  # elsewhere, or the hook was given another URL, they say nothing about
  # the destination, so assume it has nothing.
  if [[ -n $name ]]; then
    if [[ $(git remote get-url "$name") != "$(git remote get-url --push "$name")" ]] ||
      [[ -n $url && $url != "$(git remote get-url --push "$name")" ]]; then
      name=
    fi
  fi
  : >"$tmp/tags"
  : >"$tmp/starts"
  if [[ -s $tmp/tuples ]]; then
    while read -r local_sha remote_sha; do
      # A deletion sends nothing.
      if [[ $local_sha =~ ^0+$ ]]; then continue; fi
      args=("$local_sha")
      if [[ -n $name ]]; then args+=(--not "--remotes=$name"); fi
      if [[ -z $name && -n $manual ]]; then args+=(--not --remotes); fi
      if [[ ! $remote_sha =~ ^0+$ ]] && git cat-file -e "$remote_sha^{commit}"; then
        if [[ -z $name && -z $manual ]]; then args+=(--not); fi
        args+=("$remote_sha")
      fi
      git rev-list --reverse "${args[@]}" >>"$tmp/starts"
      if [[ $(git cat-file -t "$local_sha") == tag ]]; then printf '%s\n' "$local_sha" >>"$tmp/tags"; fi
    done <"$tmp/tuples"
  else
    args=(--branches --tags HEAD)
    if [[ -n ${PRE_COMMIT_TO_REF-} ]]; then args+=("$PRE_COMMIT_TO_REF"); fi
    if [[ -n $name ]]; then args+=(--not "--remotes=$name"); fi
    if [[ -z $name && -n $manual ]]; then args+=(--not --remotes); fi
    git rev-list --reverse "${args[@]}" >"$tmp/starts"
    git for-each-ref --format='%(objecttype) %(objectname)' refs/tags >"$tmp/refs"
    while read -r u r; do
      if [[ $u == tag ]]; then printf '%s\n' "$r" >>"$tmp/tags"; fi
    done <"$tmp/refs"
  fi
  awk '!seen[$0]++' "$tmp/starts" >"$tmp/commits"
  emit_commits <"$tmp/commits"
  while read -r u; do
    emit_tag "$u"
  done <"$tmp/tags"
}

mode=tree
range=
remote=
push_url=
files=()
while (($#)); do
  case $1 in
  --staged) mode=staged ;;
  --range)
    shift
    (($#)) || die "--range needs A..B"
    mode=range
    range=$1
    ;;
  --pre-push)
    mode=pre-push
    if (($# > 1)) && [[ $2 != -* ]]; then
      remote=$2
      shift
      if (($# > 1)) && [[ $2 != -* ]]; then
        push_url=$2
        shift
      fi
    fi
    ;;
  -*) die "unknown option" ;;
  *)
    mode=files
    files+=("$1")
    ;;
  esac
  shift
done

if [[ $mode != files ]]; then
  cd "$(git rev-parse --show-toplevel)"
fi

case $mode in
tree) emit_tree >"$tmp/stream" ;;
staged) emit_staged >"$tmp/stream" ;;
range) emit_range "$range" >"$tmp/stream" ;;
pre-push) emit_pre_push "$remote" "$push_url" >"$tmp/stream" ;;
files)
  for f in "${files[@]}"; do
    [[ -f $f ]] || die "an argument is not a readable file"
  done
  for f in "${files[@]}"; do emit_file "$f" "$f"; done >"$tmp/stream"
  ;;
esac

rc=0
scan <"$tmp/stream" || rc=$?
finished=1
exit "$rc"
