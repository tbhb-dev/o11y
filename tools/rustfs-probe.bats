#!/usr/bin/env bats
# tools/rustfs-probe.sh against a stub Compose: when the run ends early while
# the crash writer is running, the writer's container must be stopped and
# the background job reaped before the scratch files go.

setup() {
  dir=$(mktemp -d)
  export STUB_LOG="$dir/calls" TMPDIR="$dir/tmp"
  mkdir "$TMPDIR" "$dir/release"
  # Answers just enough for steps 1 to 4. The crash writer prints its start
  # line and then blocks; killing the store fails, which ends the run early.
  cat >"$dir/compose" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$*" in
  *"exec -T rustfs curl -s -o /dev/null -w %{http_code} http://127.0.0.1:9000/health/ready"*) printf 200 ;;
  *"exec -T rustfs curl -s -o /dev/null -m 5 http://127.0.0.1:9001/"*) exit 7 ;;
  *"logs --no-log-prefix rustfs"*) echo '{"console_enabled":false}' ;;
  *"s3probe crash"*)
    echo "probe: writing"
    sleep 300 &
    echo $! >"${STUB_LOG%/*}/writer.pid"
    wait
    ;;
  *"kill rustfs"*) exit 1 ;;
  *"kill s3probe"*) kill "$(cat "${STUB_LOG%/*}/writer.pid")" ;;
esac
exit 0
STUB
  chmod +x "$dir/compose"
}

teardown() {
  [ ! -f "$dir/writer.pid" ] || kill "$(cat "$dir/writer.pid")" 2>/dev/null || true
  rm -rf "$dir"
}

@test "an early exit stops the writer's container and removes the scratch files" {
  run bash "$BATS_TEST_DIRNAME/rustfs-probe.sh" --release "$dir/release" --project probe-test -- "$dir/compose"
  [ "$status" -ne 0 ]
  [[ $output == *"ok 4:"* ]]
  [[ $output != *"ok 5:"* ]]
  grep -q 'kill s3probe' "$STUB_LOG"
  ! kill -0 "$(cat "$dir/writer.pid")" 2>/dev/null || false
  [ -z "$(ls -A "$TMPDIR")" ]
}
