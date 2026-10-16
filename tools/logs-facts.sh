#!/usr/bin/env bash
# What the container-log reader would find on the deploy host: Docker's
# data root, the mounts around it, the stack's json-file logs and who can
# read them, the other apps' log drivers, log growth, the listeners an
# internal network can reach, and root filesystem headroom. It changes
# nothing on the stack. `tools/nas.sh logs-facts` runs it on the host as the
# script of bash -c, with two arguments:
#
#   logs-facts.sh <docker path> <pinned Alloy image>
#
# It takes about 11 minutes, 10 of them A4's growth window.
#
# Docker is reached only as `sudo -n <docker path>`, the one sudo the host
# grants. Root-owned paths are read only from inside a throwaway reader
# container from the pinned Alloy image, with the log reader's own
# settings: uid 0, every capability dropped, no-new-privileges, a read-only
# root, no network, no log, removed on exit, and the containers directory
# bound read-only and rprivate through --mount, which never creates a
# missing source. Nothing is pulled. While a reader runs it is a real
# container, so Docker writes its record, a writable layer and containerd's
# bundle, and --rm removes them. The daemons' own logs of its start and
# exit stay.
#
# Two rules hold throughout:
# - It fails closed. Every read is its own assignment with its status
#   checked, here and inside the readers, and every value is checked before
#   it is used. A number is decimal with no leading zero, so bash
#   arithmetic never reads one as octal. Any failure stops the run with
#   `FAIL <id>: <reason>` and status 1, and anything else that stops it
#   prints `FAIL run:`.
# - Its output is shape-allowlisted. A value prints only after it matches a
#   fixed pattern, and a reason is always a fixed string from this script.
#   From the first line on, the script's stderr goes to /dev/null, so no
#   helper's diagnostic prints, bash's own included. The data root and
#   other apps' project names never reach a print statement.
#
# docker inspect only ever takes a -f template, and no template names
# Config.Env. The host side keeps to bash 3.2: no associative arrays and no
# mapfile. It also uses no here-string, which bash 3.2 writes to a
# temporary file; values reach a command through printf and a pipe or a
# process substitution instead. The readers run in the Alloy image's bash,
# started through env -i with a fixed PATH and no startup files.
# cspell:ignore aufs devicemapper gelf hostconfig logdrv mountinfo noprofile norc overlayfs rootfs rprivate rwro rwxs tmpfs trunc unbindable
set -euo pipefail
exec 3>&2 2>/dev/null

# A function the environment handed in could stand in for any command or
# builtin used below, declare included. nas.sh starts this shell with
# env -i; this refuses one that started some other way.
inherited=$(builtin declare -F) || exit 1
if [[ -n $inherited ]]; then
  printf 'FAIL env: the shell inherited functions from its environment\n' >&3
  exit 1
fi

# Only the last line sets completed. Any other way out, bash's own errors
# and signals included, ends in FAIL and a nonzero status, on bash 3.2 as
# well, where an unbound variable can otherwise exit 0.
reported=0
completed=0
fail() {
  reported=1
  printf 'FAIL %s: %s\n' "$1" "$2" >&3
  exit 1
}
finish() {
  local status=$?
  ((completed == 0)) || return 0
  if ((reported == 0)); then
    printf 'FAIL run: the script stopped on an unexpected error\n' >&3
  fi
  ((status != 0)) || status=1
  exit "$status"
}
trap finish EXIT
trap 'fail run "the run was stopped by a signal"' INT TERM HUP

