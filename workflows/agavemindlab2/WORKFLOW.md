---
tracker:
  kind: linear
  project_slug: $SYMPHONY_PROJECT_SLUG
  assignee: me
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 60000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    : "${SYMPHONY_REPO:?SYMPHONY_REPO is not set}"

    fork_owner="${GITHUB_FORK_OWNER:-$(gh api user -q .login)}"
    fork_repo="$fork_owner/$SYMPHONY_REPO"
    base_branch="${SYMPHONY_BASE_BRANCH:-main}"

    gh repo clone "$fork_repo" .

    if ! git remote get-url upstream >/dev/null 2>&1; then
      git remote add upstream "https://github.com/agavemindlab/$SYMPHONY_REPO.git"
    fi

    git fetch upstream "$base_branch" --prune

    if [ -f "$SYMPHONY_WORKFLOW_DIR/setup.sh" ]; then
      "$SYMPHONY_WORKFLOW_DIR/setup.sh"
    fi

    mkdir -p .agents/skills
    if [ -d "$SYMPHONY_WORKFLOW_DIR/skills" ]; then
      for skill in "$SYMPHONY_WORKFLOW_DIR"/skills/*; do
        [ -d "$skill" ] || continue
        name="${skill##*/}"
        target=".agents/skills/$name"
        if [ -e "$target" ]; then
          continue
        fi
        cp -R "$skill" "$target"
        if [ -d .git/info ]; then
          exclude_entry=".agents/skills/$name/"
          grep -Fxq "$exclude_entry" .git/info/exclude 2>/dev/null || printf '%s\n' "$exclude_entry" >> .git/info/exclude
        fi
      done
    fi
  before_remove: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    if [ -f "$SYMPHONY_WORKFLOW_DIR/teardown.sh" ]; then
      "$SYMPHONY_WORKFLOW_DIR/teardown.sh"
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on a Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless blocked by missing required permissions, secrets, or tools.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended Symphony orchestration session. Never ask a human to perform follow-up actions, except for explicit requirement-confirmation, plan-confirmation, or blocker handoff gates below.
2. Stop early only for a true blocker: missing required auth, permissions, secrets, tools, contradictory requirements, or an unconfirmed high-impact plan. If stopped, record the exact reason in the workpad and move the issue according to this workflow.
3. Final messages must report completed actions and blockers only. Do not include generic "next steps for user".
4. **Subagent use is explicitly authorized when available.** Do not wait for additional user confirmation before using subagents.

Work only in the provided repository copy. Do not touch any other path.

## Language Policy

Phase artifacts and other Linear comments are read by Chinese-speaking humans — write them in clear, readable Chinese:

- Use Chinese throughout; make full use of Linear-supported Markdown: callouts, tables, code blocks, horizontal rules, heading levels
- Use emoji to signal importance and structure; use tables for acceptance-criteria results and before/after comparisons
- Link to relevant PRs, issues, and resources so readers don't have to hunt
- Keep Phase artifact headings (`## Requirements`, `## Design`, `## Implementation`, `## Deployment`) exactly as written — routing depends on them
- Use English for code, commit messages, PR titles/bodies, test names, and repository documentation

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent must be able to talk to Linear, either via a configured Linear MCP server or the injected Symphony `linear_graphql` tool. If neither is present, stop through the blocker handoff flow.

## Operational Safety Boundaries

- Default allowed write targets are the assigned repository workspace, the current issue's persistent Linear comments/state, the current PR branch on `origin`, and the GitHub PR for the issue.
- Do not modify production infrastructure, services, databases, queues, storage, payment systems, analytics exports, or customer/user data.
- Do not run destructive commands such as `rm -rf`, `git reset --hard`, `git clean -fdx`, broad database deletes, infrastructure deletes, or deploy commands unless the confirmed plan explicitly requires it.
- Do not push directly to `upstream/$SYMPHONY_BASE_BRANCH`, `upstream/main`, or any protected/base branch. Push only to the current issue PR branch on `origin`.
- Do not force-push except when the `symphony-pull`, `symphony-pr`, or `symphony-land` skill explicitly requires `--force-with-lease` for the current PR branch, after checking the remote branch did not advance with unrelated human work.
- Do not commit generated, cache, build, pyc, or temporary artifacts.
- Do not expose secrets in Linear comments, PR comments, commit messages, logs, screenshots, or workpad notes.

