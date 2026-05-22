---
name: phase-merge-and-confirm
description:
  Handle the Merging state after human approval, including land flow and final
  confirmation.
---

# Phase: Merge And Confirm

## Goal

Land an approved PR safely and verify the issue objective after merge.

## Steps

1. Verify the issue is in `Merging`.
2. Confirm the latest handoff or human comment clearly approves merging.
3. Open and follow `.agents/skills/land/SKILL.md`.
4. After merge, verify the issue objective using evidence available from tests,
   checks, or documented runtime validation.
5. Update the workpad with merge and verification evidence.
6. Move the issue to `Done` only when the workflow explicitly allows it;
   otherwise create a completion-confirmation handoff.
