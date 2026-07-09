# Agavemindlab Symphony Workflows

This directory is the canonical source for shared Symphony workflow content.
Project-specific workflow directories inherit the shared files with symlinks and
override only the entries that need project-specific behavior.

## Layout

```text
bin/
  symphony-run
workflows/
  agavemindlab/
    WORKFLOW.md
    project.env.defaults
    skills/
      cleanup/
    README.md
  <project>/
    WORKFLOW.md -> ../agavemindlab/WORKFLOW.md
    skills -> ../agavemindlab/skills
    setup.sh (optional)
    teardown.sh (optional)
    project.env
    project.env.local (optional, gitignored)
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

`workflows/agavemindlab/project.env.defaults` contains shared defaults for all
Agavemindlab projects. Each project also has a real `project.env` file in
envfile format; values are quoted so the files can be parsed by dotenv-style
tools and sourced by a shell. An optional gitignored
`workflows/<project>/project.env.local` provides a per-project, machine-local
override layer.

For the env layering rules, profile selection, and manual-run recipe, see
[`bin/README.md`](../../bin/README.md). This section only documents what is
specific to the Agavemindlab workflow namespace.

`project.env` may also define project-specific runtime settings consumed by that
project's `setup.sh`.

Existing project env files use `SYMPHONY_PROJECT_SLUG` with
`tracker.project_slug` and do not need migration. A workflow that watches
multiple Linear projects can use `SYMPHONY_PROJECT_NAMES="grotto,symphony"`;
`workflows/grandline/` is the shared Agavemindlab aggregate target.

`project.env.defaults` currently defines `AUTOMATED_REVIEWER="gl-swe"`, the
shared Agavemindlab automated reviewer used by the `symphony-pr` skill. Keep common
workflow values there instead of duplicating them in every project env file.
Profile env files may fill local defaults, and project env files (or the
optional `project.env.local`) may override them when needed.

## Hooks

The shared `WORKFLOW.md` expects Symphony to expose `SYMPHONY_WORKFLOW_DIR` to
local hooks. The value is the directory that contains the workflow file passed
to the CLI, without resolving through symlinks.

`hooks.after_create` clones `$GITHUB_FORK_OWNER/$SYMPHONY_REPO`, configures the
`agavemindlab/$SYMPHONY_REPO` upstream remote, fetches
`$SYMPHONY_BASE_BRANCH`, runs the project `setup.sh` if it exists, then
symlinks shared skills from `$SYMPHONY_WORKFLOW_DIR/skills/` into the workspace
`.agents/skills/` directory. If the target repository already contains
`.agents/skills/<name>/`, the installer skips that skill and leaves the
repository version in place. Only newly linked skills are added to
`.git/info/exclude`; the committed `.gitignore` is not modified. The hook also
creates `.issue-secrets/` with mode `700` and local-excludes it for
human-provided, issue-scoped secret files.

`hooks.before_remove` runs the project `teardown.sh` if it exists.

When an issue comes from Linear, hooks and Codex startup receive
`SYMPHONY_LINEAR_PROJECT_ID`, `SYMPHONY_LINEAR_PROJECT_SLUG`, and
`SYMPHONY_LINEAR_PROJECT_NAME`. Aggregate workflows can source
`project-for-linear-project.sh` to select the per-project `project.env`,
repository, setup script, and teardown path. That script is a thin wrapper
around the shared `workflows/resolve-project-dir.sh`, which reads the
aggregate's `projects.tsv` (slug → workflows/ dir registry; a `-lite`
aggregate sets `SYMPHONY_PROJECT_DIR_SUFFIX` and symlinks the same registry).
Adding a project to an aggregate = one `projects.tsv` row + its name in
`SYMPHONY_PROJECT_NAMES` in `project.env` (+ the WORKFLOW.md routing
registry for spawned-issue routing).

## Shared Skills

`workflows/agavemindlab/skills/` contains the shared workflow skills installed
into each workspace. The `symphony-cleanup` skill is shared because it only uses Docker's
`com.docker.compose.project` labels and the configured Symphony workspace root
to identify resources left behind by removed workspaces; it does not depend on
any project-specific Compose files or services.

## Project Commands

Shared workflow content must not hard-code project build, test, migration, or
runtime commands. Put project development instructions in the target
repository's `AGENTS.md`, and have agents follow that file during validation.
