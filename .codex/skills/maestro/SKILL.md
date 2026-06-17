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
   - For runtime-secret contract work, include whether the named runtime
     variables are present, without printing their values.
4. Inspect spawned or related issues mentioned by the current artifacts and
   Linear relations. Include each related issue's relation type, state, assignee,
   whether it is blocked by or blocks the reviewed issue, and whether validation
   or disposable issues have a durable relation plus a terminal cleanup state.
5. Inspect linked PRs only when `## Implementation` is awaiting review:
   - Identify the project's configured automated reviewer accounts first
     (especially `AUTOMATED_REVIEWER` from workflow env/defaults, such as
     `workflows/<project>/project.env*`). Treat those accounts as automated
     even if GitHub does not mark them as bots.
   - `gh pr view <pr> --json number,title,url,state,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,comments`
   - `gh pr diff <pr>`
   - `gh pr checks <pr>` when available
   - Treat only human PR reviews/comments as phase feedback; ignore bot or
     configured automated reviewer approval as a human approval signal.
6. Read `agents/maestro-reviewer.md` and spawn exactly one fresh subagent with
   context forking disabled. Pass only that reviewer prompt and the explicit
   evidence pack. Do not pass current conversation history, prior `$maestro`
   results, or your own expected answer.
7. Compare the subagent's recommendation with the evidence. If it is unsupported
   or misses later comments, correct it in the final answer and explain why.
8. Return a concise Chinese recommendation with:
   - `建议回复方式`: approve / request changes / ask clarification / merge nudge /
     completion confirmation / no reply yet.
   - `回复对象`: next Symphony agent / human.
   - `回复位置`: awaiting-review artifact thread / none.
   - `建议 issue status`: In Progress / Merging / Rework / Done / unchanged.
   - `建议回复`: a ready-to-send Chinese draft. For approve, request changes,
     merge nudge, and completion confirmation, set `回复对象` to next Symphony
     agent and write it as the human's review note for the next run. For ask
     clarification and no reply yet, set `回复对象` to human and write it for
     the human, explaining what Maestro cannot decide.
   - `依据`: 2-5 evidence bullets.
   - `注意`: only if there is uncertainty or missing evidence.

## Acting for the Human

By default, `$maestro ISSUE-1234` is read-only. If the user explicitly asks you
to send the reply for them, e.g. "帮我回复", then:

1. Reply in the exact target thread:
   - approve / request changes / ask clarification / completion confirmation:
     reply to the awaiting-review phase artifact's thread.
   - merge nudge: do not add a nudge comment unless the recommendation includes
     a human-facing clarification; the state change to `Merging` is the signal.
   - no reply yet: do not create a Linear comment.
2. Update the issue to `建议 issue status` when it is not `unchanged`.
3. Never resolve comments, write phase-closing replies (`✅ 已批准...`), create
   PR comments, merge, deploy, or move to `Done` unless the recommendation says
   `Done` and the user explicitly asked you to act.

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

Runtime secret provisioning:
<required variable names and present/missing status only, or "not applicable">

Spawned or related issue evidence:
<issue identifiers, relation types, state/assignee, blocker relation status,
validation/disposable issue cleanup status, and whether any downstream issue can
be selected before this one is accepted, or "none">

Linked PR evidence, only for Implementation review:
<PR metadata, checks, configured automated reviewer accounts, human review
state/comments after excluding bots/automated reviewers, important diff summary,
or "none">

Behavioral diff / new failure windows, only for bugfix Implementation review:
<side effects moved earlier/later, durable state before success, failure points
after those side effects, and tests or explanations covering them, or "none
identified">

Task:
1. Decide the best reply method: approve, request changes, ask clarification,
   merge nudge, completion confirmation, or no reply yet.
2. State the reply audience: next Symphony agent or human.
3. State the reply location.
4. State the recommended Linear issue status after the reply.
5. Draft the exact Chinese reply the human could post. For approve, request
   changes, merge nudge, and completion confirmation, address the next Symphony
   agent run. For ask clarification and no reply yet, address the human.
6. For every phase, compare the artifact's evidence with the acceptance source
   of truth; do not rely only on the Symphony agent's self-assessment or `✅`
   statuses.
7. Apply the relevant review lens from the reviewer prompt: Requirements /
   Design rigor, Implementation / Deployment verification, or bugfix / rework
   root cause.
8. Check whether spawned or related issues have the dependency relation or
   cleanup disposition needed to prevent unsafe parallel work or orphaned
   validation artifacts.
9. For bugfixes, reject artifacts that do not explain new failure windows caused
   by moved side effects or durable state before success.
10. Cite the decisive evidence and call out missing evidence or uncertainty.
Keep the answer concise and do not recommend changing state directly unless the
human's reply should explicitly instruct that.
```
