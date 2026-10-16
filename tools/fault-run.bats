#!/usr/bin/env bats
# The fault run's memory verdict against made-up peaks files, and its load
# generator verdict against made-up inspect results. The run itself
# needs a Linux engine and takes minutes, so only its last check runs here.

setup() {
  script="$BATS_TEST_DIRNAME/fault-run.sh"
  peaks=$(mktemp)
}

teardown() {
  rm -f "$peaks"
}

# row <service> <anon percent>: one peaks line, as the run writes it.
row() {
  printf '%-8s %7s %8s %8s %8s %8s %7s%% %4d %9d %d\n' "$1" 768M 100M 110M 90M 5M "$2" 0 0 90
}

six() {
  local service
  for service in alloy grafana loki mimir rustfs tempo; do
    row "$service" "$1"
  done
}

@test "every container under 70 percent anon passes" {
  six 41.0 >"$peaks"
  run bash "$script" --check-peaks "$peaks"
  [ "$status" -eq 0 ]
}

@test "one container at or over 70 percent anon fails" {
  {
    six 20.0 | head -n 5
    row tempo 95.0
  } >"$peaks"
  run bash "$script" --check-peaks "$peaks"
  [ "$status" -ne 0 ]
  {
    six 20.0 | head -n 5
    row tempo 70.0
  } >"$peaks"
  run bash "$script" --check-peaks "$peaks"
  [ "$status" -ne 0 ]
}

@test "a missing container or a short line fails" {
  six 20.0 | head -n 5 >"$peaks"
  run bash "$script" --check-peaks "$peaks"
  [ "$status" -ne 0 ]
  {
    six 20.0 | head -n 5
    echo "tempo 768M"
  } >"$peaks"
  run bash "$script" --check-peaks "$peaks"
  [ "$status" -ne 0 ]
}

@test "a load generator passes only when its inspect succeeded and it runs or exited 0" {
  run bash "$script" --check-load 0 "running 0"
  [ "$status" -eq 0 ]
  run bash "$script" --check-load 0 "exited 0"
  [ "$status" -eq 0 ]
  run bash "$script" --check-load 0 "exited 1"
  [ "$status" -ne 0 ]
  run bash "$script" --check-load 1 ""
  [ "$status" -ne 0 ]
  run bash "$script" --check-load 1 "running 0"
  [ "$status" -ne 0 ]
}

# samples <count>: that many good samples of each of the six services.
samples() {
  local i service
  for ((i = 0; i < $1; i++)); do
    for service in alloy grafana loki mimir rustfs tempo; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' $((1760000000 + i * 5)) "$service" 1000 2000 900 100 0 0
    done
  done
}

@test "a complete sampler record passes" {
  samples 10 >"$peaks"
  run bash "$script" --check-samples "$peaks"
  [ "$status" -eq 0 ]
}

@test "a sampler error, a shell message, a non-numeric or empty field, or too few samples fails" {
  local bad
  for bad in "ERROR	anon	a cgroup memory file could not be read" "cat: can't open memory.stat" \
    "1760000000	alloy	1000	2000		100	0	0" "1760000000	alloy	1000	2000	x	100	0	0" \
    "1760000000	minio	1000	2000	900	100	0	0"; do
    {
      samples 10
      printf '%s\n' "$bad"
    } >"$peaks"
    run bash "$script" --check-samples "$peaks"
    [ "$status" -ne 0 ]
  done
  samples 9 >"$peaks"
  run bash "$script" --check-samples "$peaks"
  [ "$status" -ne 0 ]
}
