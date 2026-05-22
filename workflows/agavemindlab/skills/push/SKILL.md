---
name: push
description:
  Push current branch changes to origin and create or update the corresponding
  pull request.
---

# Push

## Goals

- Push the current issue branch to `origin`.
- Create or update the GitHub PR for the branch.
- Keep PR title and body aligned with the total branch diff.

## Steps

1. Confirm the current branch is an issue feature branch, not a protected/base branch.
2. Run the required validation from the repository's `AGENTS.md`.
3. Push with upstream tracking: `git push -u origin HEAD`.
4. If push is rejected because the remote branch moved, use the `pull` skill to merge the latest base and retry. Use `--force-with-lease` only after verifying no unrelated human work advanced the remote branch.
5. Create a PR if one does not exist; otherwise update the open PR.
6. Fill the PR body from `.github/pull_request_template.md` when the repository provides one.
7. If the repository documents a PR-body validation command, run it and fix failures.
8. Ensure the PR is linked to the Linear issue.

## Notes

- Do not push to `upstream` or any protected/base branch.
- Do not switch remotes or authentication methods to bypass permission errors.
- Keep validation project-specific by following `AGENTS.md`.
