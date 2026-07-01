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

Publish the `## Requirements` artifact through the workflow artifact protocol
with these fields locked down:

- `Primary: Type:<...>` classifier
- `要解决的问题（what）`
- `为什么解决（why）`
- `验收标准（S1, S2, ...）` — every entry passing the 5 rules below, and the
  set as a whole passing the sufficiency check below

The `验收标准` are the issue's **close test**: when every `S<N>` is satisfied
the issue is genuinely done and can be closed; if any fails it cannot. They are
not a proxy for "the code ran" — passing unit tests, a green build, or a merged
PR are evidence the *implementation* moved, never on their own evidence the
*problem* is solved.

The Design approach is not part of this artifact; it belongs in `## Design`.

## At phase start

Main Flow has already checked out the feature branch (so
`.symphony/workpad.md` is writable) and opens this skill only when
Requirements is the target phase. Two cases:

- **Fresh run** — no `## Requirements` artifact yet, or it has no
  unresolved human feedback. Proceed to Discovery.
- **Rework** — the `## Requirements` artifact has unresolved human feedback
  in its thread. Address that feedback and follow the same-phase Rework
  cycle in your workflow instructions when re-posting the artifact.

## Discovery

Read all issue context first (description, comments, attachments, linked
issues, labels).

Then decide whether to **invoke the `office-hours` skill** to interrogate
intent, surface hidden assumptions, and stress-test the problem statement.
office-hours earns its place only when the problem framing has genuine
uncertainty. The rule: **unless both the `what` and the `why` are already
concrete and unambiguous, run it; when in doubt, run it** (a wasted
interrogation is far cheaper than building the wrong thing).

Form an initial type read from the issue's Linear `Type:Xxx` label (or, if it
has none, your own quick classification — the same call `## Primary: type`
below formalizes). Use it only as the heuristic below; you confirm the final
`Primary:` when writing the artifact.

- Typically run it — `Feature` (boundaries and implicit needs), `Spike`
  (hypotheses and the real question being asked), a vague `Bug` (expected
  behavior / root-cause intent unclear).
- Typically skip it — the intent is already mechanical and self-evident:
  `Chore` (dep bump, config, rename), a scoped `Refactor` (intent is
  behavior-preservation, the risk is invariance not intent), a metric-bound
  `Performance`, a reproduced `Bug` with clear expected behavior. Go straight
  to writing acceptance criteria.

Type is only a heuristic — a fuzzy Chore can still need interrogation, a
crisply-specified Feature may not. Judge the actual `what`/`why`, not the label.

Regardless of that decision, always do the lightweight ambiguity scan that
feeds Batched clarification. This workflow is unattended, so you cannot
interview a human turn by turn: when office-hours (or your own analysis) would
put a question to the human, do not ask one at a time — collect every
uncertainty and resolve it through the **Batched clarification** protocol below
(assume-and-record the immaterial ones, batch the material ones with a
recommended answer).

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
5. **Time-bounded** — names *when* it is judged. A point in time is a valid
   bound: a signal one conclusive observation settles (a reproduction path that
   no longer triggers, checked at **PR 验收 / 上线 smoke**) needs no window. Use
   a *sustained window* ("zero X events for N days") **only** for signals whose
   meaning depends on duration — absence of events, stability, no-regression
   under real traffic. Don't attach a window to a criterion a single check
   already settles.

Each entry must also be **independently verifiable**. Use stable IDs
(`S1`, `S2`, ...). Design and Implementation reference these IDs.

### Sufficiency check (the set, not the item)

The 5 rules govern each `S<N>` in isolation; this governs the **whole set**.
The criteria must be **necessary and sufficient to close the issue**:

- **Sufficient** — if every `S<N>` is satisfied, `要解决的问题` is genuinely
  solved with no material outcome left unproven. Apply the set-falsification
  test: *imagine all `S<N>` green — could the issue still legitimately stay
  open?* If yes, a criterion is **missing** (usually the primary user/business
  outcome, which is easy to omit when each individual criterion looks fine);
  add it.
- **Necessary** — every `S<N>` is actually required to close. If the issue
  could close with one left unmet, it is gold-plating — cut it, or move it to a
  spun-off follow-up issue.

A set that is all-green-but-not-closeable is the failure this guards against:
well-formed individual criteria that together still do not witness that the
problem is solved.

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

## Batched clarification (`[NEEDS CLARIFICATION]`)

Because the agent cannot interview the human turn by turn, ambiguities are
resolved in **one batch** with a recommended answer per question, so the human
can approve the whole set with a single reply or push back only on the items
they disagree with.

**What becomes a question — and what doesn't.** office-hours is natively
one-at-a-time; the batch is how you run it unattended. Simulate its
interrogation: answer each question it would put to you with your **own
recommended answer**, walk on down its tree, and keep going until it reaches
its natural stopping point. Collect every uncertainty you hit along that full
path — do not stop early to keep the list short; a batch is cheapest when it is
complete, because the human answers it in one pass. Then sort each one:

