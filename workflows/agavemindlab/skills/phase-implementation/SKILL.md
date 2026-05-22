---
name: phase-implementation
description:
  Execute the approved plan with tests, validation, commits, PR publication,
  and review handoff.
---

# Phase: Implementation

## Goal

Produce a focused PR that satisfies the issue acceptance criteria and can be
reviewed from a compact `## Review Handoff`.

## Steps

1. Keep the persistent `## Codex Workpad` current.
2. For behavior changes, write a failing test first, verify it fails for the
   expected reason, implement the minimal passing change, and rerun the test.
3. Follow validation commands from the repository's `AGENTS.md`.
4. Commit coherent changes with the `commit` skill.
5. Push and create/update the PR with the `push` skill.
6. Run the PR feedback sweep. Treat actionable comments as blocking until code,
   tests, docs, or same-thread pushback resolves them.
7. Before handoff, rerun required validation and update the workpad checkboxes.
8. Create a fresh `## Review Handoff` with `Status: Waiting for PR review`, then
   move the issue to `Human Review`.

## Blockers

Use `Status: Blocked` only for true missing auth, permissions, secrets, required
tools, or validation environments that cannot be resolved in-session.
