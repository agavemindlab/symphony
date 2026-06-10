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

## Sub-issue: fit the parent's design

If this issue has a **parent** (it was created as a sub-issue), read the
parent's `## Design` first. Adopt its architecture and already-settled
tradeoffs for this slice — do **not** re-decide them. Scope the approach to the
child's slice; raise a `[NEEDS CLARIFICATION]` only if the slice genuinely
cannot fit the parent's design.

## Discovery / design review

Decide whether to **invoke the `plan-eng-review` skill** to adversarially
review the chosen approach across architecture / code quality / tests /
performance. plan-eng-review earns its place only when the approach carries
genuine design risk. The rule: **unless the approach is the single obvious one
with no real architectural choice, run it; when in doubt, run it** (a wasted
review is far cheaper than building on a flawed design).

- Typically run it — there is a real architectural fork, new component / data
  flow, async / concurrency, a migration, a security boundary, or any
  non-obvious failure mode. When run, enumerate alternatives, consider edge
  cases and failure modes, and record the analysis in the workpad before
  writing the approach.
- Typically skip it — the change is mechanical with no design latitude: a
  config / dep `Chore`, a one-line fix with an obvious correct shape, a scoped
  `Refactor` whose only question is behavior-invariance (cover that with the
  Type-specific emphasis instead). Go straight to writing the approach.

Judge the actual design surface, not the type label — a "small" change that
touches a trust boundary or shared schema still warrants the review.

This workflow is unattended, so resolve what you can unilaterally (the
safe-default tradeoffs) and route every finding that genuinely needs a human
decision into the **Batched clarification** block below — one batch, each with
your recommended resolution.

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
- **Type:Spike** — the "approach" is an **investigation plan**, not an
  implementation direction: state the hypotheses, what to probe / prototype /
  measure, and how each Requirements `S<N>` question gets answered (the
  evidence each will produce). Name the spike's time/scope box so it does not
  sprawl. A diagram is optional unless the investigation itself is about
  component flow. The output is findings, posted at Implementation.

## High-impact decision protocol

If the approach has a **high-impact unresolved decision**, do not pick
unilaterally — surface it as a batched `[NEEDS CLARIFICATION]` question tagged
`🔴 〔影响：高 · 需明确回答〕` (see Batched clarification below) and move to Human
Review. The tag means a blanket `同意默认` never resolves it — the human must
answer it explicitly.

High-impact categories: schema/data migrations; dependency changes with
breaking changes; production/shared infrastructure; security/privacy
behavior; public API contracts; irreversible data operations; major UX
tradeoffs.

For ordinary tradeoffs with a safe default, pick the simplest option,
record the decision in the workpad notes, and continue — do not ask. A
material-but-not-high-impact approach fork (a real architectural choice a
reviewer might decide differently, no safe default) becomes an ordinary
batched question with your recommended direction.

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

### 待确认（omit if none; the batched [NEEDS CLARIFICATION] block — see Batched clarification）
```

## Batched clarification (`[NEEDS CLARIFICATION]`)

Because the agent cannot interview the human turn by turn, design ambiguities
are resolved in **one batch** with a recommended answer per question, so the
human can approve the whole set with a single reply or push back only on the
items they disagree with.

**What becomes a question — and what doesn't.** Walk the design decision tree
along your **own recommended answers** and collect every uncertainty you hit on
that path. Then sort each one:

- **Immaterial** (a safe default exists and a wrong guess costs little) → do
  **not** ask. Take the default, record it in the workpad notes (or `风险/注意`
  if a reviewer should see it), and move on.
- **Material** (your recommendation could be wrong in a way that changes the
  approach or what gets built) → make it a batched question. For Design this is
  most often an **approach fork**: two reasonable architectures with no safe
  default.
- **High-impact** (the categories in "High-impact decision protocol" above) →
  batched question tagged `🔴 〔影响：高 · 需明确回答〕`, which a blanket approval
  never covers (see the consent convention).

Each question must carry enough for the human to decide **without re-deriving
the design**: a `背景` line naming the fork and what a wrong pick would cost,
and a short consequence on **every** option — not just the recommended one (a
bare architecture label gives the reviewer nothing to weigh an override
against). When plan-eng-review (or your own analysis) surfaced the tradeoff,
preserve it here — do not flatten the reasoning down to a bare question.

**Batched format** — one block at the foot of the `## Design` artifact:

