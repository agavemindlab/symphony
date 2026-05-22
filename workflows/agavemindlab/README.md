# Agavemindlab Symphony Workflows

This directory is the canonical source for shared Symphony workflow content.
Project-specific workflow directories inherit the shared files with symlinks and
override only the entries that need project-specific behavior.

## Layout

```text
workflows/
  agavemindlab/
    WORKFLOW.md
    skills/
    README.md
  <project>/
    WORKFLOW.md -> ../agavemindlab/WORKFLOW.md
    skills -> ../agavemindlab/skills
    setup.sh
    teardown.sh
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

Each project has a real `project.env` file. Operators source it before starting
Symphony:

```sh
source workflows/<project>/project.env
./bin/symphony workflows/<project>/WORKFLOW.md
```

`project.env` must define `SYMPHONY_PROJECT_SLUG`. It may also define
project-specific runtime settings such as `SYMPHONY_BASE_BRANCH` or environment
variables consumed by that project's `setup.sh`.

## Hooks

The shared `WORKFLOW.md` expects Symphony to expose `SYMPHONY_WORKFLOW_DIR` to
local hooks. The value is the directory that contains the workflow file passed
to the CLI, without resolving through symlinks.

`hooks.after_create` runs the project `setup.sh`, then installs shared skills
from `$SYMPHONY_WORKFLOW_DIR/skills/` into the workspace `.agents/skills/`
directory. If the target repository already contains `.agents/skills/<name>/`,
the installer skips that skill and leaves the repository version in place. Only
newly installed skills are added to `.git/info/exclude`; the committed
`.gitignore` is not modified.

`hooks.before_remove` runs the project `teardown.sh`.

## Project Commands

Shared workflow content must not hard-code project build, test, migration, or
runtime commands. Put project development instructions in the target
repository's `AGENTS.md`, and have agents follow that file during validation.
