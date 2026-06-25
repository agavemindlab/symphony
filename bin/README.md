# `bin/symphony-run` — Repository launcher

`bin/symphony-run <project>` is the operator entry point for running Symphony
against a project workflow under `workflows/<project>/`. It composes the
environment, selects the profile, validates required variables, then execs the
Elixir Symphony binary with the project's `WORKFLOW.md`.

```sh
bin/symphony-run <project>
```

`<project>` is a directory name under `workflows/`. `grandline` is an
aggregate Agavemindlab target that watches several Linear projects from one
process.

## Environment layers

The launcher composes environment variables from four ordered layers. Each
later layer overrides earlier layers:

1. **`workflows/<namespace>/project.env.defaults`** — committed shared defaults
   for a workflow namespace (e.g.
   `workflows/agavemindlab/project.env.defaults`,
   `workflows/personal/project.env.defaults`). Optional; the launcher hard-codes
   `workflows/agavemindlab/project.env.defaults` as the only defaults file it
   sources, and skips it silently if missing.
2. **`~/.config/symphony/<profile>.env`** — operator profile. Machine-local, not
   in any repo, shared across every project that selects the same profile.
   Required (the launcher exits if missing). Must define `LINEAR_API_KEY`.
3. **`workflows/<project>/project.env`** — committed project settings.
   Required. Must define one of `SYMPHONY_PROJECT_SLUG`,
   `SYMPHONY_PROJECT_SLUGS`, `SYMPHONY_PROJECT_NAME`, or
   `SYMPHONY_PROJECT_NAMES`. Single-project workflows also define
   `SYMPHONY_BASE_BRANCH`, `SYMPHONY_REPO`, and `SYMPHONY_PROFILE`; aggregate
   workflows resolve repo/base per issue.
4. **`workflows/<project>/project.env.local`** — machine-local per-project
   overrides. Optional; gitignored via `*.env.local` in the repo root
   `.gitignore`. Use this layer for values that
   - must not be committed (host-only paths, vault password file paths), AND
   - must not leak into other projects that share the same operator profile.

   Example: setting `ANSIBLE_VAULT_PASSWORD_FILE` to a file outside the
   workspace for a single infra project, without exposing the path to unrelated
   projects on the same profile.

Later files override earlier files, so the gitignored `project.env.local` (when
present) has the highest precedence.

## Profile selection

Because the profile name must be known before sourcing the operator profile,
the launcher sources `project.env` once before profile selection (for bootstrap
values like `SYMPHONY_PROFILE`), then re-sources `project.env` and
`project.env.local` again after the profile so the layer ordering above is
preserved.

The profile is picked in this order, taking the first non-empty value:

1. Caller-provided `SYMPHONY_PROFILE` already in the environment.
2. `SYMPHONY_PROFILE` set in `project.env`.
3. `grandline`.

## Other exports

After all layers load, the launcher additionally exports:

- `GH_PROMPT_DISABLED=true` (unless already set)
- `SYMPHONY_WORKSPACE_ROOT` (defaults to `$HOME/symphony-workspaces` if unset)
- `SYMPHONY_PROFILE` (the resolved profile name)

Set `SYMPHONY_PORT` in any environment layer to pass `--port` to the Symphony
CLI and enable the dashboard.

## Manual run (without the launcher)

Reproduce the layer order yourself:

```sh
set -a
source workflows/agavemindlab/project.env.defaults
source workflows/<project>/project.env
profile="${SYMPHONY_PROFILE:-grandline}"
source "$HOME/.config/symphony/$profile.env"
source workflows/<project>/project.env
[ ! -f workflows/<project>/project.env.local ] || \
  source workflows/<project>/project.env.local
set +a
./elixir/bin/symphony workflows/<project>/WORKFLOW.md
```
