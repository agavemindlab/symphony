---
name: phase-design
description:
  Run solution design for a Symphony-managed Linear ticket after requirements
  are clear.
---

# Phase: Design

## Goal

Choose the simplest safe implementation approach and make high-impact decisions
explicit before code changes.

## Steps

1. Map the files, modules, data flow, and tests likely to change.
2. Prefer existing project patterns and documented conventions in `AGENTS.md`.
3. For non-trivial designs, include a short diagram or data-flow sketch in the workpad.
4. If the approach involves a high-impact unresolved decision, create a compact
   `## Review Handoff` with `Status: Waiting for plan confirmation`.
5. For ordinary tradeoffs with a safe default, decide, record the rationale, and continue.

## Output

- Workpad plan has a clear approach and validation design, or
- a plan-confirmation handoff exists and the issue is in `Human Review`.
