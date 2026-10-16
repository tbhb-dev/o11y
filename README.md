# Observability stack

Configuration for a self-hosted observability stack built from Grafana, Loki, Tempo, Mimir and Grafana Alloy, run with Docker Compose.

One Compose project runs the six services. Grafana Alloy receives OpenTelemetry data over gRPC and HTTP and forwards each signal to its backend, Tempo for traces, Loki for logs, and Mimir for metrics. Mimir takes only cumulative metrics, so Alloy converts the delta sums that clients such as Claude Code and Codex send. RustFS is the S3 object store behind those three, and Grafana reads from them. Published ports bind to loopback, and Tailscale Services put Grafana and the OpenTelemetry endpoint on the tailnet.

## Development

Run `mise run bootstrap` to sync the vendored payload, then set up the pinned tools, `guard-markdown` and the git hooks. Then run `mise run lint` and `mise run test` to run the checks. The shared tasks come from the [devtools](https://github.com/tbhb-dev/devtools) toolchain.

Two more checks need a Docker engine. `mise run validate` loads the Compose models and runs each component's own settings check. `mise run smoke` boots the stack locally and proves that it stores and returns telemetry.

## Deploying

One host runs the stack, reached over SSH. Copy `mise.local.toml.example` to `mise.local.toml`, which git ignores, and set the `O11Y_*` values that the header of `tools/nas.sh` lists. Each task that changes the host refuses to run unless `O11Y_CONFIRM` names it, as in `O11Y_CONFIRM=stage mise run stage`. Those that change the stack or its directory also take a lock on the host, so only one of them runs at a time.

`preflight`, `gate-test` and `deploy` refuse to start when the filesystem under `$O11Y_REMOTE_DIR` has less than `O11Y_DISK_RESERVE_GB` free (50 GiB unless set) or less than 10 percent free, and `status` prints the free space. `rollback` skips that check, so going back to the last release that passed works on a full disk too.

A first deploy runs these tasks in order:

1. `preflight` reads facts off the host without changing anything there.
2. `deploy-plan` prints the images, ports, release environment file and remote commands of a deploy, without connecting.
3. `stage` uploads a rendered release and checks every file against its manifest. Then it pulls the images, and starts nothing.
4. `gate-test` rehearses the deploy in a disposable project with its own data directory and ports, then stops it.
5. `gate-clean` removes the rehearsal's directory.
6. `deploy` starts the staged release and makes it current once the health gate passes.
7. `serve-apply` maps the two Tailscale Services to the stack's loopback ports.
8. `smoke-remote` sends a trace, a log and a metric through the Services and reads each one back.

### Alerts

The stack's Grafana sends its own alerts to Discord, and also by email once you set a recipient. An alert goes out when a service stays down for 5 minutes, when disk free drops below the deploy reserve, when a backend or Alloy drops incoming data, when RustFS nears its memory limit, when one of Alloy's queues fills or an exporter gives up, and when the stack logs more than 50 lines a second to Loki for an hour. `config/grafana/provisioning/alerting/` holds the rules. `deploy` reads the webhook URL with `op read` from the 1Password reference in `O11Y_ALERT_DISCORD_WEBHOOK_REF`, which needs a signed-in 1Password command-line tool, and pipes the URL to the host. There it goes into `data/secrets/` beside the Grafana password. Until a deploy writes it, as on the gate, the contact point posts to a placeholder address that refuses every connection.

With a recipient in `O11Y_ALERT_EMAIL_TO`, alerts also go out by email, and without one that receiver stays off. A recipient needs `O11Y_ALERT_SMTP_HOST`, `O11Y_ALERT_SMTP_PORT`, `O11Y_ALERT_SMTP_USER` and `O11Y_ALERT_SMTP_FROM` beside it, the Simple Mail Transfer Protocol (SMTP) server and login. `deploy` pipes the SMTP password from the reference in `O11Y_ALERT_SMTP_PASSWORD_REF` the same way as the webhook URL. Grafana requires STARTTLS on that connection.

A `rollback` to a release from before alerting leaves the alerts in place, because Grafana keeps a provisioned rule or contact point after its file goes away.

### After the first deploy

For day-to-day work, `status` shows the current release and each service's state, and `logs` shows recent container logs. To go back, `rollback` starts the current release again, or the one before it with `--previous`. Once `--previous` passes the health gate, the two pointers swap: `current` names the restored release and `previous` the one rolled back from. The next deploy then keeps the restored release as its fallback. Finally, `down` removes the containers and leaves everything else in place.

Everything the stack keeps on the host is under `$O11Y_REMOTE_DIR`. Each deploy adds a directory under `releases/`, and `current` and `previous` point at the last two releases that passed the health gate. Telemetry goes to `data/`. The init step creates the S3 key and the Grafana recovery password on the host, under `data/secrets/`. No task copies them off the host, and only `grafana-password` prints the recovery password, for recovery.

A rollback restores files and image versions, not data. A newer Grafana or backend may already have converted what it stored to a newer format, so going back can cost telemetry.

### A stale lock

A task stopped by a signal, a dropped connection or an incomplete rollback leaves `.deploy.lock` in `$O11Y_REMOTE_DIR`, and every task that changes the host refuses to start while it's there. Before you remove it:

1. On the host, list the processes and make sure no `docker-compose` or `docker` command from an earlier run is still going.
2. Run `mise run status` and note the release the containers run.
3. Compare that with the `current` and `previous` links in `$O11Y_REMOTE_DIR`. After an interrupted deploy or rollback, its message gives the release each link should point at. Set them to match before you go on.
4. Remove the lock with `rmdir`.

See [AGENTS.md](AGENTS.md) for the conventions that apply to contributors and coding agents.

## License

Apache-2.0. See [LICENSE](LICENSE).
