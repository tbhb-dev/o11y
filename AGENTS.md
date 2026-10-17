# Agent instructions

Guidance for AI coding agents working in this repository. This file is the canonical source for every harness. `CLAUDE.md` points here, and the agy command-line tool reads only this file.

## Scope

This repository holds configuration for a self-hosted observability stack built from Grafana, Loki, Tempo, Mimir and Grafana Alloy, run with Docker Compose. It contains YAML and Alloy configuration, shell scripts, mise tasks that deploy over SSH, and Markdown docs. It has no Go or Python app code. The one Python file, `tools/apm_audit.py`, belongs to the toolchain.

One Compose project runs the stack, with RustFS as the S3 object store for Loki, Tempo, and Mimir. To check it, run `mise run validate`, `mise run rustfs-probe` and `mise run smoke`, each of which needs a Docker engine.

## Public repository

This repository is public. Never commit an internal hostname, tailnet name, IP address, deployment path, username on an internal host, or password manager reference. Those values live in `mise.local.toml`, which git ignores. `mise.local.toml.example` is the tracked template and holds placeholders only.

Tasks read these values from the environment, so no private value appears in `mise.toml` or a script. Resolve a secret at the moment of use inside the task body. Keep Compose settings in the task environment instead of a committed `.env` file. Run `mise fmt` after editing `mise.local.toml`, because `mise run lint` format-checks it.

Check the staged diff against that list before every commit. `mise run devtools:lint-leaks -- --staged` does it mechanically, as the next section describes.

## Private values

`mise run devtools:lint-leaks` scans private literals from exported variables ending in `_PRIVATE_STRINGS`, plus the shared patterns for private addresses, tailnet names, password manager references, and private keys. Findings report the location and rule. They don't print the matched value.

Set `O11Y_PRIVATE_STRINGS` under `[env]` in the gitignored `mise.local.toml` to a comma-separated list of plain literals. The list must contain every private host name, login, address, deployment or executable path, tailnet domain and private domain label, site-specific cluster name, and model identifier that must stay out of the repository. For this list, the gate doesn't derive values from other `O11Y_*` variables or recorded host names. Entries need at least four characters and can't contain commas. Keep deployment variables in place for the stack tasks. Copy their private literals into this list yourself. Never put real values in the tracked template.

In documentation and examples, use placeholders such as `example.ts.net`, `nas.example.invalid`, `192.0.2.x` or `/srv/o11y`, or refer to the variable, such as `$O11Y_REMOTE_DIR`. `.leak-allow` exempts vendored and deployed trees from pattern checks. Private literals still apply to every file.

With no arguments the gate scans the working tree. Pass `-- --staged` to scan index blobs, `-- --range A..B` to scan objects added by a commit range, or `-- FILE...` to scan named files. The pre-push wrapper scans the objects and ref names a push sends. This includes commit and annotated tag contents. Missing objects, unreadable inputs, and shallow history fail the scan.

`mise run devtools:prek-install` installs the shared pre-push wrapper, and `mise run bootstrap` calls it. `mise run lint` checks the wrapper with `devtools:check-leak-hook` and scans the tree with `devtools:lint-leaks`. Commit hooks scan staged files and the message. `lint-pr-description` scans the PR draft. CI scans the tree and `origin/main..HEAD` for pull requests.

The gate guards against accidents. It can't catch encoded or split literals, values shorter than four characters, or text typed directly into GitHub. CI has no local private literals and checks only the shared patterns. The gate prints a notice when it doesn't load any private literals.

## Stack secrets

The init one-shot generates the S3 key and the Grafana recovery password on the host that runs the stack. Keep both out of committed files, rendered files, command lines, logs, and task output.

Compose prints the contents of every environment file a model loads. Against the environment file of a deployment, run `config` only with `-q`. To read a resolved model, run `mise run compose-config` instead. It renders with placeholders and loads a dummy file, and it ignores inherited variables. In a task, run `docker inspect` on the stack's containers only with a `-f` template that can't print `Config.Env`. Their environment contains the S3 key.

Published ports bind to 127.0.0.1. Don't add a setting that changes that, because Grafana gives anonymous users the Editor role and whatever fronts the host decides who reaches it.

## Stack tasks

The local tasks need only a Docker engine and set every `O11Y_*` value themselves: `render`, `validate`, `compose-config`, `rustfs-probe` and `smoke`. Run them freely. `deploy-plan` also runs locally and is safe to run, but it reads the real values and prints them. Keep its output in the terminal.

The other tasks act on the deploy host over SSH, each as `bash tools/nas.sh <task>`: `preflight`, `stage`, `gate-test`, `gate-clean`, `deploy`, `rollback`, `status`, `logs`, `down`, `serve-apply`, `serve-status`, `serve-clear` and `grafana-password`. `smoke-remote` doesn't use SSH, but it writes test signals to the deployed stack through the Tailscale Services. Run any of these only when the owner has approved that run. This holds for the read-only ones as well, because each of them connects to the host. The tasks that change state also refuse to start unless `O11Y_CONFIRM` names the task. Set it on the command line of that one run, and never export it or put it in a file.

`tools/nas.bats` covers these tasks against a fake host, with `ssh`, `sudo` and the host's binaries stubbed. Change `tools/nas.sh` through that suite, never by trying a task against the real host. `mise run nas-local-rehearsal` goes further and runs the tasks end to end against the local Docker engine, with `ssh`, `sudo` and `tailscale` stubbed, plus a `git` stub that prints the commit for the copied tree. Its first deploy is of a base commit, `origin/main` by default or the commit named as its argument. After `rollback --previous` to that base, the base's Up panels must show only the jobs the base scrapes. It uses the project names `o11y` and `o11y-gate`, so it refuses to start while either exists on the engine.

What a host task prints can hold deployment paths and names. Never paste its output, a log under `tmp/deploy/`, or `deploy-plan` output into a commit, a pull request, or a comment. Write a short summary by hand instead.

## Tools

mise pins the tools and defines the tasks. The shared half arrives from `tbhb-dev/devtools` through vendir into `.config/mise/conf.d/` and `.devtools/tasks/`. Never edit those two directories by hand. Run `mise run bootstrap` once to sync the payload and install the tools plus the git hooks.

- `mise run lint` runs every lint gate in order.
- `mise run test` runs the test suites.
- `mise run check` runs both.
- `mise run devtools:update-pins <version>` moves every devtools pin together. Redeploy the agent primitives with `mise run apm-sync` instead of a bare `apm install`.

The `guard-markdown` binary backs `lint-markdown-wrap` and the Claude write hook. `mise.toml` pins it through the Go backend at the devtools release, so mise installs it with the toolchain and Renovate can update it. Keep that pin aligned when updating devtools. Run the hooks in the mise environment so the binary is on PATH.

`mise run lint` uses `devtools:check-vendored`, which syncs the payload in place and compares it against the index. Review and stage a payload update before running that gate. The sync can overwrite local edits to vendored files.

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
