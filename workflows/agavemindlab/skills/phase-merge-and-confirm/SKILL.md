---
name: phase-merge-and-confirm
description:
  Handle the Merging state after human approval, including land flow and final
  confirmation handoff. The agent never moves the issue to Done.
---

# Phase: Merge And Confirm

## Goal

Land an approved PR safely, verify the issue objective after merge, and hand
back to the human for final confirmation.

The agent **never** moves the issue to `Done`. That is the human's final
confirmation after reading the completion-confirmation handoff.

## Steps

1. Verify the issue is in `Merging`.
2. Confirm the latest handoff or human comment clearly approves merging.
3. Open and follow `.agents/skills/land/SKILL.md`.
4. After merge, verify the issue objective using evidence available from tests,
   checks, or documented runtime validation.
5. Update the workpad with merge and verification evidence.
6. Create a fresh `## Review Handoff` comment with
   `Status: Waiting for completion confirmation` using the template below.
7. Move the issue back to `Human Review`. Do **not** move the issue to `Done`.

## Completion Confirmation Handoff Template

```md
## Review Handoff

Status: Waiting for completion confirmation

**PR**: [#NNNN](URL) | **Merge**: [<commit-sha>](URL)

### 合并结果
<PR、merge commit、CI 结果，以及任何部署 caveat>

### 目标验证
- ✅ <acceptance criterion> — <证据>
- ❓ <acceptance criterion> — <仍待观察或需人工确认，说明原因>

### 后续事项（无则省略）
- <follow-up issues、监控窗口、回滚路径>

> [!IMPORTANT]
> 👉 **Human action needed**: 确认合并结果符合预期，将 issue 置为 `Done`；如有问题置为 `Rework`。
```

### Writing rules

- Map every acceptance criterion from the workpad 1:1 in the 目标验证 section.
  Use ✅ for verified with evidence, ❓ for items still pending human or runtime
  confirmation. Do not omit ❓ items.
- For acceptance criteria involving persistent outputs (MEMORY.md writes, file
  generation, database records), evidence must include a readable content
  summary—direct quotes, per-item summaries, or key excerpts. A count like
  `promotion.applied=3` is not sufficient evidence for a ✅.
- Keep the handoff compact. Do not paste the full workpad, full logs, or
  environment troubleshooting steps.
- Body in Chinese except status enum values, commands, identifiers, and file
  paths.
