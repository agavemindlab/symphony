---
name: phase-clarification
description:
  Run Gate 1 (requirement clarification) of the Symphony workflow. Turn an
  issue into a `## Spec` Linear comment whose `要解决的问题`, `为什么解决`,
  and `验收标准` lock down what to solve and how to know it's solved. Use at
  the start of any `Todo` / `In Progress` / `Rework` ticket. Exit when the
  Spec passes the 5-rule acceptance gate with no `[NEEDS CLARIFICATION]`
  markers, or hand off to human if blocked.
---

# Phase 1: Requirement Clarification

## Goal

Produce (or update) the persistent `## Spec` Linear comment with these
fields locked down:

- `Primary: Type:<...>`
- `要解决的问题（what）`
- `为什么解决（why）`
- `验收标准 (S1, S2, ...)` — every entry passing the 5 rules below

`解决方案（approach）` is filled at Gate 2 (phase-design); leave a
`<Gate 2 待补>` placeholder here. The 5 fields above must not depend on
implementation specifics.

## Default skill to invoke

Use the project's configured discovery tool if one is available (e.g., an
`office-hours` equivalent) — interrogate user intent, surface ambiguity, and
stress-test the problem statement before writing the Spec. Check whether
such a tool is installed in `.agents/skills/` or available in the session
environment before proceeding.

If no discovery tool is available, conduct manual requirement analysis:
read all issue context (description, comments, attachments, linked issues,
labels), identify the problem mechanism, and surface ambiguities explicitly
before writing the Spec.

Either way, if the default path was skipped or altered, record
`Skipped discovery tool: <reason>` in workpad `Notes` per WORKFLOW.md
`Related skills`.

## `## Spec` field rules (this gate)

### `Primary:` type

One of `Bug | Feature | Refactor | Performance | Migration | Chore | Other`.
For multi-type issues, pick the dominant type as `Primary:` and note the
secondary concerns in `风险/注意`. Use the existing Linear `Type:Xxx` label
as the mechanical override; if no label is present, classify and add the
matching label to the Linear issue.

### `验收标准` — 5 rules

Every `S<N>` entry must satisfy all five:

1. **Technology-agnostic** — written in problem/user language, not
   lint/test/HTTP-code language. "lint pass / tests passed / endpoint
   returns 200" belongs in Workpad `Validation`, not here.
2. **Observable** — names a concrete read mechanism (specific dashboard
   / log query / error tracker issue ID / user reproduction path / database
   read).
