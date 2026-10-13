# Observability stack

Configuration for a self-hosted observability stack built from Grafana, Loki, Tempo, Mimir and Grafana Alloy, run with Docker Compose.

The repository is at the bootstrap stage. It holds the shared [devtools](https://github.com/tbhb-dev/devtools) toolchain and no stack configuration yet.

## Development

Run `mise run bootstrap` to sync the vendored payload, then set up the pinned tools, `guard-markdown` and the git hooks. Then run `mise run lint` and `mise run test` to run the checks. Copy `mise.local.toml.example` to `mise.local.toml` for local settings, which git ignores.

See [AGENTS.md](AGENTS.md) for the conventions that apply to contributors and coding agents.

## License

Apache-2.0. See [LICENSE](LICENSE).
