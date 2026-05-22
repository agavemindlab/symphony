# Agavemindlab Symphony Workflows

This directory is the canonical source for shared Symphony workflow content.
Project-specific workflow directories inherit the shared files with symlinks and
override only the entries that need project-specific behavior.

## Layout

```text
workflows/
  symphony-run
  agavemindlab/
    WORKFLOW.md
    skills/
    README.md
  <project>/
    WORKFLOW.md -> ../agavemindlab/WORKFLOW.md
    skills -> ../agavemindlab/skills
    setup.sh (optional)
    teardown.sh (optional)
    project.env
```

`workflows/agavemindlab/` is canonical. Each `workflows/<project>/` directory
contains symlinks for inherited shared entries and real files for project
overrides.

## Override Rule

- A symlink to `../agavemindlab/<entry>` means the project inherits the shared
  entry.
- A real file or directory in `workflows/<project>/` replaces that entry for the
  project.
- There is no `extends`, deep merge, or prompt composition layer. The directory
  entries are the override mechanism.

## Project Environment

Each project has a real `project.env` file in envfile format. Values are quoted
so the file can be parsed by dotenv-style tools and sourced by a shell.

Operators should usually start Symphony through the repository launcher:

```sh
workflows/symphony-run <project>
```

The launcher loads `workflows/<project>/project.env`, then loads
`~/.config/symphony/<profile>.env`. The profile is selected in this order:
caller-provided `SYMPHONY_PROFILE`, project `SYMPHONY_PROFILE`, then
`grandline`.

For manual runs, export variables while sourcing the envfile:

```sh
set -a; source workflows/<project>/project.env; set +a
./bin/symphony workflows/<project>/WORKFLOW.md
```

`project.env` must define `SYMPHONY_PROJECT_SLUG`, `SYMPHONY_BASE_BRANCH`,
`SYMPHONY_REPO`, and `SYMPHONY_PROFILE`. It may also define project-specific
runtime settings consumed by that project's `setup.sh`.

## Hooks

The shared `WORKFLOW.md` expects Symphony to expose `SYMPHONY_WORKFLOW_DIR` to
local hooks. The value is the directory that contains the workflow file passed
to the CLI, without resolving through symlinks.

`hooks.after_create` clones `$GITHUB_FORK_OWNER/$SYMPHONY_REPO`, configures the
`agavemindlab/$SYMPHONY_REPO` upstream remote, fetches
`$SYMPHONY_BASE_BRANCH`, runs the project `setup.sh` if it exists, then
installs shared skills from `$SYMPHONY_WORKFLOW_DIR/skills/` into the workspace
`.agents/skills/` directory. If the target repository already contains
`.agents/skills/<name>/`, the installer skips that skill and leaves the
repository version in place. Only newly installed skills are added to
`.git/info/exclude`; the committed `.gitignore` is not modified.

`hooks.before_remove` runs the project `teardown.sh` if it exists.

## Project Commands

Shared workflow content must not hard-code project build, test, migration, or
runtime commands. Put project development instructions in the target
repository's `AGENTS.md`, and have agents follow that file during validation.
