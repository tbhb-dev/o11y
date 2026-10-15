#!/usr/bin/env bats
# The fault run's memory verdict against made-up peaks files. The run itself
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