- **Immaterial** (a safe default exists and a wrong guess costs little) → do
  **not** ask. Take the default, record it in `关键假设` as `<value>（假设）`,
  and move on.
- **Material** (your recommendation could be wrong in a way that changes the
  problem, the acceptance criteria, or the build) → make it a batched question.
- **High-impact** (schema/data migration, irreversible data op, security/
  privacy behavior, public API contract, dependency breaking change, major UX
  fork) → batched question tagged `🔴 〔影响：高 · 需明确回答〕`; it is **not**
  covered by a blanket approval (see the consent convention).

Each question must carry enough for the human to decide **without re-reading
the issue**: a `背景` line naming what is ambiguous and what a wrong pick would
cost, and a short consequence on **every** option — not just the recommended
one (a bare option label gives the human nothing to weigh an override against).
When office-hours (or your own analysis) surfaced the underlying tradeoff,
preserve it here — do not flatten the reasoning down to a bare question.

**Batched format** — one block at the foot of the `## Requirements` artifact:

```md
### 待确认（一次性审阅：认可全部推荐请回复「同意默认」，否则逐条说明）
[NEEDS CLARIFICATION]
**Q1. <question> 〔影响：低〕**
  背景: <一句：歧义在哪 + 选错的代价>
  - A（推荐）: <answer> — <这样选的后果 / 为什么是安全选择>
  - B: <answer> — <这样选的后果>

**Q2. <question> 🔴 〔影响：高 · 需明确回答〕**
  背景: <一句：利害所在 / 为什么 blanket approval 不能覆盖>
  - A（推荐）: <answer> — <后果>
  - B: <answer> — <后果>
  - C: <answer> — <后果>
```

Give each question as many concrete branches as the decision genuinely has
(office-hours' framing decides this, not a fixed number), exactly one marked
`（推荐）`. Every option states its consequence; the recommended one's doubles
as the rationale. There is **no cap** on questions per round — surface every
material uncertainty the walk reached; that one complete batch is the efficient
ask.

Do **not** propose or create sub-issues here. Requirements settles *what* and
*why*, not *how*, so the work cannot be decomposed yet — that is a Design
decision. The one related move at this phase: if the ticket reads as **several
distinct problems** rather than one (separate goals, separate acceptance
criteria), raise that as a batched clarification question — `要拆成几个 ticket
吗？` with your recommended split — and let the human decide. Create nothing
either way.

While any batched question is unresolved, product implementation code must not
start.

## Verifiability of each `S<N>`

A close-worthy `S<N>` is often not checkable on the agent's dev machine at
handoff time — that does **not** make it unverifiable, and you must never weaken
the criterion just to make it checkable now (that reintroduces the "tests pass"
failure). What matters is **who produces the proof, and when**. For a
production-only signal the deciding factor is whether the agent actually has the
access to observe *that specific signal* in production — it has production-log
read access, but a given criterion may need data / dashboards it cannot reach.
Classify by that, not by where the signal lives:

- **当场可验** — provable at handoff / deploy time: either locally reproducible,
  **or** production-observable with the agent's access (e.g. a post-deploy log /
  metric query the agent can run right after deploy). The agent runs it and
  records real evidence; no special handling.
