---
name: symphony-cleanup
description: Prune Docker resources left behind by removed Symphony workspaces.
---

# Cleanup

Use this skill when a Symphony workspace directory has been removed but Docker
resources for its Compose project may still exist.

## Safety Model

- Dry-run is the default. The script prints the resources it would remove and
  exits without changing Docker state.
- The script only considers Docker resources with a
  `com.docker.compose.project` label.
- The project label must look like a Symphony issue workspace project, and the
  Docker resource name must be prefixed by that project name.
- Existing workspace directories under `$SYMPHONY_WORKSPACE_ROOT` are always
  preserved.

## Commands

From the repository root:

```bash
python3 .agents/skills/symphony-cleanup/scripts/docker_workspace_gc.py
```

To apply the cleanup:

```bash
python3 .agents/skills/symphony-cleanup/scripts/docker_workspace_gc.py --apply
```

Use an explicit root when `$SYMPHONY_WORKSPACE_ROOT` is not set:

```bash
python3 .agents/skills/symphony-cleanup/scripts/docker_workspace_gc.py \
  --workspace-root /path/to/symphony-workspaces
```
