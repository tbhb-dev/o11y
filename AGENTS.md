# Agent instructions

Guidance for AI coding agents working in this repository. This file is the canonical source for every harness. `CLAUDE.md` points here, and the agy command-line tool reads only this file.

## Scope

This repository holds configuration for a self-hosted observability stack built from Grafana, Loki, Tempo, Mimir and Grafana Alloy, run with Docker Compose. It contains YAML and Alloy configuration, shell scripts, mise tasks that deploy over SSH, and Markdown docs. It has no Go or Python app code. The one Python file, `tools/apm_audit.py`, belongs to the toolchain.

One Compose project runs the stack, with RustFS as the S3 object store for Loki, Tempo, and Mimir. To check it, run `mise run validate`, `mise run rustfs-probe` and `mise run smoke`, each of which needs a Docker engine.

## Public repository

This repository is public. Never commit an internal hostname, tailnet name, IP address, deployment path, username on an internal host, or password manager reference. Those values live in `mise.local.toml`, which git ignores. `mise.local.toml.example` is the tracked template and holds placeholders only.

Tasks read these values from the environment, so no private value appears in `mise.toml` or a script. Resolve a secret at the moment of use inside the task body. Keep Compose settings in the task environment instead of a committed `.env` file. Run `mise fmt` after editing `mise.local.toml`, because `mise run lint` format-checks it.

Check the staged diff against that list before every commit. `tools/check-leaks.sh` does it mechanically, as the next section describes.

## Private values

`tools/check-leaks.sh` stops private values from reaching a commit, using two sets of rules over the same text.

Private literals form the first set. It matches them in every file, ignoring case. The literals are the values of `O11Y_SSH_HOST`, `O11Y_REMOTE_DIR`, `O11Y_REMOTE_TAILSCALE`, `O11Y_TAILNET_DOMAIN` (and its first label) and `O11Y_NODE_ADDR`, plus each entry of the comma-separated `O11Y_PRIVATE_STRINGS`, the deploy host's own name, which stage and gate-test read over SSH into `tmp/deploy/host-name`, and `O11Y_CLUSTER` when it names something other than its default, `o11y`. A value under four characters matches too much. The script skips it and warns.

The second set matches shapes that identify a private network whatever the value, namely password manager references, tailnet host names other than `example.ts.net`, tailnet addresses, private IPv4 addresses, and path shapes from the network-attached storage host (a `/volume<N>` shared folder, and the services and packages trees under `/var`), whether the path is the root itself or something below it. The vendored and deployed trees (`.claude/`, `.agents/`, `.devtools/`, `.config/mise/conf.d/` and `.vale/`) and the checker's own two files skip this set but not the first.

In documentation and examples, write a placeholder such as `example.ts.net`, `nas.example.invalid`, `192.0.2.x` (the documentation range) or `/srv/o11y`, or write the variable name, such as `$O11Y_REMOTE_DIR`. A finding gives a location and the rule or variable, and never the matched text. If the location matches a rule itself, as a path with a private name does, it appears as an opaque `path#` identifier. Errors don't repeat an argument.

The script has four modes. With no arguments it scans the working tree: tracked files plus new files that git doesn't ignore. `--staged` scans the index blobs of staged files and their paths, so a private value you staged and then cleaned from the working file still fails. `--range A..B` scans every object the range adds, and `--pre-push` does the same for what a push sends. File arguments scan exactly those files.

Range and push scans read whole objects through `git cat-file`, never a diff. The scan reads blobs and tree entries. It also reads each path in the trees of the listed commits, submodule entries included but not entered. A blob skips the pattern rules only when each of its paths is exempt. Commit objects count whole, including their author and committer lines, and annotated tag objects do too. A push adds the ref names. For each ref line git gives the pre-push hook, the scan covers the objects reachable from the pushed commit that the destination lacks. The destination has the line's own remote commit. When a ref is new, or names a commit this clone lacks, the scan also runs `git ls-remote` against the URL git passed the hook and treats every commit it reports as present. Remote-tracking refs play no part, and the script doesn't print the URL. The scan fails when `ls-remote` fails, as the push would. An empty destination gets a scan of the whole history. A missing object, a failed git command, an unreadable list of private values, a shallow repository, or a mismatch between objects listed and objects read ends the scan with exit status 2, and so blocks the push. The installed hook passes `--pre-push-hook`, under which no ref lines means nothing to push. It blocks the push if it can't buffer the lines from git. A manual `--pre-push` with no lines scans the history behind the checked-out commit.

At commit the hooks run `--staged` and scan the message file. At push, `tools/install-pre-push.sh` puts the check in front of prek's pre-push hook, because prek hides the ref lines from its hooks. `mise run bootstrap` installs it, and `mise run lint` fails locally when it's missing. `mise run lint` also scans the tree, and `lint-pr-description` adds `PR_AGENTDESC.md`. CI scans the tree and `--range origin/main..HEAD`.

The check guards against accidents in a cooperative workflow. It doesn't catch a value that's URL-encoded or otherwise transformed, a value split across lines, or a literal under four characters, and an entry of `O11Y_PRIVATE_STRINGS` can't contain a comma. It doesn't stop `git push --no-verify`, a clone without the hook installed, or text typed into GitHub, such as a pull request title or review comment. Only the second set runs in CI, because the private values never leave the owner's machine, so CI catches address and path shapes but not an arbitrary host name or login. The script prints a notice whenever it runs without private values. History already pushed isn't rechecked. When you run `--pre-push` by hand without ref lines, it scans the full history behind your current commit and so reports pattern hits in old history. A branch cut before this check merged has no `tools/check-leaks.sh`. The installed hook then prints one warning and skips the check, which leaves a transitional gap on such branches.

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