## Phase Map

The workflow progresses through four sequential phases. Each phase has a dedicated skill.

| Phase | Skill | Trigger |
|-------|-------|---------|
| Requirements | `phase-requirements` | New issue; requirements not yet confirmed |
| Design | `phase-design` | Requirements approved |
| Implementation | `phase-implementation` | Design approved |
| Deployment | `phase-deployment` | Human approves merge (`Merging` state) |

Requirements, Design, and Implementation all run in the `In Progress` Linear state; the workpad `current_phase` distinguishes them.

When the agent finishes **Requirements** or **Design** on a fresh run and is confident a human would very likely approve the artifact as-is, it **auto-advances** to the next phase in the same session instead of stopping for review; if the artifact is complete but the agent is not confident, it stops for human review. See Main Flow step 6. **Implementation** always stops at `Human Review` (the PR is up), and **Deployment** is reachable only via `Merging`.

## Main Flow

Symphony only starts the agent when the issue is in an active state (`Todo`, `In Progress`, `Merging`, `Rework`). Other states never reach this flow.

1. Open and follow `.agents/skills/symphony-linear/SKILL.md` to fetch the issue, its current Linear state, and its active (unresolved) Phase artifacts.

2. Ensure the feature branch exists so `.symphony/workpad.md` is readable and writable:
   - Read the issue's `branchName` field from Linear.
   - If already on that branch, continue. Otherwise check it out — preferring an existing branch on `origin`, then a local branch, then creating a new one from `upstream/${SYMPHONY_BASE_BRANCH:-main}`.

3. Route by Linear state:
   - `Todo` → move to `In Progress`, then continue as `In Progress`.
   - `Merging` → the human approved the PR. Write an approval reply on `## Implementation`: `✅ 已批准，进入 Deployment（[timestamp]）`. Target phase = Deployment; go to step 6.
   - `In Progress`, `Rework` → determine the target phase via steps 4–5.

