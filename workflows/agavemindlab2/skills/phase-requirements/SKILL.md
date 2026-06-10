---
name: phase-requirements
description:
  Run the Requirements phase of the Symphony workflow. Turn an issue into
  a `## Requirements` Linear artifact with problem statement, motivation,
  and acceptance criteria locked down. Main Flow opens this skill only when
  Requirements is the target phase (a fresh Todo / In Progress ticket, or a
  Rework that routes back here). Exit by posting the artifact; Main Flow then
  auto-advances to Design or stops for human review.
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

## Sub-issue: inherit the parent's scope

If this issue has a **parent** (it was created as a sub-issue), its
requirements are a *slice* of the parent, not a fresh problem. Before writing
the artifact:

- Read the parent's `## Requirements` (and `## Design` if posted) to learn the
  already-settled problem framing and `S<N>` acceptance criteria.
- Scope this artifact to **only this child's slice**. Do not re-derive or
  restate the parent's full requirements.
- **Inherit** the parent's acceptance criteria that this slice carries (cite
  them as the parent's `S<N>`, e.g. `继承父 issue ENG-123 的 S2`) rather than
  inventing parallel ones; add new `S<N>` only for behavior unique to this
  child.
- If the slice conflicts with the parent's framing, that is a real ambiguity —
  raise it as `[NEEDS CLARIFICATION]` instead of silently overriding the
  parent.

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

One of `Bug | Feature | Refactor | Performance | Migration | Chore | Spike | Other`.
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
- **Type:Spike** — investigation / research / 技术选型, where the deliverable
  is a documented decision or set of findings, **not** shipped code. `要解决的
  问题` states the question(s) to answer; each `S<N>` is decision-shaped — a
  specific question answered with concrete, checkable evidence and a recorded
  recommendation. See "Non-shipping issues" below for how the 5 rules relax and
  how the pipeline terminates.
- **Type:Other** — explicitly justify why none of the other types apply.

## Non-shipping issues (Spike / investigation)

A `Type:Spike` issue answers a question; it does not ship a feature. Two
things differ from a normal issue.

**Acceptance relaxes** (only for `Type:Spike`): rules 1, 3, 4 still hold, but

- rule 2 (observable read mechanism) becomes **evidence a reviewer can
  independently check** — a benchmark output, a throwaway prototype branch, a
  comparison table, a linked artifact;
- rule 5 (time-bounded) is **dropped** — a spike concludes at decision time,
  not after an observation window.

**The pipeline terminates early.** The deliverable is a findings /
recommendation artifact, not a shippable PR. A spike normally ends at
`Human Review` after Implementation, and the human moves it to `Done`; it
reaches `Merging` / Deployment only if it also produced a real PR worth
landing (e.g. an ADR or docs commit). Design becomes an investigation plan and
Implementation produces the findings — see those skills' `Type:Spike` notes.

**Bounce a pure question.** If the issue is a question or discussion with no
investigation the agent can actually perform (only a human can answer), do not
run the pipeline: state this in the `## Requirements` artifact, `@`-mention the
issue's `creator`, move the issue to `Human Review`, and stop.

## `[NEEDS CLARIFICATION]` markers

Use `[NEEDS CLARIFICATION: <question>]` inline in the artifact for
ambiguities that block correct implementation and cannot be resolved with
a safe default. Record safe-default resolutions in `关键假设` as
`<value>（假设）`.

While any marker is unresolved, product implementation code must not start.

## `本地验收不可达` declaration

When the acceptance criteria cannot be verified locally (requires
production scale, real customer data, sustained alert windows), declare
`本地验收不可达：<具体原因>` in `关键假设`. Design and Implementation will
set up substitution paths.

## Artifact template

```md
## Requirements

Primary: Type:<Bug|Feature|Refactor|Performance|Migration|Chore|Spike|Other>

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
scope reduction or splitting — when a split is warranted, propose `sub-issue`
decomposition via the `symphony-issue` skill (consent-gated: it posts a
`## 建议新建 issue` proposal and creates nothing until a human consents).

On resume: read human replies in the artifact thread. For each marker, if the
reply resolves it, replace the marker with the answered value (or record a
recommended default in `关键假设` as `<value>（假设）`) and proceed to exit. If the
reply is too vague or off-point to resolve it, do **not** guess: keep the
marker, refine its question to name exactly what is still missing, bump that
marker's unresolved-round count in the workpad `notes`, and stop again via
"When blocked". After a marker has gone two rounds unresolved, stop re-asking
the same way — `@`-mention the issue's `creator` in the artifact, state the
blocking point and the decision you need, and (when the deadlock is really
scope being too large) propose a `sub-issue` split via `symphony-issue`.
Remain at `Human Review`.

## Exit

### Completeness bar (required to post the artifact)

The artifact is complete enough to post when all of these hold — this is
about form, not correctness:

- `Primary:`, `要解决的问题`, `为什么解决`, `验收标准` all filled.
- Every `S<N>` satisfies the 5 rules and is independently verifiable.
- Type-specific writing emphasis satisfied for `Primary:` (e.g. a Bug carries
  its required bug-specific `S<N>`).
- No unresolved `[NEEDS CLARIFICATION]` markers.

Post or update the `## Requirements` artifact and set the workpad
`current_phase: Requirements`. Do **not** move the issue yourself on a clean
exit — hand back one of two outcomes (`advance` / `stop`) for Main Flow to
execute. The decision is yours; Main Flow only carries it out.

### Exit decision: advance or stop

Choose **`advance`** only when **all** of these hold:

- **Fresh run** — not a rework, and the artifact carries no prior human reply.
- **State `In Progress`** — not `Rework`.
- **Confident** — answer honestly: *Did I actually understand the intent? Is
  this the only reasonable reading of the issue, such that a human reviewer
  would very likely approve it as-is?* Yes only if the problem statement and
  acceptance criteria follow directly from the issue, with no material
  ambiguity resolved by guessing.

A declared `本地验收不可达` does **not** by itself block `advance` — it is a
verifiability caveat, orthogonal to whether the intent was understood. As long
as it is stated in `关键假设`, it stays visible on the posted artifact for a
human to revisit later (a `⏩` artifact remains reviewable).

On `advance`, record `confidence: advance` in the workpad notes; Main Flow
writes the `⏩` reply and opens `phase-design` in the same session.

Otherwise choose **`stop`** — Main Flow moves the issue to `Human Review`.
This is the right outcome for a rework, for a human already in the thread,
for the `Rework` state, and for the **complete-but-not-confident** case: a
key interpretation could reasonably go another way, or you resolved a
material ambiguity with a judgment call a human might overturn. Before
stopping for low confidence, surface the specific uncertain point in
`关键假设` / `风险/注意` and record `confidence: review` in the notes.
**When in doubt, stop** — auto-advance is for the unambiguous case. After a
stop, the human approves by moving the issue back to an active state and the
next session advances to Design.

(The "When blocked" path above is the harder stop: an unresolved
`[NEEDS CLARIFICATION]` means the artifact is not even safe to build on, so
it moves to `Human Review` directly.)