- **延迟验收** — a production signal the agent *can* observe, but which only
  exists over a post-merge observation window (e.g. "zero error events for 7
  days"). Verifiable, just later: the agent owns it as a deferred check that
  Deployment runs once the window closes (it re-enters Deployment via
  `In Progress`).
- **需人工判定** — the agent genuinely cannot produce the real proof: it lacks
  the access to observe that production signal, or the criterion needs a human
  judgment call. This is the **only** case that hands off. Record the closest
  safe local **substitution path** as interim evidence, and route the real
  confirmation to the human (or a follow-up issue).

Most `S<N>` are `当场可验` and need no note. For every criterion that is not,
record the classification in `关键假设` as
`S<N> 验证：<延迟验收 | 需人工判定> — <原因>`. The pipeline acts on it:
Implementation writes the executable deferred-verification spec into
`Merge 后验证` for each `延迟验收`, which Deployment carries into its `待验证项`
and runs once checkable (re-entered via `In Progress` — see your workflow instructions); a
`需人工判定` gets the substitution path plus a human/follow-up route.

## Artifact template

```md
## Requirements

<用人话先说明结论和影响，再列证据。>

Primary: Type:<Bug|Feature|Refactor|Performance|Migration|Chore|Spike|Other>

要解决的问题（what）:
- <actual problem at mechanism level, not symptom restatement>

为什么解决（why）:
- <motivation: user pain / business constraint / trigger>

验收标准（acceptance）:
- S1: <observable, measurable, falsifiable, time-bounded signal>
- S2: <...>

关键假设（omit if none; include an `S<N> 验证：…` line for any criterion not verifiable at handoff）:
- <one sentence per assumption>

风险/注意（secondary concerns; omit if none）:
- <one sentence per item>

### 待确认（omit if none; the batched [NEEDS CLARIFICATION] block — see Batched clarification）

>>> 🛠️ 本次激活的 skills
- Codex session id: `<session_id | n/a>`
- `<skill>` — <≤6-word purpose>
>>>
```

## When blocked

When a batched `[NEEDS CLARIFICATION]` block remains after honest analysis:

1. Write the batched block at the foot of the `## Requirements` artifact.
2. Publish the artifact through the workflow artifact protocol.
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

Read the human's reply in the artifact thread and apply the consent convention. Fold answers into the revised artifact content, not the old comment body:

- For each **resolved** question, fold the chosen answer into the artifact
  (into `要解决的问题` / `为什么解决` / `验收标准` / `关键假设` as fitting) and
  drop it from the batch. An accepted recommendation that is a default
  assumption lands in `关键假设` as `<value>（假设）`.
- If accepting an **early/high-fanout** answer's *non-recommended* branch
  invalidates a later question's recommendation, **re-walk only that affected
  subtree** and surface the updated questions in the next batch; questions on
  unaffected branches stay resolved.
- If a reply is too vague or off-point to resolve a question, do **not** guess:
  keep it, refine its wording to name exactly what is still missing, bump its
  unresolved-round count in the workpad `notes`, and stop again.
- After a question has gone **two rounds** unresolved, stop re-asking the same
  way — `@`-mention the issue's `creator` and state the decision you need. When
  the deadlock is really scope being too large, **flag** that the ticket looks
  too broad and ask whether to split it — but create nothing here; the actual
  sub-issue decomposition is a Design decision. Remain at `Human Review`.

Once no batched question remains, proceed to Exit.

## Exit

### Completeness bar (required to post the artifact)

The artifact is complete enough to post when all of these hold — this is
about form, not correctness:

- `Primary:`, `要解决的问题`, `为什么解决`, `验收标准` all filled.
- Every `S<N>` satisfies the 5 rules and is independently verifiable.
- The `S<N>` set passes the **sufficiency check** — necessary and sufficient to
  close the issue (the set-falsification test holds: all-green ⟹ closeable).
- Type-specific writing emphasis satisfied for `Primary:` (e.g. a Bug carries
  its required bug-specific `S<N>`).
- No unresolved `[NEEDS CLARIFICATION]` markers.

Publish the `## Requirements` artifact through the workflow artifact protocol
and set the workpad `current_phase: Requirements`. Do **not** move the issue
yourself on a clean exit — hand back one of two outcomes (`advance` / `stop`)
for Main Flow to execute. The decision is yours; Main Flow only carries it out.

### Exit decision: advance or stop

Choose **`advance`** only when **all** of these hold:

- **Fresh run** — not a rework, and the artifact carries no prior human reply.
- **State `In Progress`** — not `Rework`.
- **Confident** — answer honestly: *Did I actually understand the intent? Is
  this the only reasonable reading of the issue, such that a human reviewer
  would very likely approve it as-is?* Yes only if the problem statement and
  acceptance criteria follow directly from the issue, with no material
  ambiguity resolved by guessing.

A declared `S<N> 验证：…` classification does **not** by itself block `advance`
— it is a verifiability caveat, orthogonal to whether the intent was
understood. As long as it is stated in `关键假设`, it stays visible on the
posted artifact for a human to revisit later (a `⏩` artifact remains
reviewable).

On `advance`, record `confidence: advance` in the workpad notes; Main Flow
writes the `⏩` reply, sets `current_phase: Design`, persists state, and stops
this agent run. The next Symphony dispatch opens `phase-design`.

Otherwise choose **`stop`** — Main Flow moves the issue to `Human Review`.
This is the right outcome for a rework, for a human already in the thread,
for the `Rework` state, and for the **complete-but-not-confident** case: a
key interpretation could reasonably go another way, or you resolved a
material ambiguity with a judgment call a human might overturn. When you stop
for a specific uncertain interpretation, prefer surfacing it as a batched
`[NEEDS CLARIFICATION]` question carrying your recommended reading (so the
human can one-click `同意默认`) rather than only a passive `风险/注意` note;
record `confidence: review` in the notes. Because a stop now costs the human a
single approval, **when in doubt, stop** — auto-advance is for the unambiguous
case. After a stop, the human approves by moving the issue back to an active
state and the next session advances to Design.

(The "When blocked" path above is the harder stop: an unresolved
`[NEEDS CLARIFICATION]` means the artifact is not even safe to build on, so
it moves to `Human Review` directly.)
