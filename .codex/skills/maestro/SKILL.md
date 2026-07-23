---
name: maestro
description: Use when the user invokes `$maestro ISSUE-1234` such as `$maestro DEV-1234` to get an isolated subagent recommendation for a Symphony issue currently in Human Review. The parent agent launches a fresh reviewer subagent with only the issue key; the subagent performs read-only Linear, GitHub, and referenced Codex-session evidence collection and returns an ordinary reply draft or an ESCALATED judgment card without changing state.
---

# Maestro

## Goal

Launch an isolated Maestro reviewer subagent for a Symphony issue in
`Human Review`, then relay its recommendation. The parent agent is only the
launcher and relay. Do not read, summarize, filter, or interpret the Linear
issue, PR, artifacts, comments, relations, or screenshots in the parent agent;
the reviewer subagent must collect evidence itself from the issue key.

## Workflow

1. Parse the issue key from the invocation, e.g. `$maestro DEV-1234`.
2. Read `agents/maestro-reviewer.md`.
3. Spawn exactly one fresh subagent with context forking disabled through the
   multi-agent tool, not `codex exec`. Pass only a plain-text message containing
   the full reviewer prompt, the issue key, and the task statement below. Do not
   pass current conversation history, issue title/state, artifact text, comment
   summaries, PR facts, prior `$maestro` results, your expected answer, or the
   reviewer prompt as a skill/file reference.
4. Wait for the subagent result. If required output fields are missing, or a
   below-10 confidence lacks a concrete reason matched to `依据` or `注意`, ask
   the same subagent once to fix only the format; do not supply issue facts.
5. For ordinary reviews, return the subagent's concise Chinese recommendation with:
   - `建议回复方式`: approve / request changes / ask
     clarification / merge nudge / completion confirmation / no reply yet.
   - `回复对象`: next Symphony agent / human.
   - `回复位置`: concrete Linear comment/thread to reply to, including phase
     heading, comment id or timestamp, or `none`.
   - `建议 issue status`: In Progress / Merging / Rework / Done / unchanged.
   - `建议回复`: a ready-to-send Chinese draft. For approve, request changes,
     merge nudge, and completion confirmation, set `回复对象` to next Symphony
     agent and write it as the human's review note for the next run. For ask
     clarification and no reply yet, set `回复对象` to human and write it for the
     human, explaining what Maestro cannot decide.
   - `置信度`: `N/10`; when below 10/10, name the concrete evidence gap, ambiguity,
     or risk that prevents a higher score and match it to `依据` or `注意`.
   - `依据`: 2-5 evidence bullets.
   - `注意`: only if there is uncertainty or missing evidence.
   For `Review verdict: ESCALATED`, relay the reviewer's advisory card instead:
   `收敛判断` (`continue implementation`, `rework design`, or
   `ask clarification`), `建议 target phase`, `建议 issue status`,
   `执行状态: awaiting human action`, `判断理由`, and `下一轮建议方向`. A `rework design`
   card also includes `失效的 Design assumption`, `建议修改的机制或边界`,
   `下一轮 proof / acceptance criteria`, and `不受影响的既有约束`. An
   `ask clarification` card also includes one `待人工回答的问题` and its
   `回答判定标准`.

## Acting for the Human

By default, `$maestro ISSUE-1234` is read-only. If the user explicitly asks you
to send the reply for them, e.g. "帮我回复", then:

1. Reply in the exact target thread:
   - approve / ask clarification / completion confirmation: reply to the
     awaiting-review phase artifact's thread.
   - clarification-answer resume: when the human has supplied an answer to an
     unresolved `[NEEDS CLARIFICATION]` marker and asks you to send it, set the issue to `In Progress` after replying with that answer in the awaiting-review artifact thread; this is not phase approval.
   - request changes: reply to the artifact thread for the phase that must be
     reworked; for same-phase rework this is the awaiting-review artifact, and
     for cross-phase rework this may be Requirements, Design, or another
     unresolved artifact.
   - Implementation merge nudge: do not add a nudge comment unless the
     recommendation includes a human-facing clarification; the state change to
     `Merging` is the signal.
   - no reply yet: do not create a Linear comment.
2. Update the issue to `建议 issue status` when it is not `unchanged`, except for
   an ESCALATED judgment card: its `执行状态` remains `awaiting human action`, and
   an agent must not perform the status action. Override
   `unchanged` only for clarification-answer resume: set the issue to
   `In Progress` after posting the human's answer so Symphony can re-enter the
   current phase.
