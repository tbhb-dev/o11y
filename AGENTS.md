# Agent instructions

Guidance for AI coding agents working in this repository. This file is the canonical source for every harness. `CLAUDE.md` points here, and the agy command-line tool reads only this file.

## Scope

This repository holds configuration for a self-hosted observability stack built from Grafana, Loki, Tempo, Mimir and Grafana Alloy, run with Docker Compose. It contains YAML and Alloy configuration, shell scripts, mise tasks that deploy over SSH, and Markdown docs. It has no Go or Python app code. The one Python file, `tools/apm_audit.py`, belongs to the toolchain.

One Compose project runs the stack, with RustFS as the S3 object store for Loki, Tempo, and Mimir. To check it, run `mise run validate`, `mise run rustfs-probe` and `mise run smoke`, each of which needs a Docker engine. Deploy tasks are still to come.

## Public repository

This repository is public. Never commit an internal hostname, tailnet name, IP address, deployment path, username on an internal host, password manager vault or item name, or `op://` reference. Those values live in `mise.local.toml`, which git ignores. `mise.local.toml.example` is the tracked template and holds placeholders only.

Tasks read these values from the environment, so no private value appears in `mise.toml` or a script. Resolve a secret at the moment of use inside the task body. Keep Compose settings in the task environment instead of a committed `.env` file. Run `mise fmt` after editing `mise.local.toml`, because `mise run lint` format-checks it.

Check the staged diff against that list before every commit.

## Stack secrets

The init one-shot generates the S3 key and the Grafana recovery password on the host that runs the stack. Keep both out of committed files, rendered files, command lines, logs, and task output.

Compose prints the contents of every environment file a model loads. Against the environment file of a deployment, run `config` only with `-q`. To read a resolved model, run `mise run compose-config` instead. It renders with placeholders and loads a dummy file, and it ignores inherited variables. In a task, run `docker inspect` on the stack's containers only with a `-f` template that can't print `Config.Env`. Their environment contains the S3 key.

Published ports bind to 127.0.0.1. Don't add a setting that changes that, because Grafana gives anonymous users the Editor role and whatever fronts the host decides who reaches it.

## Tools

mise pins the tools and defines the tasks. The shared half arrives from `tbhb-dev/devtools` through vendir into `.config/mise/conf.d/` and `.devtools/tasks/`. Never edit those two directories by hand. Run `mise run bootstrap` once to sync the payload and install the tools plus the git hooks.

- `mise run lint` runs every lint gate in order.
- `mise run test` runs the test suites.
- `mise run check` runs both.
- `mise run devtools:update-pins <version>` moves every devtools pin together. Redeploy the agent primitives with `mise run apm-sync` instead of a bare `apm install`.

The `guard-markdown` binary must be on PATH for `lint-markdown-wrap` and the Claude write hook. `mise run bootstrap` installs it through `mise run install-guard-markdown`, which takes the version from the devtools pin in `apm.yml`. A pin bump moves it too. Keep the Go bin directory on PATH.

## Commit messages

Run the `commit` skill. Draft the message in the repo-root file `COMMIT_AGENTMSG`, which a gitignore entry keeps out of history, then run `mise run lint-commit-msg`. The prek commit-msg hook is the real gate. Stage paths by name, and never run `git add -A` or `git add .`.

A message needs a Conventional Commits subject, a blank line before the body, an `Assisted-by:` trailer in the form `agent:model tool` such as `claude:opus-5-5 claude-code`, and a `Signed-off-by:` trailer after it. Never use `--no-verify` on a real commit.

## Pull requests

Run the `pr` skill. Draft the description in the repo-root file `PR_AGENTDESC.md`, following `.github/pull_request_template.md`, and run `mise run lint-pr-description`. The `watch-pr`, `fix-pr` and `merge-pr` skills cover what follows.

## Markdown

Write each paragraph on one line, with no hard wrapping. `mise run lint-markdown-wrap` enforces it.

## Stash and work in progress

Agent sessions can run in parallel worktrees, and every worktree shares one global `git stash` stack.

- Use `git rebase --autostash` instead of a manual stash when you rebase a dirty worktree.
- Never run a bare `git stash pop` or `git stash apply`. Name a manual stash with `git stash push -m`, check `git stash list` right before restoring, and pop the explicit `stash@{n}`.
- To park work across a rebase or branch switch, commit it with `git commit -am wip --no-verify` and unwind it with `git reset --soft HEAD~1`. This throwaway commit is the one sanctioned use of `--no-verify`, and real commits never use it.