[[ $# -eq 2 ]] || fail args "it takes the docker path and the Alloy image"
docker=$1
image=$2
[[ $docker =~ ^/[A-Za-z0-9._/-]+$ && $docker != *..* ]] || fail args "the docker path is not a plain absolute path"
[[ $image =~ ^grafana/alloy:v[0-9.]+@sha256:[0-9a-f]{64}$ ]] || fail args "the image is not a pinned Alloy image"

host_mountinfo=/proc/self/mountinfo
# Where a reader sees the containers directory, as the log reader will.
target=/var/log/docker-containers
expected='alloy grafana loki mimir rustfs tempo'

NUM='^(0|[1-9][0-9]{0,14})$'
PORT='^[1-9][0-9]{0,4}$'
MODE='^[0-7]{3,4}$'
OWNER='^(0|[1-9][0-9]{0,9}):(0|[1-9][0-9]{0,9})$'
YESNO='^(yes|no)$'
SVC='^(alloy|grafana|loki|mimir|rustfs|tempo)$'
PROJECT='^(o11y|o11y-gate|other)$'
ID='^[0-9a-f]{64}$'
SHORT_ID='^[0-9a-f]{12}$'
VER='^[0-9]+(\.[0-9]+){1,3}[+a-z0-9-]{0,16}$'
STORAGE='^(btrfs|overlay2|vfs|devicemapper|zfs|aufs|fuse-overlayfs)$'
LOGDRV='^(json-file|local|journald|syslog|gelf|fluentd|none|db)$'
FSTYPE='^(ext4|btrfs|xfs|tmpfs|overlay|rootfs)$'
RWRO='^(rw|ro)$'
TAGS='^(none|((shared|master|propagate_from):[1-9][0-9]{0,9} ?)+|unbindable)$'

# show <id> <label> <pattern> <value>
show() {
  [[ $4 =~ $3 ]] || fail "$1" "$2 has an unexpected shape"
  printf '%s %s %s\n' "$1" "$2" "$4"
}

# d <args>: docker through the one sudo the host grants.
d() {
  sudo -n "$docker" "$@"
}

# reader <function>: runs that function, defined below, in a throwaway
# container with the log reader's settings. The function's text is all the
# container gets, so it carries its own checks; its stdout is data for the
# checks here, never printed as is.
reader() {
  local body
  body=$(builtin declare -f "$1") || return 1
  d run --rm -i --pull never --network none --log-driver none \
    --user 0:0 --cap-drop ALL --security-opt no-new-privileges:true --read-only \
    --mount "type=bind,source=$root/containers,target=$target,readonly,bind-propagation=rprivate" \
    --entrypoint /usr/bin/env "$image" -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash --noprofile --norc -c "set -euo pipefail; target=$target; $body; $1"
}

# --- the readers, each run only inside a container ---------------------

# R2: the number of mounts at or below the target, and whether the target
# itself is read-only.
reader_r2() {
  local m
  m=$(awk -v t="$target" '$5 == t || index($5, t "/") == 1 { n++; if ($5 == t) o = "," $6 "," }
    END { print n + 0, (o ~ /,ro,/ ? "ro" : "not-ro") }' /proc/self/mountinfo) || exit 1
  echo "$m"
}

# R3: how many logs the real glob finds, then for each "service id" line on
# stdin whether the glob found its log and whether one byte of it reads.
reader_r3() {
  local all x s id f g r
  shopt -s nullglob
  all=("$target"/*/*-json.log)
  echo "total ${#all[@]}"
  while read -r s id; do
    f=$target/$id/$id-json.log
    g=no
    for x in "${all[@]}"; do
      if [[ $x == "$f" ]]; then g=yes; fi
    done
    if head -c 1 "$f" >/dev/null; then r=yes; else r=no; fi
    echo "$s $g $r"
  done
}

# R4: mode and owner of the target and of one container's directory, log,
# config.v2.json and hostconfig.json, the id on stdin, then the target's
# mode word from ls, which carries the ACL mark.
reader_r4() {
  local id p m l
  read -r id
  for p in "" "/$id" "/$id/$id-json.log" "/$id/config.v2.json" "/$id/hostconfig.json"; do
    m=$(stat -c '%a %u:%g' "$target$p") || exit 1
    echo "$m"
  done
  l=$(ls -ld "$target") || exit 1
  echo "acl ${l%% *}"
}

# A4: for each "service id" line on stdin, the inode and size of its log
# and of its rotated log, ten minutes apart, as one line per service.
reader_a4() {
  local pairs a b
  snap() {
    local s id f cur old
    while read -r s id; do
      f=$target/$id/$id-json.log
      cur=$(stat -c '%i %s' "$f") || exit 1
      if [[ -e $f.1 ]]; then
        old=$(stat -c '%i %s' "$f.1") || exit 1
      else
        old="0 0"
      fi
      echo "$s $cur $old"
    done < <(printf '%s\n' "$pairs")
  }
  pairs=$(cat) || exit 1
  a=$(snap) || exit 1
  sleep 600
  b=$(snap) || exit 1
  paste -d ' ' <(echo "$a") <(echo "$b")
}

# --- D0: the data root, never printed --------------------------------------

root=$(d info -f '{{.DockerRootDir}}') || fail D0 "docker info failed"
[[ $root =~ ^/[A-Za-z0-9._/-]+$ && $root != */ && $root != *..* ]] || fail D0 "the data root is not a plain absolute path"
info=$(d info -f '{{.ServerVersion}} {{.Driver}} {{.LoggingDriver}} {{.KernelVersion}}') || fail D0 "docker info failed"
read -r ver storage logdrv kernel extra < <(printf '%s\n' "$info") || fail D0 "docker info has an unexpected shape"
[[ -z $extra ]] || fail D0 "docker info has an unexpected shape"
show D0 engine "$VER" "$ver"
show D0 storage "$STORAGE" "$storage"
show D0 default-log-driver "$LOGDRV" "$logdrv"
show D0 kernel "$VER" "$kernel"

# --- A2: the pinned image is here, so nothing is pulled ---------------------

d image inspect -f '{{.Id}}' "$image" >/dev/null || fail A2 "the pinned Alloy image is not on the host"
echo "A2 image present"

# --- R1: the mount that holds the data root; nothing below containers/ ------

r1=$(awk -v r="$root" -v c="$root/containers" '
  # A mountinfo line has at least ten fields with a lone - among them.
  { dash = 0; for (i = 7; i <= NF; i++) if ($i == "-") dash = i
    if (NF < 10 || dash == 0 || dash + 3 > NF) exit 3
    mp = $5 }
  mp == c || index(mp, c "/") == 1 { below++ }
  mp == "/" || mp == r || index(r, mp "/") == 1 {
    if (length(mp) > best) {
      best = length(mp); split($6, o, ","); rw = o[1]; tags = ""
      for (i = 7; i <= NF && $i != "-"; i++) tags = tags (tags == "" ? "" : " ") $i
      fstype = $(i + 1); kind = (mp == r) ? "itself" : "ancestor"
    }
  }
  END { if (best == 0) exit 2; print kind "|" fstype "|" rw "|" (tags == "" ? "none" : tags) "|" below + 0 }' "$host_mountinfo") ||
  fail R1 "the mount table could not be read, or holds no enclosing mount"
IFS='|' read -r kind fstype rw tags below extra < <(printf '%s\n' "$r1") || fail R1 "the mount summary has an unexpected shape"
[[ -z $extra ]] || fail R1 "the mount summary has an unexpected shape"
show R1 enclosing-mount '^(itself|ancestor)$' "$kind"
show R1 type "$FSTYPE" "$fstype"
show R1 access "$RWRO" "$rw"
show R1 propagation "$TAGS" "$tags"
show R1 mounts-below-containers "$NUM" "$below"
[[ $below == 0 ]] || fail R1 "a mount is at or below containers/"

# --- R2: the reader's own mount table ---------------------------------------

r2=$(reader reader_r2 </dev/null) || fail R2 "the reader could not read its own mount table"
[[ $r2 == "1 ro" ]] || fail R2 "the reader's mounts are not exactly one read-only target"
echo "R2 one read-only target"

# --- R3: exactly the six services, each log globbed and readable ------------

# services: the project's running containers, one "service id state" line
# each, sorted, so two snapshots compare as text.
services() {
  d ps --no-trunc --filter label=com.docker.compose.project=o11y \
    --format '{{.Label "com.docker.compose.service"}} {{.ID}} {{.State}}' | sort
}

running=$(services) || fail R3 "docker ps failed"
pairs=
names=
while read -r s id state extra; do
  [[ $s =~ $SVC && $id =~ $ID && $state == running && -z $extra ]] || fail R3 "docker ps has an unexpected shape"
  pairs+="${pairs:+$'\n'}$s $id"
  names+="${names:+$'\n'}$s"
done < <(printf '%s\n' "$running")
have=$(printf '%s\n' "$names" | sort | tr '\n' ' ') || fail R3 "the service list could not be sorted"
[[ $have == "$expected " ]] || fail R3 "the running o11y services are not exactly the expected six"
r3=$(printf '%s\n' "$pairs" | reader reader_r3) || fail R3 "the reader failed"
n=0
while read -r a b c extra; do
  [[ -z $extra ]] || fail R3 "the reader printed an unexpected line"
  if [[ $a == total ]]; then
    show R3 json-file-logs-on-host "$NUM" "$b"
    continue
  fi
  [[ $a =~ $SVC ]] || fail R3 "the reader printed an unexpected line"
  show R3 "$a-globbed" "$YESNO" "$b"
  show R3 "$a-readable" "$YESNO" "$c"
  [[ $b == yes && $c == yes ]] || fail R3 "a service's log was not globbed or not readable"
  n=$((n + 1))
done < <(printf '%s\n' "$r3")
[[ $n == 6 ]] || fail R3 "the reader did not report all six services"

# --- R4: modes and owners around the loki container -------------------------

id=
while read -r s i; do
  if [[ $s == loki ]]; then id=$i; fi
done < <(printf '%s\n' "$pairs")
[[ $id =~ $ID ]] || fail R4 "the loki container has no id"
r4=$(printf '%s\n' "$id" | reader reader_r4) || fail R4 "the reader failed"
labels=(target container-dir log config.v2.json hostconfig.json)
i=0
acl=
while read -r a b extra; do
  [[ -z $extra ]] || fail R4 "the reader printed an unexpected line"
  if [[ $a == acl ]]; then
    [[ -z $acl ]] || fail R4 "the reader printed an unexpected line"
    # The mode word ls prints, with + for an ACL; anything else is no
    # answer, so an empty or odd line fails rather than reading as none.
    [[ $b =~ ^d[-rwxsStT]{9}[.+@]?$ ]] || fail R4 "ls printed an unexpected mode word"
    if [[ $b == *+ ]]; then acl=yes; else acl=no; fi
    show R4 acl-on-target "$YESNO" "$acl"
    continue
  fi
  [[ $i -lt 5 ]] || fail R4 "the reader printed more than expected"
  show R4 "${labels[$i]}-mode" "$MODE" "$a"
  show R4 "${labels[$i]}-owner" "$OWNER" "$b"
  i=$((i + 1))
done < <(printf '%s\n' "$r4")
[[ $i == 5 && -n $acl ]] || fail R4 "the reader did not report all five paths and the ACL mark"

# --- R5: every container on the host by project class and log driver --------
# Other apps' projects count only as other, a driver outside the known set
# only as other-driver.

ids=$(d ps -aq) || fail R5 "docker ps failed"
list=()
while read -r i; do
  [[ $i =~ $SHORT_ID ]] || fail R5 "docker ps has an unexpected shape"
  list+=("$i")
done < <(printf '%s\n' "$ids")
r5=$(d inspect -f '{{index .Config.Labels "com.docker.compose.project"}}|{{.HostConfig.LogConfig.Type}}' "${list[@]}") ||
  fail R5 "docker inspect failed"
classes=
n=0
while IFS='|' read -r proj drv; do
  if [[ $proj != o11y && $proj != o11y-gate ]]; then proj=other; fi
  if [[ ! $drv =~ $LOGDRV ]]; then drv=other-driver; fi
  classes+="${classes:+$'\n'}$proj $drv"
  n=$((n + 1))
done < <(printf '%s\n' "$r5")
[[ $n == "${#list[@]}" ]] || fail R5 "docker inspect did not report one line per container"
counts=$(printf '%s\n' "$classes" | sort | uniq -c) || fail R5 "the classes could not be counted"
while read -r c proj drv extra; do
  [[ -z $extra && $c =~ $NUM && $proj =~ $PROJECT && ($drv =~ $LOGDRV || $drv == other-driver) ]] ||
    fail R5 "the counts have an unexpected shape"
  echo "R5 $proj $drv $c"
done < <(printf '%s\n' "$counts")

# --- R6: each service's log driver and its known options --------------------

while read -r s id; do
  r6=$(d inspect -f '{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{index .HostConfig.LogConfig.Config "max-file"}}|{{index .HostConfig.LogConfig.Config "labels"}}|{{index .HostConfig.LogConfig.Config "mode"}}|{{len .HostConfig.LogConfig.Config}}' "$id") ||
    fail R6 "docker inspect failed"
  IFS='|' read -r drv size files lab mode keys extra < <(printf '%s\n' "$r6") || fail R6 "docker inspect has an unexpected shape"
  [[ -z $extra ]] || fail R6 "docker inspect has an unexpected shape"
  [[ $drv == json-file && $size == 10m && $files == 3 ]] || fail R6 "a service is not on json-file 10m x 3"
  [[ -z $lab || $lab == com.docker.compose.project,com.docker.compose.service ]] || fail R6 "a service has an unexpected labels option"
  [[ -z $mode || $mode == blocking || $mode == non-blocking ]] || fail R6 "a service has an unexpected mode option"
  show R6 "$s-options" "$NUM" "$keys"
  if [[ -n $lab ]]; then lab="set"; else lab="unset"; fi
  echo "R6 $s json-file 10m x 3 labels=$lab mode=${mode:-default}"
done < <(printf '%s\n' "$pairs")

# --- A4: each service's log growth over ten minutes -------------------------

# The window measures the containers R3 checked, so the same ones, each
# still running, must be there before it and after it.
before=$(services) || fail A4 "docker ps failed"
[[ $before == "$running" ]] || fail A4 "the services changed before the window"
a4=$(printf '%s\n' "$pairs" | reader reader_a4) || fail A4 "the reader failed"
after=$(services) || fail A4 "docker ps failed"
[[ $after == "$running" ]] || fail A4 "the services changed during the window"
n=0
while read -r s i0 s0 j0 t0 s_ i1 s1 j1 t1 extra; do
  [[ -z $extra && $s =~ $SVC && $s_ == "$s" ]] || fail A4 "a snapshot has an unexpected shape"
  for v in "$i0" "$s0" "$j0" "$t0" "$i1" "$s1" "$j1" "$t1"; do
    [[ $v =~ $NUM ]] || fail A4 "a snapshot has a non-numeric field"
  done
  [[ $i0 != 0 && $i1 != 0 ]] || fail A4 "a current log has no inode"
  if [[ $i1 == "$i0" ]]; then
    ((s1 >= s0)) || fail A4 "a log shrank without rotating"
    g=$((s1 - s0))
  elif [[ $j1 == "$i0" ]]; then
    ((t1 >= s0)) || fail A4 "a rotated log is smaller than before it rotated"
    g=$((t1 - s0 + s1))
  else
    fail A4 "a log rotated more than once in the window; shorten it"
  fi
  show A4 "$s-bytes-a-day" "$NUM" "$((g * 144))"
  n=$((n + 1))
done < <(printf '%s\n' "$a4")
[[ $n == 6 ]] || fail A4 "the reader did not report all six services"

# --- A5: TCP ports listening on all addresses (plan section 1.1) ------------

if command -v netstat >/dev/null; then
  tool=netstat
  l=$(netstat -ltn) || fail A5 "netstat failed"
elif command -v ss >/dev/null; then
  tool=ss
  l=$(ss -ltn) || fail A5 "ss failed"
else
  fail A5 "neither netstat nor ss is on the host"
fi
# The tool's header first, then only listening TCP lines with a port, so
# output in any other shape fails instead of reading as no listeners.
found=$(printf '%s\n' "$l" | awk -v tool="$tool" '
  tool == "netstat" && NR == 1 && /^Active Internet connections/ { next }
  !seen && $1 == (tool == "netstat" ? "Proto" : "State") && $2 == "Recv-Q" && $3 == "Send-Q" { seen = 1; next }
  !seen { exit 3 }
  tool == "netstat" { if (NF != 6 || $1 !~ /^tcp6?$/ || $6 != "LISTEN") exit 3 }
  tool == "ss" { if (NF < 5 || $1 != "LISTEN") exit 3 }
  { a = $4; if (a !~ /:[0-9]+$/) exit 3 }
  a ~ /^(0\.0\.0\.0|\*|\[::\]|::|):[0-9]+$/ || a ~ /^:::[0-9]+$/ { sub(/.*:/, "", a); print a }
  END { if (!seen) exit 3 }') ||
  fail A5 "the listener table has an unexpected shape"
ports=
if [[ -n $found ]]; then
  ports=$(printf '%s\n' "$found" | sort -n -u) || fail A5 "the ports could not be sorted"
fi
shown=
while read -r p; do
  [[ -n $p ]] || continue
  if [[ ! $p =~ $PORT ]] || ((p > 65535)); then fail A5 "a port has an unexpected shape"; fi
  shown+=" $p"
done < <(printf '%s\n' "$ports")
echo "A5 tcp-ports-on-all-addresses${shown:- none}"

# --- N7: root filesystem headroom ------------------------------------------

df=$(df -Pk /) || fail N7 "df failed"
# The POSIX header, then exactly one line of six fields.
sizes=$(printf '%s\n' "$df" | awk 'NR == 1 && $1 != "Filesystem" { exit 3 }
  NR == 2 { if (NF != 6) exit 3; print $4, $2 }
  END { if (NR != 2) exit 3 }') || fail N7 "the df output could not be read"
read -r free total extra < <(printf '%s\n' "$sizes") || fail N7 "the df output has an unexpected shape"
[[ -z $extra ]] || fail N7 "the df output has an unexpected shape"
show N7 root-free-kib "$NUM" "$free"
show N7 root-total-kib "$NUM" "$total"

echo "OK all checks passed"
completed=1
