---
name: land
description:
  Land an approved pull request by verifying review state, checks, and merge
  readiness, then merging safely.
---

# Land

## Preconditions

- The Linear issue is in `Merging`.
- The latest `## Review Handoff` or a human comment clearly indicates approval.
- The PR branch is current with `upstream/${SYMPHONY_BASE_BRANCH:-main}`.

## Workflow

1. Identify the PR for the current branch.
2. Confirm there are no unresolved actionable review comments.
3. Confirm required checks are passing or explicitly documented as non-blocking.
4. Fetch latest refs and merge the upstream base if needed by using the `pull` skill.
5. Run validation from `AGENTS.md` after any merge/conflict resolution.
6. Merge the PR using the repository's normal GitHub merge policy.
7. Verify the merge result and update Linear according to the active workflow.

## Notes

- Do not merge without explicit human approval.
- Do not push directly to upstream/base branches.
- Do not use force-push except when recovering an issue branch with
  `--force-with-lease` and clear remote-state evidence.