3. Never resolve comments, write phase-closing replies (`✅ 已批准...`), create
   PR comments, merge, deploy, or move to `Done` unless the recommendation says
   `Done` and the user explicitly asked you to act.

Maestro pre-review sessions auto-execute `request changes` by default, except an `ESCALATED` Implementation review: they append
`🤖 auto: 已自动将 issue 置为 Rework` and set the issue to `Rework`. Set
`MAESTRO_AUTO_REWORK=false` to keep ordinary request changes recommendation-only.
ESCALATED and all non-rework verdicts stay in `Human Review` until a later human
reply or state action starts the transition.

## Subagent Task

Send the subagent a prompt shaped like this, after the contents of
`agents/maestro-reviewer.md`:

```text
Use the Maestro reviewer prompt above to advise on issue <KEY>. Rely only on
the issue key and evidence you collect read-only from Linear, GitHub, local repo
metadata, and Codex session transcripts referenced by phase artifact footers.
Ignore any prior conversation context and parent-agent interpretation. Do not
mutate Linear, GitHub, files, or issue state.

Task:
1. Fetch and inspect the issue, active unresolved Phase artifacts with no
   phase-closing reply, human feedback, related issues, and PR evidence needed
   by the reviewer prompt.
2. Decide the best ordinary reply method, or emit the ESCALATED judgment card
   defined by the reviewer prompt.
3. State the reply audience: next Symphony agent or human.
4. State the concrete reply location, not an abstract label.
5. State the recommended Linear issue status after the reply.
6. For ordinary review, draft the exact Chinese reply the human could post. For
   approve, request changes, merge nudge, and completion confirmation,
   address the next Symphony agent run. For ask clarification and no reply yet,
   address the human.
7. For every phase, compare the artifact's evidence with the acceptance source
   of truth; do not rely only on the Symphony agent's self-assessment or `✅`
   statuses. For Deployment, do not approve a bundled `S1-S6` / main-readback
   summary when any item needs separate regression or historical evidence.
8. Apply the relevant review lens from the reviewer prompt: Requirements /
   Design rigor, Implementation / Deployment verification, or bugfix / rework
   root cause.
9. Check spawned or related issues for creation rationale, title/description,
   project/routing, assignee, dependency direction, `symphony` label, `To Do`
   state, and cleanup disposition. For Implementation, if the reviewed issue has
   no independent runtime/deployment value until related operational work
   finishes (infra, secrets, protected environments, test users, data
   reset/seed, allowlists, or "do not enable/deploy/run acceptance until X"),
   that related work is a prerequisite blocker and must block the reviewed
   issue; code that can land first, a default-off/no-op path, soft-start
   feedback, or merge-risk-only feedback does not make it a downstream
   follow-up. Do not classify the current PR's own post-merge
   deploy/verification as such a prerequisite; if an Implementation artifact
   parks on manual deploy/write authorization instead of handing off to
   `Merging` / Deployment, request rework unless it identifies a separate
   human-only provisioning action. If the relation is reversed, request
   changes / `Rework`, make
   blocker direction the primary reason, and do not recommend `Merging` unless
   you cite exact current-artifact approval text saying to merge/approve before
   the prerequisite finishes; conditional soft-start guidance such as "if this
   issue merges first, it must..." is not approval. Also check whether true
   downstream issues have enough inherited context to start safely once
   unblocked and are scheduled with `symphony` + `To Do` when they are otherwise
   ready.
10. For bugfixes, reject artifacts that do not explain new failure windows caused
   by moved side effects or durable state before success. When required
   regression validation, a `回归例`, or a historical issue anchor lacks a
   command, log, test, or manual exercise, request changes instead of completion
   confirmation. For workflow path regressions, readback or existing Linear
   state is not enough. If readback satisfies an `S<N>` group containing a
   regression example, require separate behavior evidence or explicit
   readback-only risk acceptance.
11. If the issue's why or acceptance asks whether the product improved a real
   outcome, do not recommend `Done` for observability-only delivery while
   material `partial`/`gap` signals still block that answer unless a linked,
   routed, scheduled follow-up exists or the human explicitly accepts dropping
   those gaps.
   Human approval that gap labels are shown or false outcome claims are avoided
   is not that acceptance. For dashboard/analytics/reporting issues, any `partial`/`gap`
   label on a metric named by the issue's purpose is a material proof gap, not
   just transparency.
12. Cite the decisive evidence and call out missing evidence or uncertainty.
13. For `Review verdict: ESCALATED`, follow the reviewer prompt's Codex-session
   trend rubric and cite its decisive events.
Keep the answer concise and do not recommend changing state directly unless the
human's reply should explicitly instruct that.
```
