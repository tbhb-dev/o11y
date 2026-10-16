#!/bin/sh
# Prepares the data directory mounted at /data. Runs as root with no network,
# before every `up`. Rerunning it is always safe and completes an interrupted
# first run.
#
# The two RustFS key files and the Grafana password are canonical: a valid
# one is never touched. s3.env repeats the keys for the backends, which
# cannot read a key from a file, and is rewritten from the key files on every
# run. Every file is written under a temporary name and renamed into place.
# No secret value is ever printed.
set -eu
umask 077
LC_ALL=C
export LC_ALL

data=/data
secrets=$data/secrets

ensure_dir() {
  mkdir -p "$1"
  chown "$2" "$1"
  chmod "$3" "$1"
}

# tr never sees end of input; head closing the pipe is what ends it.
random() {
  tr -dc "$1" </dev/urandom | head -c "$2"
}

# valid <file> <character set> <length>. RustFS starts on a well-known
# default login when its key is missing, so that value is never acceptable.
valid() {
  [ -f "$1" ] || return 1
  value=$(cat "$1")
  [ "${#value}" -eq "$3" ] || return 1
  case $value in *[!$2]*) return 1 ;; esac
  [ "$value" != rustfsadmin ]
}

# A missing or damaged secret can be generated afresh only while nothing
# depends on it. Once the store it unlocks holds data, a new value would lock
# that data away, so stop and leave everything as it is.
must_generate=
check_secret() {
  if valid "$secrets/$1" "$2" "$3"; then
    return
  fi
  if [ -e "$4" ]; then
    echo "init: $1 is missing or damaged and $4 already exists; restore the file, nothing was changed" >&2
    exit 1
  fi
  must_generate="$must_generate $1"
}

generate_secret() {
  case " $must_generate " in *" $1 "*) ;; *) return ;; esac
  # shellcheck disable=SC2312 # valid checks the result on the next line
  printf '%s\n' "$(random "$2" "$3")" >"$secrets/.tmp.$1"
  valid "$secrets/.tmp.$1" "$2" "$3"
  mv "$secrets/.tmp.$1" "$secrets/$1"
  echo "init: generated $1"
}

check_secret rustfs.access_key 'A-Z0-9' 20 "$data/rustfs/.rustfs.sys"
check_secret rustfs.secret_key 'A-Za-z0-9' 40 "$data/rustfs/.rustfs.sys"
check_secret grafana_admin_password 'A-Za-z0-9' 32 "$data/grafana/grafana.db"

ensure_dir "$data/rustfs" 10001:10001 0750
ensure_dir "$data/loki" 10001:10001 0750
ensure_dir "$data/tempo" 10001:10001 0750
ensure_dir "$data/mimir" 0:0 0750
ensure_dir "$data/alloy" 0:0 0750
ensure_dir "$data/grafana" 472:472 0750
ensure_dir "$secrets" 0:0 0755

# Leftovers of a run that was interrupted between write and rename.
rm -f "$secrets"/.tmp.*

generate_secret rustfs.access_key 'A-Z0-9' 20
generate_secret rustfs.secret_key 'A-Za-z0-9' 40
generate_secret grafana_admin_password 'A-Za-z0-9' 32

# The Discord webhook URL and the SMTP password for alerts arrive from
# deploy, never from here, and deploy replaces these files after init.
# Grafana reads both at start, so a missing or empty webhook file gets a
# placeholder whose address refuses every connection: notifications to it
# fail, and nothing leaves the host. A missing password file is created
# empty, which is what Grafana reads while email is off.
webhook=$secrets/alert_discord_webhook_url
smtp_password=$secrets/alert_smtp_password
if [ ! -s "$webhook" ]; then
  printf '%s' 'http://127.0.0.1:9/o11y-no-webhook' >"$secrets/.tmp.alert_discord_webhook_url"
  mv "$secrets/.tmp.alert_discord_webhook_url" "$webhook"
  echo "init: wrote a placeholder alert_discord_webhook_url"
fi
if [ ! -f "$smtp_password" ]; then
  : >"$secrets/.tmp.alert_smtp_password"
  mv "$secrets/.tmp.alert_smtp_password" "$smtp_password"
  echo "init: wrote an empty alert_smtp_password"
fi

access_key=$(cat "$secrets/rustfs.access_key")
secret_key=$(cat "$secrets/rustfs.secret_key")
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$access_key" "$secret_key" >"$secrets/.tmp.s3.env"
chown "${O11Y_SECRETS_OWNER:-0:0}" "$secrets/.tmp.s3.env"
chmod 0600 "$secrets/.tmp.s3.env"
mv "$secrets/.tmp.s3.env" "$secrets/s3.env"

chown 10001:10001 "$secrets/rustfs.access_key" "$secrets/rustfs.secret_key"
chmod 0400 "$secrets/rustfs.access_key" "$secrets/rustfs.secret_key"
chown 472:472 "$secrets/grafana_admin_password" "$webhook" "$smtp_password"
chmod 0400 "$secrets/grafana_admin_password" "$webhook" "$smtp_password"

echo "init: ok"