4. Gather the signals:
   - Identify the phase awaiting review = the most recent artifact with no closing reply (neither `✅` human approval nor `⏩` auto-advance). The workpad `current_phase` should already name it; if the workpad is absent (brand-new branch), infer it as the most recent phase whose artifact exists. No artifacts at all → target phase is Requirements, go to step 6.
   - Gather new human feedback from two places: (a) replies in each unresolved Phase artifact's thread, and (b) standalone top-level comments on the issue that are not replies to any artifact. Scan **every** unresolved artifact, not just the awaiting-review one — humans request cross-phase rework by commenting on the artifact they want changed (e.g. feedback on `## Design` while `## Implementation` awaits review). "New" = newer than the agent's last closing reply on that artifact (or, for standalone comments, newer than the agent's last action). Attribute each standalone comment to the phase it discusses; if unclear, assume the awaiting-review phase. If a comment refers back to an earlier round ("上次"/"之前提到的"), pull the specific resolved comment it points to per the `symphony-linear` skill's back-reference exception.
   - When the awaiting-review phase is Implementation, the **PR is also a feedback channel** — but only for **human** reviewers. Humans often leave change requests as GitHub PR review comments instead of repeating them on Linear; gather new human PR review comments / inline threads / review states and treat them as feedback targeting Implementation. Bot / automated reviews (e.g. the configured `AUTOMATED_REVIEWER`) are **not** human intent: a bot approval never counts as a human approval, and a bot's comments are addressed by the Implementation PR feedback sweep, not by this intent check. Identify the author of each PR review/comment and drop bot ones before judging intent.
   - Note the Linear state (`In Progress` vs `Rework`).

5. Determine intent:

   **If the human left new feedback**, read it to understand the intent — approval, question, or change request — using the Linear state as a hint (`In Progress` leans approval, `Rework` leans change request) to break ambiguity:
   - **Question / discussion** (asks for rationale or explores alternatives without requesting a concrete change) → answer in that artifact's thread. Do **not** write an approval reply, advance, resolve, or re-post the artifact. Return the issue to `Human Review` and stop — the human will approve, ask more, or request a change next.
   - **Approval** (accepts the work, possibly with non-blocking remarks) → write an approval reply on the awaiting-review artifact: `✅ 已批准，进入 [Next Phase]（[timestamp]）`. Target phase = the next phase. Address any non-blocking remark in that next phase.
   - **Change request** → target phase = the **earliest** phase (in Phase Map order) carrying a change request. If that phase is earlier than the awaiting-review phase, follow Cross-phase rework; otherwise it is a same-phase rework. When a later phase also carried feedback, record it in the workpad `notes` so it is not lost when that phase is redone. (A comment that both asks and requests a change is a change request; answer the question inside the rework summary.)

   **If the human left no feedback** (on Linear artifacts or, for Implementation, the PR), decide by Linear state alone:
   - **`In Progress`** → approval. Write an approval reply on the awaiting-review artifact and target the next phase.
   - **`Rework`** → a rework was requested but with no stated direction anywhere. Only after confirming there is no new PR feedback either, reply in the awaiting-review artifact's thread asking what to change (e.g. `🔧 已收到打回，但 Linear 与 PR 上都未看到具体修改要求，请说明需要调整的内容`); do not resolve or re-post the unchanged artifact. Return the issue to `Human Review` and stop. The human's next reply provides the direction, which the following session reads as a change request.

   **If the phase never reached review** (no awaiting-review artifact — e.g. an interrupted session resuming mid-phase) → target phase = the current phase, no approval reply.

   **Exception — Implementation → Deployment is gated by `Merging`.** Deployment is irreversible (it merges and deploys) and is entered **only** via the `Merging` state (step 3). When the awaiting-review phase is Implementation, an approval detected in `In Progress` (with or without feedback) must **not** advance to Deployment, open `phase-deployment`, or write a Deployment approval reply. Treat it as "implementation accepted, awaiting the human's merge decision": leave the `## Implementation` artifact awaiting review, reply nudging `实现已通过 review，如需合并请将 issue 置为 Merging`, return the issue to `Human Review`, and stop.

6. Set the workpad `current_phase` to the target phase and open the matching phase skill (per the Phase Map). The skill does its phase work, posts or updates its own artifact, and on a **clean** exit hands back one of two outcomes — the skill alone decides which (see its "Exit"); only the Requirements and Design skills ever choose `advance`:

   - **`advance`** → write the `⏩ 自动进入 [Next Phase]` reply on the just-posted artifact, set the workpad `current_phase` to the next phase, and loop back to the start of step 6 with that as the target.
   - **`stop`** → move the issue to `Human Review` and stop.

   (A skill that stops **blocked** — unresolved `[NEEDS CLARIFICATION]` / escalated high-impact decision — moves the issue to `Human Review` itself; the session ends there.)

   This is the only auto-advance mechanism, and Main Flow does not second-guess the skill's choice. A single confident session may chain Requirements → Design → Implementation, but the Implementation skill always returns `stop` (the PR awaits the human's merge decision), so the chain always ends at `Human Review`; Deployment is reached only via `Merging` (step 3).

## Skill Interaction Protocol

This workflow runs unattended — no interactive UI. When any invoked skill needs a human decision, mark it `[NEEDS CLARIFICATION: <question>]` inline in the current phase's artifact, update the artifact comment, move the issue to `Human Review`, and stop. Each phase skill's "When blocked" section defines the detailed bridging procedure for that phase.

## Phase Artifact Protocol

Each phase maintains exactly one top-level comment on the Linear issue, identified by its heading (see Phase Map). A phase skill posts its artifact via `commentCreate`, or updates the existing one in place via `commentUpdate`. No phase edits another phase's artifact, and no comments are posted outside this protocol.

When content conflicts, precedence is: human reply in artifact thread > current artifact body > previous artifact > original issue description. Reconcile by updating the current artifact to absorb the human's intent.

### Phase-closing replies

A phase artifact is **closed** (no longer awaiting review) once its thread carries a Main-Flow-written closing reply. Two kinds exist:

- `✅ 已批准，进入 [Next Phase]（[timestamp]）` — **human approval**. Main Flow writes it (step 5, or the `Merging` branch of step 3) when a human accepted the phase.
- `⏩ 自动进入 [Next Phase]（agent 自评通过，未经人工评审，[timestamp]）` — **agent auto-advance**. Main Flow writes it when it advances a fresh, clean Requirements/Design phase without stopping (step 6).

