---
name: phase-design
description:
  Run Gate 2 (solution design) of the Symphony workflow. Fill the Spec's
  `解决方案（approach）` field with a chosen approach + rationale + a
  diagram for non-trivial designs, and validate it against architecture /
  edge cases / risks before writing implementation code. Use after Gate 1
  exits (Spec what/why/acceptance locked, no `[NEEDS CLARIFICATION]`
  markers). Exit when the approach is filled and any high-impact
  unresolved decision is human-confirmed.
---

# Phase 2: Solution Design

## Goal

Update the persistent `## Spec` Linear comment so that:

- `解决方案（approach）` is complete (replaces the `<Gate 2 待补>`
  placeholder from Gate 1).
- For non-trivial designs (multi-component data flow, async / event
  sequencing, migration ordering, security boundary changes), the
  `approach` includes a diagram (mermaid or equivalent) inline.
- `风险/注意` carries any newly-discovered trade-offs that emerged from
  review.

The Spec's other fields (`Primary`, `要解决的问题`, `为什么解决`,
`验收标准`) were locked at Gate 1 (phase-clarification). Touch them only
if review surfaces a contradiction; if so, treat that as a Gate 1
re-entry.

## Default skill to invoke

Use the project's configured engineering-review tool if one is available
(e.g., a `plan-eng-review` equivalent) — adversarially review the chosen
approach across architecture / code quality / tests / performance, with
opinionated recommendations. Check whether such a tool is installed in
`.agents/skills/` or available in the session environment before
proceeding.

If no such tool is available, conduct manual design review: enumerate
alternatives, consider edge cases and failure modes per the type-specific
emphasis below, identify high-impact decisions, and record analysis in the
workpad before writing the approach.

Either way, feed the review the Spec (with `approach` draft) plus any
pre-existing design notes. Bounce findings back into Spec edits until the
design is locked.

If the default path was skipped or altered, record
`Skipped design review tool: <reason>` in workpad `Notes` per WORKFLOW.md
`Related skills`.

## Diagram requirement

`解决方案（approach）` must include a diagram inline when the design has
**any** of:

- multi-component data flow (≥2 services / queues / stores in the path),
- async / event-driven sequencing (callbacks, retries, partial-success
  handling),
- migration ordering (forward/backward compat, dual-write windows),
- security boundary changes (auth, trust zones, secret movement).

Format: mermaid block (preferred) or ASCII art. Trivial-Spec issues
skip this requirement.

A diagram is required even when the design "feels obvious" — the act of
drawing it is the cheapest way to catch missing edges, hidden
dependencies, and unhandled error paths. A reviewer reading the Spec
should be able to trace the data path without opening the code.

## `解决方案（approach）` writing rules

The `approach` field is a **high-level direction + rationale**, not an
implementation step list. Implementation breakdown lives in the Workpad
`Plan` at Gate 3 (phase-implementation).

Required content (every approach):

- Chosen direction (one or two sentences).
- Key trade-off and why the chosen path was picked over the alternative
  (1-2 alternatives named).
- Intentionally uncovered scope + follow-up issue ID (tag as
  `blocking-related` or `optional-related`).
- Diagram inline (per the rule above) for non-trivial designs.

### Type-specific writing emphasis at this gate

Apply the emphasis matching `Primary:` to the `approach` field. (The
non-approach side — `要解决的问题` / `为什么解决` / `验收标准` — was
emphasis-applied at Gate 1.)

- **Type:Bug** — `approach` must explicitly answer:
  - Causal link: in one sentence, how does this fix causally address
    the root cause named in `要解决的问题`? If the link is non-obvious
    (the fix is a retry / fallback / suppression / boundary-narrowing
    rather than direct cause-elimination), name the specific failure
    mode the fix removes. A fix whose causal link to the root cause
    cannot be stated in one sentence is either a guess or symptomatic;
    mark it as such.
  - Sibling code path survey: which other call sites share the same
    pattern, and what was found, with grep / file evidence.
  - 治标 vs 治本: if 治标 or 根因 unknown, an investigative follow-up
    issue ID is required and classified as `blocking-related` or
    `optional-related`.
  - Data-integrity risk of the fix (e.g., does salvage commit partial
    data?).
  - If 治标 or 根因 unknown, explicitly mark the fix as a symptomatic
    fix in `approach`, file an investigative follow-up issue ID, and
    add 数据完整性 / 同类路径 risks to `风险/注意`.
