---
name: phase-requirements
description:
  Run the Requirements phase of the Symphony workflow. Turn an issue into
  a `## Requirements` Linear artifact with problem statement, motivation,
  and acceptance criteria locked down. Use at the start of any Todo /
  In Progress / Rework ticket. Exit by posting the artifact and moving to
  Human Review.
---

# Phase: Requirements

## Goal

Post (or update) the `## Requirements` artifact on the Linear issue with
these fields locked down:

- `Primary: Type:<...>` classifier
- `要解决的问题（what）`
- `为什么解决（why）`
- `验收标准（S1, S2, ...）` — every entry passing the 5 rules below

The Design approach is not part of this artifact; it belongs in `## Design`.

## At phase start

Main Flow has already checked out the feature branch (so
`.symphony/workpad.md` is writable) and opens this skill only when
Requirements is the target phase. Two cases:

- **Fresh run** — no `## Requirements` artifact yet, or it has no
  unresolved human feedback. Proceed to Discovery.
- **Rework** — the `## Requirements` artifact has unresolved human feedback
  in its thread. Address that feedback and follow the same-phase Rework
  cycle in WORKFLOW.md when re-posting the artifact.

## Discovery

Use the project's configured discovery tool if one is available (e.g.,
`office-hours`) — interrogate intent, surface ambiguity, stress-test the
problem statement. If none is available, read all issue context
(description, comments, attachments, linked issues, labels) and surface
ambiguities explicitly before writing the artifact.

## `验收标准` — 5 rules

Every `S<N>` entry must satisfy all five:

1. **Technology-agnostic** — written in problem/user language, not
   lint/test/HTTP-code language.
2. **Observable** — names a concrete read mechanism (dashboard / log
   query / error tracker / reproduction path / database read).
3. **Measurable** — number, boolean, or clearly defined state.
4. **Falsifiable** — can be rewritten as "if X then NOT accepted".
5. **Time-bounded** — names how long to observe (e.g., "for 7 days
   post-merge").

Each entry must also be **independently verifiable**. Use stable IDs
(`S1`, `S2`, ...). Design and Implementation reference these IDs.

## `Primary:` type

One of `Bug | Feature | Refactor | Performance | Migration | Chore | Other`.
Use the existing Linear `Type:Xxx` label as the mechanical override; if
none, classify and add the matching label to the issue.

## Type-specific writing emphasis

- **Type:Bug** — `what` must reach the causal mechanism, not a symptom
  restatement. At least one `S<N>` must be bug-specific (error events
  stay at zero for N days / reproduction path no longer triggers).
- **Type:Feature** — `why` names the user/role and their problem today.
  `S<N>` includes a UX critical-path signal and an observability signal.
- **Type:Refactor** — `why` answers "why now". `S<N>` includes a
  no-regression signal (error rate / latency within ±N% of baseline).
- **Type:Performance** — `what` includes bottleneck-localization evidence.
  `S<N>` uses measured signals (p99 < X ms on dashboard Y).
- **Type:Migration** — `what` includes production data scale. `S<N>`
  includes data-integrity signals.
- **Type:Chore** — `S<N>` includes transitive smoke and compatibility
  verification.
- **Type:Other** — explicitly justify why none of the other types apply.

## `[NEEDS CLARIFICATION]` markers

Use `[NEEDS CLARIFICATION: <question>]` inline in the artifact for
ambiguities that block correct implementation and cannot be resolved with
a safe default. Record safe-default resolutions as `Brief 假设: <value>`.

While any marker is unresolved, product implementation code must not start.

## `本地验收不可达` declaration

When the acceptance criteria cannot be verified locally (requires
production scale, real customer data, sustained alert windows), declare
`本地验收不可达：<具体原因>` in `关键假设`. Design and Implementation will
set up substitution paths.

## Artifact template

```md
## Requirements

Primary: Type:<Bug|Feature|Refactor|Performance|Migration|Chore|Other>

要解决的问题（what）:
- <actual problem at mechanism level, not symptom restatement>

为什么解决（why）:
- <motivation: user pain / business constraint / trigger>

验收标准（acceptance）:
- S1: <observable, measurable, falsifiable, time-bounded signal>
- S2: <...>

关键假设（omit if none; required when 本地验收不可达）:
- <one sentence per assumption>

风险/注意（secondary concerns; omit if none）:
- <one sentence per item>
```

## When blocked

When `[NEEDS CLARIFICATION]` markers remain after honest analysis:

1. Write them inline in the `## Requirements` artifact.
2. Post or update the artifact comment.
3. Move the issue to `Human Review`.
4. Stop.

Cap at five blocking questions per round. More signals the issue needs
scope reduction or splitting.

On resume: read human replies in the artifact thread, replace each marker
with the answered value (or `Brief 假设: <value>` for recommended
defaults), then proceed to exit.

## Exit

When all exit conditions are met:

- `Primary:`, `要解决的问题`, `为什么解决`, `验收标准` all filled.
- Every `S<N>` satisfies the 5 rules.
- No unresolved `[NEEDS CLARIFICATION]` markers.

Post or update the `## Requirements` artifact. Update the workpad:
`current_phase: Requirements`. Move the issue to `Human Review` and stop.

The human approves by moving the issue back to an active state. On the next
session, Main Flow detects the approval, writes the approval reply on this
artifact, and advances to Design.
