---
name: symphony-pull
description:
  Merge the latest upstream base branch into the current feature branch and
  resolve conflicts.
---

# Pull

## Base Branch

Use `upstream/${SYMPHONY_BASE_BRANCH:-main}` unless the user or repository
instructions explicitly name another base.

## Workflow

1. Verify the working tree is clean or commit/stash intended changes before merging.
2. Enable rerere locally:
   - `git config rerere.enabled true`
   - `git config rerere.autoupdate true`
3. Fetch refs:
   - `git fetch upstream`
   - `git fetch origin`
4. If the current feature branch already exists on `origin`, pull it first with
   `git pull --ff-only origin $(git branch --show-current)`.
5. Merge the base:
   - `git -c merge.conflictstyle=zdiff3 merge upstream/${SYMPHONY_BASE_BRANCH:-main}`
6. Resolve conflicts by reading both sides, preserving behavior intentionally,
   and keeping edits minimal.
7. Run validation from `AGENTS.md`.
8. Record the merge source, conflict result, and resulting short SHA in the
   workpad.

## Conflict Guidance

- Inspect `git status`, `git diff --merge`, and relevant file history before editing.
- Prefer semantic resolutions over blindly choosing ours/theirs.
- Check for conflict markers with `git diff --check`.
- Ask through the workflow handoff only when the correct resolution depends on
  product intent that is not inferable from code, tests, or documentation.