```md
### 待确认（一次性审阅：认可全部推荐请回复「同意默认」，否则逐条说明）
[NEEDS CLARIFICATION]
Q1. <question> 〔影响：低〕
  背景: <一句：这个 fork 是什么 + 选错的代价>
  - A（推荐）: <answer> — <这样选的后果 / 为什么优于备选>
  - B: <answer> — <这样选的后果>
Q2. <question> 🔴 〔影响：高 · 需明确回答〕
  背景: <一句：利害所在 / 为什么 blanket approval 不能覆盖>
  - A（推荐）: <answer> — <后果>
  - B: <answer> — <后果>
  - C: <answer> — <后果>
```

Keep each question's options to 2–4 concrete branches, exactly one marked
`（推荐）`. Every option states its consequence; the recommended one's doubles
as the rationale. **Cap at five questions per round** — more
signals the issue needs scope reduction or splitting (propose a `sub-issue`
split via `symphony-issue`).

## When blocked

When a batched `[NEEDS CLARIFICATION]` block remains after analysis:

1. Write the batched block at the foot of the `## Design` artifact.
2. Post or update the artifact comment.
3. Move the issue to `Human Review`.
4. Stop.

### Consent convention (how the human replies)

- **`同意默认`** (or 认可 / 都按推荐) → accept every `（推荐）` option, **except**
  any question tagged `🔴 〔影响：高 · 需明确回答〕`, which a blanket approval never
  covers.
- **Per-question override** (e.g. `Q2 选 B；其余默认`, or a prose answer naming
  the question) → take the named choice for those questions, the recommendation
  for the rest.
- A high-impact question is resolved **only** by an explicit answer to it; if a
  reply says `同意默认` but leaves a high-impact question untouched, that
  question stays open and you stop again for it.

### On resume

Read the human's reply in the artifact thread and apply the consent convention:

- For each **resolved** question, fold the chosen answer into the artifact
  (the `方案（approach）` / `选择理由` / `风险/注意` as fitting) and drop it from
  the batch.
- If accepting an **early/high-fanout** answer's *non-recommended* branch
  invalidates a later question's recommendation, **re-walk only that affected
  subtree** and surface the updated questions in the next batch; questions on
  unaffected branches stay resolved.
- If a reply is too vague or off-point to resolve a question, do **not** guess:
  keep it, refine its wording to name exactly what is still missing, bump its
  unresolved-round count in the workpad `notes`, and stop again.
- After a question has gone **two rounds** unresolved, stop re-asking the same
  way — `@`-mention the issue's `creator`, state the decision you need, and
  (when the deadlock is really scope being too large) propose a `sub-issue`
  split via `symphony-issue`. Remain at `Human Review`.

Once no batched question remains, proceed to Exit.

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
before you build on it. When you stop for a specific fork, prefer surfacing it
as a batched `[NEEDS CLARIFICATION]` question carrying your recommended
direction (so the human can one-click `同意默认`) rather than only a passive
`风险/注意` note; record `confidence: review` in the notes. Because a stop now
costs the human a single approval, **when in doubt, stop** — auto-advance is
for the clearly-right design. After a stop, the human approves by moving the
issue back to an active state and the next session advances to Implementation.

(The "When blocked" path above is the harder stop: an unresolved
`[NEEDS CLARIFICATION]` means the artifact is not even safe to build on, so
it moves to `Human Review` directly.)