3. **Measurable** — number, boolean, or clearly defined state.
4. **Falsifiable** — can be rewritten as "if X then NOT accepted".
5. **Time-bounded** — names how long to observe (e.g., "for 7 days
   post-merge", "within 24h after deploy").

Each entry must also be **independently verifiable** on its own.

Use stable IDs (`S1`, `S2`, ...). The Workpad and Handoff reference these
IDs instead of restating the criterion text.

### Type-specific writing emphasis at this gate

Apply the emphasis matching `Primary:` to the `要解决的问题（what）`,
`为什么解决（why）`, and `验收标准` fields. (Approach-side emphasis is
in phase-design.)

- **Type:Bug** — `what` must reach the actual causal mechanism (LLM
  truncation, race condition, missing index, malformed input from source
  Y, etc.), not a restatement of the existing code's assumption. If the
  agent cannot localize the mechanism after honest investigation, write
  `根因: unknown` plus evidence of investigation attempts. At least one
  `验收标准` must be bug-specific (error tracker issue events stay at zero
  for N days / user-reported reproduction path no longer triggers), not
  a generic health check.
- **Type:Feature** — `why` names the user/role and the problem they
  have today. `验收标准` includes a UX critical path signal (user can
  complete X end-to-end) and an observability signal (counter / log /
  SLO emits expected data within window).
- **Type:Refactor** — `why` answers "why now". `验收标准` includes a
  no-regression signal (error rate / latency stays within ±N% of
  baseline post-merge).
- **Type:Performance** — `what` includes bottleneck localization
  evidence (profiling, EXPLAIN, metrics screenshot). `验收标准` uses
  measured signals (p99 < X ms on dashboard Y), not "should be faster".
- **Type:Migration** — `what` includes production data scale (row
  count / size order). `验收标准` includes data-integrity signals
  (row count parity, no lock contention alerts during window).
- **Type:Chore (deps/tooling)** — `验收标准` includes transitive
  smoke (application-level) and compatibility verification.
- **Type:Other** — explicitly justify why none of the other types
  apply. Reviewer is responsible for confirming the classification
  before merge.

### `[NEEDS CLARIFICATION:...]` markers

Use inline `[NEEDS CLARIFICATION: <question>]` markers anywhere in the
Spec for ambiguities that block correct implementation and **cannot be
resolved with a safe default**. Resolved-with-default ambiguities are
recorded as `Brief 假设: <value>` instead.

While any `[NEEDS CLARIFICATION]` marker is unresolved, **product
implementation code must not start**. Follow the blocked-handoff protocol
below.

### `本地验收不可达` substitution

When the bug or behavior cannot be reproduced locally because it requires
production scale, multi-replica state, sustained alert windows, real
customer data, or other production-only conditions, declare
`本地验收不可达：<具体原因>` in `关键假设`. The substitution path
(characterization tests + handoff `Merge 后验证` section) is enforced at
phase-implementation and at the PR-review completion bar.

### `迭代记录` segment

When the issue has ≥2 linked PRs (current + prior, regardless of
merged/closed/open), include the `迭代记录` segment so reviewers can
see the iteration history without reading git log. Skip when only one
PR is linked.

### PII

Spec must not contain PII. Sanitize root-cause writeups that reference
user data (replace user IDs with hashes, redact emails / payloads, never
paste raw request/response bodies).

### Trivial Spec

Use the compact `Trivial Spec` form only when the change is single-file
(or a tightly coupled pair such as code + matching test) and has **no**
behavior / data / security / API / migration / performance impact. The
PR-review gate validates this classification; if any of those impact
categories apply, escalate to the full template before handoff.

## Output template

### Full Spec

````md
## Spec

Primary: Type:<Bug|Feature|Refactor|Performance|Migration|Chore|Other>

要解决的问题（what）:
- <agent 理解的实际问题；不抄 description；按 type emphasis 写到机制层（bug 写到上游因果机制；migration 写出生产数据规模；performance 写瓶颈定位证据）>

为什么解决（why）:
- <动机：用户痛点 / 业务约束 / 触发原因>

解决方案（approach）:
- <Gate 2 待补>

迭代记录（仅 issue 关联 ≥2 个 linked PR 时填；否则省略）:
- PR #<NNNN>（<merged YYYY-MM-DD | closed | open>）: <一句这一轮覆盖范围>
- PR #<NNNN>（<...>）: <...>
- 本轮（PR #<NNNN>）相对前轮新增的覆盖范围: <一句>

验收标准（acceptance）:
- S1: <问题视角的可观测信号；技术无关 / 可观测 / 可度量 / 反证可能 / 时间界；独立可测>
- S2: <...>

关键假设（如果错了方案就要变；无则省略；本地不可复现 production 状态时必填一条 `本地验收不可达：<原因>`）:
- <每条一句>

风险/注意（多类型次要顾虑、symptomatic fix 风险、其他；无则省略）:
- <每条一句>
````

### Trivial Spec

````md
## Spec

Primary: Type:Chore (trivial)
Brief 假设: trivial change; 无 behavior/data/security/API/migration/performance 影响。

要解决的问题: <一句>
解决方案: <一句>
S1: <一句可观测信号>
````

## When blocked: requirement-confirmation handoff

When at least one `[NEEDS CLARIFICATION:...]` marker remains after
honest analysis (whether surfaced by the discovery tool, by another invoked
skill, or by the agent's own analysis), follow WORKFLOW.md `Skill
interaction protocol (unattended bridge)`: collect every blocking
question, consider 2-4 options for each, mark a recommendation, write
each as `[NEEDS CLARIFICATION:<question>]` inline in the relevant Spec
field, batch into one `Status: Waiting for requirement confirmation`
handoff (sub-template below), and move the issue to `Human Review`.
Cap at five questions per round; if more, propose narrowed scope or
issue split.

### Handoff sub-template

Lifecycle invariants (marker, status enum, fresh-comment-per-transition,
shared writing rules) live in WORKFLOW.md `Review handoff lifecycle`. Use
this body shape:

````md
## Review Handoff

**Status**: Waiting for requirement confirmation
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

Then sync the workpad's `Acceptance Criteria` mirror to reflect the
resolved Spec. Only then re-enter Gate 2 (phase-design).

## Exit conditions (advance to Gate 2)

This phase exits and Gate 2 (phase-design) starts when **all** of:

- `## Spec` exists with `Primary: Type:<...>`, `要解决的问题`,
  `为什么解决`, and `验收标准` filled.
- Every `验收标准 S<N>` satisfies the 5 rules above.
- No unresolved `[NEEDS CLARIFICATION:...]` markers remain.
- Trivial Spec, if used, was correctly classified (no
  behavior/data/security/API/migration/performance impact).

`解决方案（approach）` is left as `<Gate 2 待补>`; phase-design will
fill it.

Product implementation code (changes that will land in the PR diff)
starts only by **entering** Gate 3 (`phase-implementation`), after
this phase and Gate 2 (`phase-design`) have both exited. Investigation
code (reproductions, temporary logging, ad-hoc scripts to characterize
a bug or measure a baseline) is allowed before the Spec is finalized;
product implementation code is not.
