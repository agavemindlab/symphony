---
name: phase-implementation
description:
  Run the Implementation phase of the Symphony workflow. Turn approved
  Requirements and Design into working code, tests, and a PR. Post the
  `## Implementation` artifact when the work is ready for human review.
  Workpad lives in `.symphony/workpad.md` on the feature branch.
---

# Phase: Implementation

## Goal

Produce working code + tests + a PR that the reviewer can approve or
request changes on within 30 seconds of reading the `## Implementation`
artifact.

## At phase start

Main Flow has already closed `## Design` (a `✅` human approval or a `⏩`
agent auto-advance reply) and set `current_phase: Implementation` before
opening this skill. Build from three sources — not the Linear summary alone:

- **`.symphony/design.md`** — the detailed, agent-facing design doc Design
  wrote for you to implement from. This is your primary spec: the full approach,
  the alternatives and why each was rejected, the architecture, the edge-case
  matrix / call-site survey / failure modes, and the verification approach. A
  fresh session has no other memory of Design's reasoning, so read this doc;
  do not work off the one-line Linear summary.
- The **approved Linear `## Requirements` and `## Design`** — what the human
  actually signed off on: `S<N>` IDs, the `验收方案`, the approved approach, and
  risks. These are **authoritative on scope and commitments**.
- The **workpad** (`.symphony/workpad.md`) — execution continuation: the plan
  checklist, spawned/proposed issues that bound scope, and progress notes.

Keep the design doc and the approved artifact consistent; the human reviewed
only the artifact, so on any conflict the **approved artifact and its thread
govern** and the doc is reconciled toward them. If the design doc itself reveals
the approved design is actually wrong, that is a **cross-phase rework** (see
below), never a silent deviation.

Implementation never auto-advances: it always ends at `Human Review` with
the PR up, and Deployment is reachable only via the `Merging` state.

## Type:Spike — findings, not a PR

For a `Type:Spike` issue the deliverable is the **findings / recommendation**,
not shipped code. Carry out the investigation plan from `## Design`, then write
a findings artifact in place of the normal `## Implementation` artifact:
state each Requirements question's answer, the evidence backing it, and the
recommended decision. TDD and local runtime acceptance apply only to throwaway
code you write to learn (a prototype, a benchmark) — keep it on a scratch
branch and do not treat it as production work. The PR/CI line is optional: cite
a prototype branch or an ADR/docs PR if one exists, else omit it. Exit to
`Human Review` as usual; for a no-PR spike the human moves the issue straight
to `Done`. The rest of this skill (PR feedback sweep, Merge-gated Deployment)
applies only when the spike actually produced a PR worth landing.

If the workpad (`.symphony/workpad.md`) does not exist, create it with the
template from your workflow instructions. If this run is a rework of `## Implementation`
(the artifact has unresolved human feedback in its thread), reconcile the
workpad plan with that feedback before writing code, and follow the
same-phase Rework cycle in your workflow instructions when re-posting the artifact.

## Skills to invoke

- `writing-plans` (superpowers) — produce the hierarchical plan.
- `subagent-driven-development` (superpowers, when tasks are parallelizable) —
  delegate independent plan items to subagents.
- `test-driven-development` (superpowers) — write failing tests first for any
  new behavior.
- `systematic-debugging` (superpowers) — when a test fails or behavior
  surprises you **while coding**, root-cause it before patching. This is for
  surprises that arise during implementation — not for re-investigating a
  `Type:Bug` root cause already established in `## Design`.
- `symphony-commit` (.agents/skills) — clean, logical commits.
- `symphony-pr` (.agents/skills) — push to `origin`, publish PR, request code
  review per the project's reviewer configuration.
- `symphony-pull` (.agents/skills) — keep the branch current with
  `upstream/${SYMPHONY_BASE_BRANCH:-main}` before handoff.
- `symphony-issue` (.agents/skills) — spin off a separate ticket for any
  out-of-scope / deferred / blocking work discovered during implementation,
  instead of expanding this issue.
- `verification-before-completion` (superpowers) — gate before claiming work
  is done.

If a skill genuinely does not apply (e.g. no new behavior to test-drive),
record `Skipped <skill>: <reason>` in workpad `notes`.

### Type-conditional skills (gate on `Primary:`; they produce the 验收方案 evidence)

