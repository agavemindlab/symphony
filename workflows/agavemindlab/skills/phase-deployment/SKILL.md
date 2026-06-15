---
name: phase-deployment
description:
  Run the Deployment phase of the Symphony workflow. Land the approved PR,
  verify the deploy, clean up agent scaffolding, and post the `## Deployment`
  artifact. Entered via `Merging` (the merge) and re-entered via `In Progress`
  to finish verification that could not complete at deploy time. The agent
  never moves the issue to Done.
---

# Phase: Deployment

## Goal

Land the approved PR safely, confirm the deploy succeeded, **verify the
acceptance criteria**, and hand back to the human for final sign-off.

Verification is Deployment's core job — a deploy is not done until its
acceptance criteria are checked. Some criteria cannot be confirmed in the
moment of deploy (a `延迟验收` window has not elapsed, an external signal is not
yet readable); those stay pending and Deployment is re-entered later to finish
them. The agent **never** moves the issue to `Done` — that is the human's final
action after reading the `## Deployment` artifact.

## At phase start — two entry modes

- **Merge entry** (issue in `Merging`). Main Flow detected the merge approval,
  wrote the approval reply on `## Implementation`, and set
  `current_phase: Deployment`. Read the `## Implementation` artifact and PR,
  then run the full path below: leak check → land → verify → post artifact.
- **Verification re-entry** (issue in `In Progress`, a concluded `## Deployment`
  artifact already exists with unresolved `⚠️ 待观察` items). The PR has long
  since merged. **Skip cleanup and land entirely** — do not touch the working
  tree; this run only reads the existing `## Deployment` 的 `待验证项` block and
  `## Requirements` and runs checks against production logs. Go straight to
  **Verification** to finish the pending items. This is what
  Deployment-in-`In Progress` means: continue verifying what could not be
  confirmed at deploy time.

## Cleanup leak check before merge (merge entry only)

Implementation should already have kept all files listed in the workpad
`cleanup` field out of the PR branch and persisted them through the
`Symphony agent state` Linear attachment. Before landing, verify the PR diff is
still clean. If any cleanup path is present because legacy state or rework
tracked it accidentally, stop and return to Implementation rework; do not merge
agent-only files. At minimum the cleanup list includes `.symphony/workpad.md`,
`.symphony/design.md` (Design's agent-facing design doc), and any plan docs
generated during brainstorming (e.g., `docs/superpowers/specs/`).

```sh
# Actual paths come from the restored workpad cleanup field
git diff --name-only upstream/${SYMPHONY_BASE_BRANCH:-main}...HEAD
```

Do not remove files that belong in the repository. Only reject paths explicitly
listed in the `cleanup` field.

## Land (merge entry only)

Open and follow `.agents/skills/symphony-land/SKILL.md` to merge the PR.

## Verification

Drive every acceptance `S<N>` from `## Requirements` to a resolved status
(`✅ 通过` / `❌ 失败` / `➖ N/A`) by executing the `## Design` 验收方案's
**post-merge 最终验收** for each, recording the evidence form the design named —
a 截屏 / 录屏 for an interactive `S<N>`, the query+matched-lines for a log
signal — readably (verdict line + artifact, raw output folded). The `验收对照`
table is the running ledger. On a re-entry the still-`⚠️ 待观察` items are the
main work — but also re-confirm any earlier `✅` you judge was only a
point-in-time proxy for a criterion whose real intent is sustained or needs
fresh confirmation; do not mechanically trust a prior pass.

1. **Verify what is checkable now.** For each unresolved `S<N>`, run its check
   and record evidence: immediate signals at deploy (smoke tests, endpoint
   health, error-rate baseline), and any `延迟验收` whose window has already
   elapsed (run its recorded `待验证项` query against the production log and
   judge it against the predicate — never weaken the predicate to pass it).
2. **Leave genuinely-pending items `⚠️ 待观察`** with a concrete reason:
   - `延迟验收` whose window is still open — on **merge entry** the deploy
     **starts** the window: carry the runnable spec forward from
     `## Implementation` 的 `Merge 后验证`, stamp the **window-end date**
     (deploy date + window length), and record it in `待验证项`. On a re-entry,
     if the window still has not elapsed, note `窗口未满，剩余 <N> 天`.
   - any other check not yet runnable (an external signal not yet readable).
3. **Hand off `需人工判定` `S<N>`** (only a human can confirm). Note it in
   后续事项; spin off genuine follow-up work as a separate ticket via the
   `symphony-issue` skill (autonomous `follow-up`) and cite its identifier
   (e.g. `ENG-123`); do not expand this issue.

A `❌ 失败` means the shipped change did not meet its criterion — a real
regression. Do not auto-fix it from here: state it plainly, `@`-mention the
issue's `creator`, and leave it for the human to route to `Rework`.

## `## Deployment` artifact template

```md
## Deployment

**PR**: [#NNNN](URL) · **Merge commit**: [`<sha>`](URL) · **Deploy**: [pipeline](URL)

### 部署结果
<2-3 句：PR 合并了什么；deploy pipeline 结果；是否有部署 caveat。>

### 验收对照（acceptance criteria）
| 验收项 | 状态 | 证据 |
|--------|------|------|
| S1: <criterion> | ✅ 通过 | <命令或观测结果> |
| S2: <criterion> | ⚠️ 待观察 | 见待验证项 |

### 待验证项（omit when none pending; one per still-`⚠️ 待观察` S<N>）
- S<N>: **查询** `<runnable query>` · **通过判据** `<predicate>` · **何时可验** `窗口末 <YYYY-MM-DD>` / `<其它前置条件>`

### 后续事项（optional）
- <follow-up issues, rollback path; omit if none>

> 👉 **需要人工处理**：确认部署结果符合预期。
> - 若仍有「待验证项」：把 issue 留在 `Human Review`（或任何 Symphony 不处理的状态）直到「何时可验」满足，然后将其移回 `In Progress` —— Deployment 会重入、把剩余验收跑完并回报；全部 `✅` 后由你置 `Done`。
> - 若验收已全部完成：直接将 issue 置为 `Done`；如有问题置为 `Rework`。

>>> 🛠️ 本次激活的 skills
- `<skill>` — <≤6-word purpose>
>>>
```

Status conventions: `✅ 通过`, `⚠️ 待观察`, `➖ N/A`, `❌ 失败`.

Use `⚠️ 待观察` (not `❌ 失败`) for acceptance criteria that are simply not yet
checkable (window still open, external signal not yet readable) — they are not
failed, just pending. Each pending item carries a runnable spec in `待验证项`
so a later Deployment re-entry (with no branch) can finish it from the artifact
and production-log access alone.

## Cross-phase rework

If post-deploy verification reveals the implementation was fundamentally
wrong and a new PR is required, follow the cross-phase rework protocol in your workflow instructions: resolve `## Deployment`, update workpad
`current_phase: Implementation`, and open `phase-implementation`.

## Exit

After posting or updating the `## Deployment` artifact:

1. Move the issue back to `Human Review`.
2. Stop. Do **not** move the issue to `Done`.

The posted `> 👉` callout tells the human how to proceed: close on all-resolved,
move back to `In Progress` to re-enter verification while items remain
`⚠️ 待观察`, or `Rework` on failure.
