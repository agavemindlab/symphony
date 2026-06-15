---
name: maestro
description: Use when the user invokes `$maestro ISSUE-1234` such as `$maestro DEV-1234` to get a subagent-assisted recommendation for how to reply to a Symphony issue currently in Human Review. The skill inspects the issue, latest Review Handoff, human comments, and linked PR evidence, then suggests the reply method and draft response without changing Linear or GitHub state.
---

# Maestro

## Goal

Advise how to reply to a Symphony issue in `Human Review`. Use exactly one
subagent for the independent judgment, then synthesize the recommendation for
the user. Do not post comments, update Linear state, edit code, push commits, or
change GitHub unless the user explicitly asks after seeing the recommendation.
Do not let the subagent inherit the current conversation context; its judgment
must come only from this skill's prompt and the explicit issue evidence.

## Workflow

1. Parse the issue key from the invocation, e.g. `$maestro DEV-1234`.
2. Read the issue and verify it is currently in `Human Review`.
   - Prefer available Linear tooling for issue title, description, state,
     comments, attachments, and links.
   - If direct Linear tools are unavailable, use local project CLIs or logs only
     when they provide reliable evidence; otherwise report the blocker.
3. Find the latest active `## Review Handoff` comment and any later human
   comments.
4. Inspect linked PRs when relevant:
   - `gh pr view <pr> --json number,title,url,state,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,comments`
   - `gh pr diff <pr>`
   - `gh pr checks <pr>` when available
5. Spawn exactly one fresh subagent with context forking disabled. Pass only
   this skill and the evidence needed to decide how the human should reply. Ask
   for a recommendation only; forbid mutations.
6. Compare the subagent's recommendation with the evidence. If it is unsupported
   or misses later comments, correct it in the final answer and explain why.
7. Return a concise Chinese recommendation with:
   - `建议回复方式`: approve / request changes / ask clarification / merge nudge /
     completion confirmation / no reply yet.
   - `建议回复`: a ready-to-send Chinese draft.
   - `依据`: 2-5 evidence bullets.
   - `注意`: only if there is uncertainty or missing evidence.

## Subagent Prompt

Use a prompt shaped like this, filling in the issue evidence already gathered:

```text
Use $maestro to advise on the issue below. Rely only on this prompt, the
attached skill instructions, and the explicit evidence here; ignore any prior
conversation context.

You are advising how a human should reply to a Symphony Linear issue in Human
Review. Do not mutate Linear, GitHub, files, or issue state.

Issue: <KEY> <title>
Current state: <state>
Latest Review Handoff:
<handoff text>

Later human comments:
<comments or "none">

Linked PR evidence:
<PR metadata, checks, review state, and important diff summary or "none">

Task:
1. Decide the best reply method: approve, request changes, ask clarification,
   merge nudge, completion confirmation, or no reply yet.
2. Draft the exact Chinese reply the human could post.
3. Cite the decisive evidence and call out missing evidence or uncertainty.
Keep the answer concise and do not recommend changing state directly unless the
human's reply should explicitly instruct that.
```

## Decision Guide

- Approve when the handoff asks for review and the evidence satisfies the Spec,
  PR/check/review expectations, and later comments do not introduce blockers.
- Request changes when the next action is agent-actionable: missing acceptance
  evidence, failing relevant checks, unaddressed review comments, stale handoff,
  or implementation/spec mismatch.
- Ask clarification when the next action requires human judgment, product scope,
  or risk acceptance rather than agent work.
- Use a merge nudge when Implementation appears accepted but the workflow
  requires the human to move the issue to `Merging`.
- Use completion confirmation when the handoff is waiting for proof that merge,
  deployment, or post-merge validation completed.
- Say no reply yet when evidence is unavailable or the issue is not actually in
  `Human Review`.