Invoke when the issue's type calls for it, to produce the acceptance evidence
the `## Design` 验收方案 named (recorded into `验收对照`); skip and record
`Skipped <skill>: <reason>` otherwise. These run autonomously — they do not
interview a human; any decision only a human can make follows the workflow's
`[NEEDS CLARIFICATION]` handling.

- **Feature / UI behavior** → `qa` (gstack — QA the running web app and fix what
  it finds) or `qa-only` (report-only) — exercise the critical-path flow and
  capture the **截屏 / 录屏** the pre-PR 本地验收 requires.
- **UI / visual change** → `design-review` (gstack) — designer's-eye pass on
  spacing / hierarchy / visual consistency, with before/after capture.
- **`Type:Refactor`** → `refactor` (gstack) — surgical, behavior-preserving
  edits plus the call-site survey the design committed to.
- **`Type:Performance`** → `benchmark` (gstack) or `performance-goal` — produce
  the before/after numbers the 验收方案 demands, with a rerunnable command.

## Workpad (`.symphony/workpad.md`)

The workpad is the agent's execution record and continuation state. Keep
it accurate so a fresh session can resume without losing state. See the Workpad template in your workflow instructions for the exact layout (YAML frontmatter +
markdown sections).

Frontmatter fields:
- `current_phase`: must be `Implementation`.
- `cleanup`: list all files that must not be merged into main (at minimum
  `.symphony/workpad.md`, `.symphony/design.md`, and any plan docs from
  brainstorming).

Markdown sections:
- `## Plan`: hierarchical checklist mirroring the implementation plan.
- `## Acceptance Criteria`: mirror every Requirements `S<N>` as an
  executable checkbox. Do not restate criterion text.
- `## Validation`: targeted test commands.
- `## Notes`: progress notes with timestamps; skills invoked.

## Implementation flow

1. **Plan** — invoke `writing-plans` to produce the hierarchical plan; write
   it to the workpad. Mirror `S<N>` IDs in `acceptance_criteria`.
2. **Delegate** — if the plan has independent subtasks, invoke
   `subagent-driven-development`.
3. **Implement with TDD** — for new behavior: failing test → minimal code
   → green → refactor.
4. **Commit** — invoke `symphony-commit` skill for each logical change.
5. **Push** — invoke `symphony-pr` skill to publish to `origin` and request code
   review.
6. **Local runtime acceptance** — execute the `## Design` 验收方案's **pre-PR
   本地验收** for each `S<N>`: exercise the feature against the running service
   per `AGENTS.md` and produce the evidence form the design named — a 截屏 for a
   single state, a 录屏 / GIF for an interactive flow — recorded readably (a
   verdict line + the artifact, raw output folded in `>>>`). If local acceptance
   is impossible, record the reason and closest safe alternative proof; surface
   the caveat in the artifact `风险/注意`.
7. **Verify** — invoke `verification-before-completion`.
8. **PR feedback sweep** — see protocol below.
9. **Post artifact** — write the `## Implementation` artifact and move to
   `Human Review`.

## PR feedback sweep protocol

Run this loop before posting the artifact:

1. Identify the PR number from issue attachments / links.
2. Ensure a code review is requested per the project's reviewer
   configuration after every push (`symphony-pr` skill handles this).
3. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries / states (`gh pr view --json reviews`).
4. Treat every substantive reviewer comment as requiring a same-thread
   reply in GitHub:
   - Addressed with code: reply with what changed + commit SHA.
   - Correct but deferred: reply with deferral reason + a follow-up issue
     spun off via the `symphony-issue` skill (autonomous `follow-up` kind);
     cite the new issue's identifier (e.g. `ENG-123`) in the reply.
   - Not applied: reply with explicit technical pushback.
5. Update the workpad `plan` / `acceptance_criteria` with each feedback
   item and its resolution.
6. Re-run validation after feedback changes and push updates.
7. Repeat until no outstanding actionable comments remain.

When responding to review feedback, follow `receiving-code-review`
discipline: verify before implementing, technical correctness over social
comfort.

## `## Implementation` artifact template

