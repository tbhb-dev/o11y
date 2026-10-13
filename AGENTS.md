# Agent instructions

Guidance for AI coding agents working in this repository. This file is the canonical source for every harness. `CLAUDE.md` points here, and the agy command-line tool reads only this file.

## Scope

This repository holds configuration for a self-hosted observability stack built from Grafana, Loki, Tempo, Mimir and Grafana Alloy, run with Docker Compose. It contains YAML and Alloy configuration, shell scripts, mise tasks that deploy over SSH, and Markdown docs. It has no Go or Python app code. The one Python file, `tools/apm_audit.py`, belongs to the toolchain.

The repository is at the bootstrap stage, and the stack itself is still to come. Compose and Alloy validation is a follow-up that needs a human decision on which tool joins the shared baseline.

## Public repository

This repository is public. Never commit an internal hostname, tailnet name, IP address, deployment path, username on an internal host, or password manager reference. Those values live in `mise.local.toml`, which git ignores. `mise.local.toml.example` is the tracked template and holds placeholders only.

Tasks read these values from the environment, so no private value appears in `mise.toml` or a script. Resolve a secret at the moment of use inside the task body. Keep Compose settings in the task environment instead of a committed `.env` file. Run `mise fmt` after editing `mise.local.toml`, because `mise run lint` format-checks it.

Check the staged diff against that list before every commit. `tools/check-leaks.sh` does it mechanically, as the next section describes.

## Private values

`tools/check-leaks.sh` stops private values from reaching a commit, using two sets of rules over the same text.

The first set matches private literals in every file, ignoring case. The literals are the values of `O11Y_SSH_HOST`, `O11Y_REMOTE_DIR`, `O11Y_REMOTE_TAILSCALE`, `O11Y_TAILNET_DOMAIN` (and its first label) and `O11Y_NODE_ADDR`, plus each entry of the comma-separated `O11Y_PRIVATE_STRINGS`. A value under four characters matches too much. The script skips it and warns.

The second set matches shapes that identify a private network whatever the value. These are password manager references, tailnet host names other than `example.ts.net`, tailnet addresses, private IPv4 addresses, and path shapes from the network-attached storage host (a `/volume<N>` shared folder, and the services and packages trees under `/var`), whether the path is the root itself or something below it. The vendored and deployed trees (`.claude/`, `.agents/`, `.devtools/`, `.config/mise/conf.d/` and `.vale/`) and the checker's own two files skip this set but not the first.

In documentation and examples, write a placeholder such as `example.ts.net`, `nas.example.invalid`, `192.0.2.x` (the documentation range) or `/srv/o11y`, or write the variable name, such as `$O11Y_REMOTE_DIR`. Scans cover file paths (both sides of a rename) and binary files as raw bytes, as well as text, so a private name in a filename counts. The range and push modes also cover commit messages, merges, and annotated tags. A finding gives the file, the line, and the rule or variable. It never gives the matched text, and a location that matches a rule itself, such as a path with a private name, appears as an opaque `path#` identifier. Error messages never repeat an argument.

The script has four modes. With no arguments it scans the working tree: tracked files plus new files that git doesn't ignore. `--staged` scans the index blobs of staged files, so a private value you staged and then cleaned from the working file still fails. `--range A..B` scans the added lines and the message of every commit in the range. File arguments scan exactly those files. `--pre-push` scans what a push sends that the destination remote lacks. Given the ref-update lines git passes a hook, it scans each one. prek doesn't pass them on, so under prek it scans every commit and annotated tag reachable from any local branch or tag that the destination's remote-tracking refs lack. That can include local work the push doesn't send. When the push URL differs from the remote's fetch URL, the tracking refs say nothing about the destination. The scan then covers everything reachable.

At commit the hook runs `--staged`, then scans the message file, and at push it runs `--pre-push`. `mise run lint` scans the tree, and `lint-pr-description` adds `PR_AGENTDESC.md`. CI scans the tree and `--range origin/main..HEAD`.

Coverage has limits. Only the second set runs in CI, because the private values never leave the owner's machine. It catches address and path shapes but not an arbitrary host name or login, and the script prints a notice whenever it runs without private values. Machines that have `mise.local.toml` enforce the private literals when you commit and when you push. GitHub's web interface is unchecked, so a pull request title, a review comment or any text typed there can still leak. History already pushed stays unchecked too. Some values still get through. The check misses a value that's URL-encoded or otherwise transformed, a value split across lines, and a literal under four characters. An entry of `O11Y_PRIVATE_STRINGS` can't contain a comma. With prek, the pre-push stage skips a push that brings new commits to nothing, so a push of only a tag on a commit the remote already has escapes the scan. The check does cover tags sent together with commits.

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
