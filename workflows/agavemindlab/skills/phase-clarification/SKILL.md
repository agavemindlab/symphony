---
name: phase-clarification
description:
  Run requirement clarification for a Symphony-managed Linear ticket before
  implementation planning.
---

# Phase: Clarification

## Goal

Make sure the issue has a clear, safe, testable scope before design or
implementation starts.

## Steps

1. Read the issue description, comments, attachments, labels, links, and current workpad.
2. Identify the problem, why it matters, and observable acceptance signals.
3. If requirements are clear, record the requirement summary and acceptance
   checks in the workpad.
4. If requirements are contradictory, incomplete, or unsafe to infer, create a
   compact `## Review Handoff` with `Status: Waiting for requirement confirmation`.
5. Do not ask one-off interactive questions; batch all blocking decisions into
   the handoff with a recommended default for each.

## Output

- Workpad requirements and acceptance criteria are current, or
- a requirement-confirmation handoff exists and the issue is in `Human Review`.