```md
## Implementation

**PR**: [#NNNN](URL) · **CI**: [green|red](URL) · `<short-sha>`

### 实现摘要
<3-5 句中文 prose。回答：解决了什么；选定方案是什么；为什么改是对的
（含关键数字 inline）；是否有 reviewer 需要知道的不放心点。
读完 reviewer 应能 30 秒内决定是否批准。>

### 验收对照（acceptance criteria）
| 验收项 | 状态 | 证据 |
|--------|------|------|
| S1: <criterion> | ✅ 通过 | <命令或检查结果> |
| S2: <criterion> | ⚠️ 部分通过 | <caveat> |
| S3: <criterion> | ➖ N/A | <原因> |

### 看哪里（optional: non-obvious diff areas only）
- [`path/file` L120-L145](URL) — <one sentence why reviewer should look here>

### 风险/注意（optional）
- <one sentence per item; omit if none>

### Merge 后验证（optional: one entry per `延迟验收` S<N> — see below）
- S<N>: **查询** `<exact runnable query/command against the prod log / error tracker>` · **通过判据** `<pass/fail predicate, e.g. 匹配条数 == 0>` · **观察窗口** `<length, e.g. 7 天>`

> 👉 **需要人工处理**：审查 PR，批准后将 issue 移至 `Merging`；需要修改则移至 `Rework`。

>>> 🛠️ 本次激活的 skills（mirror workpad notes: invoked + Skipped）
- `<skill>` — <≤6-word purpose>
- _跳过_ `<skill>` — <reason>
>>>
```

Status column conventions: `✅ 通过`, `⚠️ 部分通过`, `➖ N/A`, `❌ 失败`.
`❌ 失败` means the criterion is still unmet at handoff time.

For any `S<N>` classified `延迟验收` in Requirements' `关键假设`, `Merge 后验证`
must carry a **self-contained, runnable** spec — the exact query, the pass/fail
predicate, and the window length — not a vague "monitor the dashboard" note.
It has to survive branch cleanup and be runnable months later by a fresh
session that only has production-log access, because Deployment carries it into
`待验证项` and re-runs it verbatim (re-entered via `In Progress`) once the window
closes. Do not record a `延迟验收` criterion's status as `✅ 通过` here — at
handoff its window has not even started; it stays pending until Deployment
verifies it.

## Blocked-access escape hatch

Use only when completion is blocked by missing required tools or
auth/permissions that cannot be resolved in-session.

A blocker is a claim about what the environment **actually refused**, never an
assumption. Before writing any `🚨 Blocked`: attempt the operation and capture
the real error (exact command + stderr/exit); honor any human grant in the
issue thread (e.g. "you can access `~/data/...`") by actually attempting that
access. Do **not** assume an access boundary the environment has not actually
imposed: a path being outside the repo is not, on its own, proof a read will
fail — find out by attempting it and reading the real result. The
repo-write-confinement and read-scope rules in your workflow instructions are *behavioral
policy you self-enforce*, not a sandbox you can lean on. A real blocker is a
captured command + error (missing auth / secrets / tools, or an endpoint that
genuinely refuses you) — never an assumption.

Only after a real, captured failure with no in-session workaround, write a
blocker description in the workpad `notes` covering: what is missing; the exact
command + error proving it; why it blocks acceptance; exact human action to
unblock.

Reflect this in the artifact's `风险/注意` and include:
```
> 🚨 **Blocked**：<one sentence + the captured command/error>
```

## Cross-phase rework

If `Rework` feedback requires revisiting an earlier phase rather than fixing
the implementation:

- **Design flaw** (approach needs to change) → target `phase-design`
- **Requirements flaw** (problem statement or acceptance criteria wrong) → target `phase-requirements`

Follow the cross-phase rework protocol in your workflow instructions: resolve intermediate
artifacts in reverse order (Implementation first, then any phases between
target and Implementation), update workpad `current_phase` to the target
phase, and open the target phase skill.

## Exit conditions

- Workpad `plan` and `acceptance_criteria` complete; every agent-owned
  checkbox checked.
- For app-behavior changes, local runtime acceptance has produced concrete
  evidence, or the substitution path is documented.
- Validation/tests green for the latest commit.
- PR pushed; PR checks green; PR linked on the issue.
- PR feedback sweep complete: every substantive comment has a reply.
- `## Implementation` artifact posted.
- Issue moved to `Human Review`.

The human approves by moving the issue to `Merging`. On the next session,
Main Flow writes the approval reply on this artifact and runs Deployment.
