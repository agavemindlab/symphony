---
name: maestro
description: Use when the user invokes `$maestro ISSUE-1234` such as `$maestro DEV-1234` to get a subagent-assisted recommendation for how to reply to a Symphony issue currently in Human Review. The skill inspects the issue, active unresolved phase artifacts, human comments, and linked PR evidence when Implementation is awaiting review, then suggests the reply method and draft response without changing Linear or GitHub state.
---

# Maestro

## Goal

Launch an isolated Maestro reviewer subagent for a Symphony issue in
`Human Review`, then relay its recommendation. The skill is only the adapter:
collect evidence, start the subagent, and synthesize the result. Do not make the
review judgment in the parent agent.

## Workflow

1. Parse the issue key from the invocation, e.g. `$maestro DEV-1234`.
2. Read the issue and verify it is currently in `Human Review`.
   - Prefer available Linear tooling for issue title, description, state,
     comments, attachments, and links.
   - If direct Linear tools are unavailable, use local project CLIs or logs only
     when they provide reliable evidence; otherwise report the blocker.
3. Read active unresolved Phase artifacts: `## Requirements`, `## Design`,
   `## Implementation`, and `## Deployment`.
   - Drop resolved artifacts by default; read a resolved artifact only when a
     current human comment explicitly refers back to it.
   - The awaiting-review artifact is the most recent phase artifact whose thread
     has no closing reply: neither `✅ 已批准，进入 ...` nor `⏩ 自动进入 ...`.
   - Gather new human feedback from every unresolved artifact thread and from
     standalone top-level human comments. Attribute unclear standalone comments
     to the awaiting-review phase.
   - When `## Deployment` is awaiting review, include the accepted close test:
     the `## Requirements` acceptance criteria plus later human-approved scope
     or verification changes.
4. Inspect linked PRs only when `## Implementation` is awaiting review:
   - `gh pr view <pr> --json number,title,url,state,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,comments`
   - `gh pr diff <pr>`
   - `gh pr checks <pr>` when available
   - Treat only human PR reviews/comments as phase feedback; ignore bot approval
     as a human approval signal.
5. Read `agents/maestro-reviewer.md` and spawn exactly one fresh subagent with
   context forking disabled. Pass only that reviewer prompt and the explicit
   evidence pack. Do not pass current conversation history, prior `$maestro`
   results, or your own expected answer.
6. Compare the subagent's recommendation with the evidence. If it is unsupported
   or misses later comments, correct it in the final answer and explain why.
7. Return a concise Chinese recommendation with:
   - `建议回复方式`: approve / request changes / ask clarification / merge nudge /
     completion confirmation / no reply yet.
   - `回复对象`: next Symphony agent / human.
   - `建议回复`: a ready-to-send Chinese draft. For approve, request changes,
     merge nudge, and completion confirmation, set `回复对象` to next Symphony
     agent and write it as the human's review note for the next run. For ask
     clarification and no reply yet, set `回复对象` to human and write it for
     the human, explaining what Maestro cannot decide.
   - `依据`: 2-5 evidence bullets.
   - `注意`: only if there is uncertainty or missing evidence.

## Evidence Pack

Send the subagent a prompt shaped like this, after the contents of
`agents/maestro-reviewer.md`:

```text
Use the Maestro reviewer prompt above to advise on the issue below. Rely only
on that prompt and this explicit evidence; ignore any prior conversation
context. Do not mutate Linear, GitHub, files, or issue state.

Issue: <KEY> <title>
Current state: <state>
Issue type/context: <Type:Spike / normal / unknown>
Awaiting-review phase: <Requirements | Design | Implementation | Deployment>
Awaiting-review artifact:
<current unresolved phase artifact text>

Other unresolved phase artifacts and feedback:
<artifact summaries, thread replies, standalone human comments, or "none">

Clarification markers:
<unresolved [NEEDS CLARIFICATION] markers and human answers, or "none">

Acceptance source of truth for all phases:
<approved Requirements acceptance criteria and later human-approved changes, or "unknown">

Linked PR evidence, only for Implementation review:
<PR metadata, checks, human review state/comments, important diff summary, or "none">

Task:
1. Decide the best reply method: approve, request changes, ask clarification,
   merge nudge, completion confirmation, or no reply yet.
2. State the reply audience: next Symphony agent or human.
3. Draft the exact Chinese reply the human could post. For approve, request
   changes, merge nudge, and completion confirmation, address the next Symphony
   agent run. For ask clarification and no reply yet, address the human.
4. For every phase, compare the artifact's evidence with the acceptance source
   of truth; do not rely only on the Symphony agent's self-assessment or `✅`
   statuses.
5. Apply the relevant review lens from the reviewer prompt: Requirements /
   Design rigor, Implementation / Deployment verification, or bugfix / rework
   root cause.
6. Cite the decisive evidence and call out missing evidence or uncertainty.
Keep the answer concise and do not recommend changing state directly unless the
human's reply should explicitly instruct that.
```
