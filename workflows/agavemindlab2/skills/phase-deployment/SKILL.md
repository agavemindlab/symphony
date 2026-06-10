---
name: phase-deployment
description:
  Run the Deployment phase of the Symphony workflow. Merge the approved PR,
  verify the deploy, clean up agent scaffolding files, and post the
  `## Deployment` artifact. Triggered by the `Merging` Linear state.
  The agent never moves the issue to Done.
---

# Phase: Deployment

## Goal

Land the approved PR safely, confirm the deploy succeeded, do immediate
post-deploy verification, and hand back to the human for final sign-off.

The agent **never** moves the issue to `Done`. That is the human's final
action after reading the `## Deployment` artifact.

## At phase start

Main Flow has already detected the merge approval, written the approval
reply on `## Implementation`, and set `current_phase: Deployment` before
opening this skill. Confirm the issue is in `Merging` and read the
`## Implementation` artifact and PR before landing.

## Cleanup before merge

Before landing the PR, remove all files listed in the workpad `cleanup`
field. At minimum this includes `.symphony/workpad.md` and any plan docs
generated during brainstorming (e.g., `docs/superpowers/specs/`).

```sh
# Example — actual paths come from workpad cleanup field
git rm .symphony/workpad.md
git rm -r docs/superpowers/specs/
git commit -m "chore: remove agent scaffolding before merge"
```

Do not remove files that belong in the repository. Only remove files
explicitly listed in the `cleanup` field.

## Land

Open and follow `.agents/skills/symphony-land/SKILL.md` to merge the PR.

## Post-deploy verification

After the merge and deploy pipeline confirms success:

1. Verify the immediate acceptance criteria that can be checked right
   after deploy (e.g., smoke tests, endpoint health, error-rate baseline).
2. Record evidence for each `S<N>` from `## Requirements`.
3. Note any `S<N>` items that require a longer observation window or
   human confirmation. Spin off any genuine follow-up work as a separate
   ticket via the `symphony-issue` skill (autonomous `follow-up`) and list
   its identifier (e.g. `ENG-123`) in 后续事项; do not expand this issue.

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
| S2: <criterion> | ⚠️ 待观察 | <观察窗口和方式> |

### 后续事项（optional）
- <follow-up issues, monitoring windows, rollback path; omit if none>

> 👉 **需要人工处理**：确认部署结果符合预期，将 issue 置为 `Done`；如有问题置为 `Rework`。
```

Status conventions: `✅ 通过`, `⚠️ 待观察`, `➖ N/A`, `❌ 失败`.

Use `⚠️ 待观察` (not `❌ 失败`) for acceptance criteria that need a
longer observation window — they are not yet failed, just pending.

## Cross-phase rework

If post-deploy verification reveals the implementation was fundamentally
wrong and a new PR is required, follow the cross-phase rework protocol in
WORKFLOW.md: resolve `## Deployment`, update workpad
`current_phase: Implementation`, and open `phase-implementation`.

## Exit

After posting the `## Deployment` artifact:

1. Move the issue back to `Human Review`.
2. Stop. Do **not** move the issue to `Done`.

The human confirms completion by moving the issue to `Done`, or requests
further work by moving to `Rework`.