- **Type:Feature** — `approach` enumerates the edge case matrix (empty
  / loading / error / permission denied / concurrency / large data) and
  calls out intentionally uncovered cases with follow-up IDs.
- **Type:Refactor** — `approach` includes a behavior-invariance
  argument (existing tests + characterization tests if needed) and a
  call-site completeness statement (grep evidence + per-site decision).
- **Type:Performance** — `approach` includes before/after numbers with
  a reproducible measurement command the reviewer can rerun.
- **Type:Migration** — `approach` answers all four:
  - Forward / backward compatibility window across deploys.
  - Backfill strategy (batch size, throughput, idempotency, failure
    recovery).
  - Rollback plan with a verified down migration.
  - Deploy ordering (migration first / code first / dual-write).
- **Type:Chore (deps/tooling)** — `approach` includes breaking-changes
  review with changelog links and per-call-site verification (grep
  imports/calls + per-call decision).
- **Type:Other** — apply whatever emphasis matches the secondary type
  noted in `风险/注意`.

## High-impact decision protocol

If the approach has a **high-impact unresolved decision**, do not pick
unilaterally. Hand off with `Status: Waiting for plan confirmation`.

High-impact categories:

- Schema / data migrations.
- Dependency changes (new packages, version bumps with breaking
  changes).
- Production / shared infrastructure (queues, caches, networking).
- Security / privacy behavior (auth, secret handling, PII flows).
- Public API contracts (request / response shape, breaking changes).
- Irreversible data operations.
- Major UX / product tradeoffs.

For ordinary implementation tradeoffs with a safe default (which struct
to use, which file to put a helper in), pick the simplest low-risk
option and record the decision in the workpad — do not block on the
human.

### Bridge to Linear via the unattended protocol

When the design-review tool (or the agent's own analysis) surfaces
findings the human must approve, bridge them to Linear instead of
querying interactively. Follow WORKFLOW.md `Skill interaction protocol
(unattended bridge)`: collect every such finding across the full review,
write each as `[NEEDS CLARIFICATION:<question>]` inline in the relevant
Spec field (most often `approach` or `风险/注意`), batch into one
`Status: Waiting for plan confirmation` handoff (sub-template below),
and move the issue to `Human Review`. Cap at five questions per round.
Findings the agent can resolve unilaterally per the high-impact category
list above are recorded in the workpad and resolved without bouncing.

### Handoff sub-template

Lifecycle invariants (marker, status enum, fresh-comment-per-transition,
shared writing rules) live in WORKFLOW.md `Review handoff lifecycle`.
Use this body shape:

````md
## Review Handoff

**Status**: Waiting for plan confirmation
**Spec**: [Spec](URL)

### 阻塞决策
（每条 1:1 反射 Spec 中未解的 `[NEEDS CLARIFICATION: ...]` marker）

1. **<问题>**
   - **A（推荐）**: <选项> — <为什么>
   - **B**: <选项>
   - **接受 A 后 agent 会做什么**: <一句>
2. ...

**Human action needed**: <一句中文行动请求，要求人类逐条确认或显式 override>
````

### After human answers (resume protocol)

The agent's first edit on resume is to replace each resolved marker in
the Spec:

- write the answered value inline, **or**
- record `Brief 假设: <value>` when the agent took its recommended
  default.

Then sync the workpad's `Acceptance Criteria` mirror if the resolution
materially changed acceptance, and continue to Gate 3
(phase-implementation).

## Exit conditions (advance to Gate 3)

This phase exits and Gate 3 (phase-implementation) starts when **all** of:

- `解决方案（approach）` is filled (no `<Gate 2 待补>` placeholder).
- Diagram inline for non-trivial designs (or Trivial-Spec issue waived
  the requirement).
- Type-specific approach emphasis satisfied for `Primary:`.
- No unresolved `[NEEDS CLARIFICATION]` markers in `approach` or
  `风险/注意`.
- High-impact decisions either resolved or human-confirmed via
  plan-confirmation handoff.

Product implementation code (changes that will land in the PR diff)
starts by **entering** Gate 3 (`phase-implementation`) once this phase
has exited.
