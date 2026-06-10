---
name: phase-design
description:
  Run the Design phase of the Symphony workflow. Produce the `## Design`
  Linear artifact with the chosen approach, rationale, and a diagram for
  non-trivial designs. Use after `## Requirements` is accepted (human
  approval or agent auto-advance). Exit by posting the artifact; Main Flow
  then auto-advances to Implementation or stops for human review.
---

# Phase: Design

## Goal

Post (or update) the `## Design` artifact on the Linear issue with:

- Chosen approach direction and rationale
- Key trade-offs and alternatives considered
- Diagram (for non-trivial designs — see Diagram requirement below)
- Intentionally uncovered scope with follow-up issue IDs
- Any newly-discovered risks

## At phase start

Main Flow has already closed `## Requirements` (a `✅` human approval or a
`⏩` agent auto-advance reply) and set `current_phase: Design` before opening
this skill. Just read the `## Requirements` artifact to extract `Primary:`,
`验收标准 S<N>`, and `关键假设` before designing the approach.

If this run is a rework of `## Design` (the artifact has unresolved human
feedback in its thread), follow the same-phase Rework cycle in WORKFLOW.md.

## Discovery / design review

Use the project's configured engineering-review tool if one is available
(e.g., `plan-eng-review`) — adversarially review the chosen approach
across architecture / code quality / tests / performance. If none is
available, enumerate alternatives, consider edge cases and failure modes,
and record analysis in the workpad before writing the approach.

## Diagram requirement

The `## Design` artifact must include a diagram inline when the design has
**any** of:

- Multi-component data flow (≥2 services / queues / stores in the path)
- Async / event-driven sequencing (callbacks, retries, partial-success)
- Migration ordering (forward/backward compat, dual-write windows)
- Security boundary changes (auth, trust zones, secret movement)

Format: mermaid block (preferred) or ASCII art.

## Approach writing rules

The approach is a **high-level direction + rationale**, not an
implementation step list. Implementation breakdown lives in the workpad
Plan at the Implementation phase.

Required content:

- Chosen direction (one or two sentences).
- Key trade-off and why the chosen path was picked over the alternative
  (1-2 alternatives named).
- Diagram inline (per the rule above) for non-trivial designs.
- Intentionally uncovered scope, spun off as a separate ticket via the
  `symphony-issue` skill (autonomous `follow-up`/`related`, or a proposed
  `blocking`/`sub-issue` when it changes this issue's plan); cite the
  resulting issue identifier (e.g. `ENG-123`, bare so Linear renders the
  chip) or the proposal in 未覆盖范围.

## Type-specific writing emphasis

Apply the emphasis matching `Primary:` from the Requirements artifact.

- **Type:Bug** — approach must answer: causal link between fix and root
  cause; sibling code path survey (grep evidence); 治标 vs 治本; data-
  integrity risk. If 治标 or 根因 unknown, explicitly mark as symptomatic
  fix, spin off an investigative follow-up issue via `symphony-issue`, and
  list risks.
- **Type:Feature** — enumerate the edge case matrix (empty / loading /
  error / permission denied / concurrency / large data) and call out
  intentionally uncovered cases.
- **Type:Refactor** — include behavior-invariance argument (existing
  tests + characterization tests) and call-site completeness statement
  (grep evidence + per-site decision).
- **Type:Performance** — include before/after numbers with a reproducible
  measurement command the reviewer can rerun.
- **Type:Migration** — answer all four: forward/backward compatibility
  window; backfill strategy (batch size, throughput, idempotency, failure
  recovery); rollback plan; deploy ordering.
- **Type:Chore** — include breaking-changes review with changelog links
  and per-call-site verification.

## High-impact decision protocol

If the approach has a **high-impact unresolved decision**, do not pick
unilaterally — mark it as `[NEEDS CLARIFICATION: <question>]` in the
artifact and move to Human Review.

High-impact categories: schema/data migrations; dependency changes with
breaking changes; production/shared infrastructure; security/privacy
behavior; public API contracts; irreversible data operations; major UX
tradeoffs.

For ordinary tradeoffs with a safe default, pick the simplest option,
record the decision in the workpad notes, and continue.

## Artifact template

```md
## Design

### 方案（approach）
<chosen direction in one or two sentences>

**选择理由**: <why this path over the main alternative>
**未覆盖范围**: <intentionally out of scope> → follow-up: <ENG-123>

### 图示（diagram; omit for trivial changes）
```mermaid
<diagram>
```

### 风险/注意（risks; omit if none）
- <one sentence per item>
```

## When blocked

When `[NEEDS CLARIFICATION]` markers remain after analysis:

1. Write them inline in the `## Design` artifact.
2. Post or update the artifact comment.
3. Move the issue to `Human Review`.
4. Stop.

Cap at five blocking questions per round.

On resume: read human replies in the artifact thread, replace each marker
with the answered value, then proceed to exit.

## Cross-phase rework

If `Rework` feedback indicates that Requirements need fundamental revision
(problem statement wrong, acceptance criteria invalid) rather than a Design
fix, do not patch it within `## Design`. Follow the cross-phase rework
protocol in WORKFLOW.md: resolve this artifact, resolve `## Requirements`,
update workpad `current_phase: Requirements`, and open `phase-requirements`.

## Exit

### Completeness bar (required to post the artifact)

The artifact is complete enough to post when all of these hold — this is
about form, not correctness:

- `方案（approach）` is complete (no placeholder text).
- Diagram included for non-trivial designs.
- Type-specific approach emphasis satisfied for `Primary:`.
- No unresolved `[NEEDS CLARIFICATION]` markers.

Post or update the `## Design` artifact and set the workpad
`current_phase: Design`. Do **not** move the issue yourself on a clean exit —
hand back one of two outcomes (`advance` / `stop`) for Main Flow to execute.
The decision is yours; Main Flow only carries it out.

### Exit decision: advance or stop

Choose **`advance`** only when **all** of these hold:

- **Fresh run** — not a rework, and the artifact carries no prior human reply.
- **State `In Progress`** — not `Rework`.
- **Confident** — answer honestly: *Will this approach actually solve the
  problem, and is it clearly the right direction, such that a human reviewer
  would very likely approve it as-is?* Yes only if this is the standard or
  clearly-best approach, with no contentious architectural fork, no risky
  bet, and no non-obvious risk a reviewer would balk at.

On `advance`, record `confidence: advance` in the workpad notes; Main Flow
writes the `⏩` reply and opens `phase-implementation` in the same session.

Otherwise choose **`stop`** — Main Flow moves the issue to `Human Review`.
This is the right outcome for a rework, for a human already in the thread,
for the `Rework` state, and for the **complete-but-not-confident** case:
there is a real architectural fork a reasonable reviewer might decide
differently, an uncertain bet, or a non-obvious risk worth a human's eyes
before you build on it. Before stopping for low confidence, surface the
specific point in `风险/注意` and record `confidence: review` in the notes.
**When in doubt, stop** — auto-advance is for the clearly-right design. After
a stop, the human approves by moving the issue back to an active state and
the next session advances to Implementation.

(The "When blocked" path above is the harder stop: an unresolved
`[NEEDS CLARIFICATION]` means the artifact is not even safe to build on, so
it moves to `Human Review` directly.)