Both are equivalent for routing: an artifact with **no** closing reply is the one still awaiting human review. The distinction is for humans — a `⏩` artifact was never human-gated, so the human is free to comment on it and set `Rework` to pull the chain back via cross-phase rework.

### Identifying the current artifact

Current artifact for a phase = the most recent comment of that type with no closing reply in its thread. Resolved artifacts (older rework versions) need not be read on session start.

### Rework cycle (same phase)

When the target phase is a rework of its own artifact:

1. Read the human feedback — from the artifact's thread, from any standalone issue comment addressing this phase, and (for Implementation) from PR review comments.
2. Do the rework.
3. Resolve the old artifact via `commentResolve` — its outdated content collapses out of the way.
4. Post a fresh artifact comment with the updated content.
5. Add a reply on the **new** artifact summarizing what changed since the last version and how each piece of human feedback was addressed (`🔧 本轮修改：...`, pointing back to the specific feedback). The changelog must live on the new artifact, not the resolved old one, so the human can review the update without expanding collapsed history.

### Cross-phase rework

When the human feedback requires revisiting an earlier phase (e.g., a design flaw found during Implementation review), Main Flow step 5 routes here:

1. Before resolving anything, copy any unaddressed human feedback on the phases being rolled back into the workpad `notes`, so it survives once those artifacts are resolved and is reconsidered when those phases are redone.
2. Reply in the awaiting-review artifact's thread: `🔄 反馈要求回到 [Target Phase]，当前阶段暂停`.
3. Resolve the awaiting-review artifact.
4. For each intermediate phase between target and the awaiting-review phase (if any), resolve that artifact too with a reply: `🔄 因跨阶段回退，此阶段需重新完成`.
5. Set workpad `current_phase` to the target phase and open the target phase skill.

The approval chain restarts from the target phase. All artifacts from target onward will be re-posted as those phases complete again.

## Workpad

Agent execution state lives in `.symphony/workpad.md` on the feature branch, committed to git. Machine-read fields (`current_phase`, `cleanup`) go in the YAML frontmatter; the rest is markdown. It is excluded from the final merge via the `cleanup` field.

```markdown
---
current_phase: Requirements   # Requirements | Design | Implementation | Deployment
cleanup:
  - .symphony/workpad.md
---

## Plan
- [ ] 1. Parent task
  - [ ] 1.1 Child task

## Acceptance Criteria
- [ ] S1: <executable check>

## Validation
- [ ] targeted tests: `<command>`

## Notes
- <short progress note with timestamp>
- Skills invoked: <comma-separated names>
```

### Persistence

Commit and push the workpad so origin always holds the latest agent state — this is what lets a recreated workspace recover via `git pull`. Whenever the workpad changes materially, and always before returning the issue to `Human Review`, run `git add .symphony/workpad.md && git commit && git push origin <branch>`.

## Guardrails

- **Phase gating**: phase advancement is driven by human signals (Linear state + human words), with one exception — the agent may **auto-advance** a fresh, clean Requirements or Design phase (Main Flow step 6). A bot / automated PR review (e.g. `AUTOMATED_REVIEWER`) is never an approval or a phase-routing signal; its feedback is handled inside the Implementation PR feedback sweep.
- **Auto-advance is upstream-only and confidence-gated**: only Requirements and Design may be auto-advanced, and only on a fresh, blocker-free run the agent judges a human would very likely approve as-is. Confidence — not formal completeness — is the gate; when in doubt, stop for review. A reworked phase, or one whose artifact already carries a human reply, always stops at `Human Review`. Implementation never auto-advances.
- **Deployment only via `Merging`**: the merge/deploy is irreversible and must be gated by the explicit `Merging` state. An approval of Implementation detected in any other state (e.g. `In Progress`) never triggers merge or opens `phase-deployment`.
- **Agent never moves to `Done`**: only humans close the issue. After Deployment concludes, the agent posts a completion summary in the `## Deployment` artifact thread and returns the issue to `Human Review`.
- **No phase advances without its artifact**: each phase must post or update its artifact before moving to `Human Review`.
- **`Human Review` is not an agent state**: Symphony does not start the agent there. Do not design any phase skill to act while the issue is in `Human Review`.
- **Out-of-scope improvements**: file a separate Linear issue instead of expanding the current issue.
