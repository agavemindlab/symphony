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

Work only in the provided repository copy. Do not touch any other path.

## Language Policy

- Write Linear-facing content in Chinese, including workpad notes, blocker briefs, review handoff notes, and status summaries.
- For `## Review Handoff`, keep the marker header and `Status` enum values exactly as written for workflow routing, but write section headings, bullet content, risk notes, and the human-action sentence in Chinese.
- Keep code, code comments, commit messages, PR titles/bodies, test names, and repository documentation in English unless the target repository documents a different convention.
- Preserve exact command names, errors, file paths, identifiers, labels, and checklist item titles when quoting or when English is clearer for technical precision.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent must be able to talk to Linear, either via a configured Linear MCP server or the injected Symphony `linear_graphql` tool. If neither is present, stop through the blocker handoff flow.

## Project Setup

- This workflow is shared by all projects under `workflows/`.
- Project identity comes from `$SYMPHONY_WORKFLOW_DIR/project.env`; operators start Symphony with:

```sh
source workflows/<project>/project.env
./bin/symphony workflows/<project>/WORKFLOW.md
```

- `SYMPHONY_PROJECT_SLUG` selects the Linear project.
- `SYMPHONY_BASE_BRANCH` may override the default base branch; use `main` when unset.
- The project repository's own `AGENTS.md` is the source of truth for build, test, validation, migration, and runtime commands.

## Default Posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every active ticket by opening the persistent `## Codex Workpad` comment and bringing it up to date before new implementation work.
- Spend extra effort up front on planning and validation design before implementation.
- Reproduce first when the ticket is a bug, regression, CI failure, broken script, or behavior mismatch.
- Keep ticket metadata current: state, checklist, acceptance criteria, links, and PR attachment.
- Treat the persistent `## Codex Workpad` comment as the agent continuation record.
- Treat `## Review Handoff` comments as compact per-handoff snapshots for human action. Each transition to `Human Review` must create a new handoff comment instead of editing or reusing an older handoff.
- At every stop for human action, update the detailed workpad first, then create a separate `## Review Handoff` comment last.
- Do not post additional "done" or summary comments outside the workpad and handoff protocol.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered, file a separate Linear issue instead of expanding the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by unclear requirements, unconfirmed high-impact engineering approach, missing requirements, secrets, permissions, or unavailable required tools.

## Operational Safety Boundaries

- Default allowed write targets are the assigned repository workspace, the current issue's persistent Linear comments/state, the current PR branch on `origin`, and the GitHub PR for the issue.
- Do not modify production infrastructure, services, databases, queues, storage, payment systems, analytics exports, or customer/user data.
- Do not run destructive commands such as `rm -rf`, `git reset --hard`, `git clean -fdx`, broad database deletes, infrastructure deletes, or deploy commands unless the confirmed plan explicitly requires it.
- Do not push directly to `upstream/$SYMPHONY_BASE_BRANCH`, `upstream/main`, or any protected/base branch. Push only to the current issue PR branch on `origin`.
- Do not force-push except when the `pull`, `push`, or `land` skill explicitly requires `--force-with-lease` for the current PR branch, after checking the remote branch did not advance with unrelated human work.
- Do not commit generated, cache, build, pyc, or temporary artifacts.
- Do not expose secrets in Linear comments, PR comments, commit messages, logs, screenshots, or workpad notes.

## Related Skills

The Symphony workflow skills are installed into `.agents/skills/`. When this workflow names a skill, open and follow its `SKILL.md` before acting.

- **Always**: `linear` at `.agents/skills/linear/SKILL.md`.
- **Requirement clarification**: `phase-clarification` at `.agents/skills/phase-clarification/SKILL.md`.
- **Solution design**: `phase-design` at `.agents/skills/phase-design/SKILL.md`.
- **Implementation**: `phase-implementation` at `.agents/skills/phase-implementation/SKILL.md`.
- **Merging**: `phase-merge-and-confirm` at `.agents/skills/phase-merge-and-confirm/SKILL.md`.
- Supporting skills: `commit`, `push`, `pull`, `land`, and `debug` under `.agents/skills/`.

## Discovery and Planning Gates

Before writing implementation code for any `Todo`, `In Progress`, or `Rework` ticket:

1. Analyze the issue state, workpad, description, acceptance criteria, comments, attachments, linked PRs, labels, and known blockers.
2. If requirements are contradictory, incomplete, too broad, or missing a safe default, batch blocking questions and recommendations into `## Review Handoff`, move the issue to `Human Review` with `Status: Waiting for requirement confirmation`, and stop.
3. If the engineering approach has a high-impact unresolved decision, use the plan-confirmation handoff. High-impact decisions include schema/data migrations, dependency changes, production/shared infrastructure, security/privacy behavior, public API contracts, irreversible data operations, or major product tradeoffs.
4. For ordinary implementation tradeoffs with a safe default, choose the simplest low-risk approach, record the decision in the workpad, and continue.
5. If the issue is too large for one focused PR, narrow the current scope or create clearly separable follow-up issues instead of expanding the current issue.
6. Write/update a hierarchical plan in the workpad with acceptance criteria and validation.

## Status Map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
- `In Progress` -> implementation actively underway.
- `Human Review` -> waiting on human action; do not actively implement while the issue is in this state.
- `Merging` -> approved by human; execute the `land` skill flow.
- `Rework` -> reviewer requested changes; planning and implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine Current Ticket State and Route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> stop and wait for human to move it to `Todo`.
   - `Todo` -> move to `In Progress`, ensure the workpad exists, then start execution.
   - `In Progress` -> continue from the current workpad.
   - `Human Review` -> wait for human action.
   - `Merging` -> open and follow `.agents/skills/phase-merge-and-confirm/SKILL.md`.
   - `Rework` -> run the rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed or merged. If it is closed or merged, create a fresh branch from `upstream/${SYMPHONY_BASE_BRANCH:-main}` and restart from reproduction/planning.

## Step 1: Start or Continue Execution

1. Find or create the persistent active `## Codex Workpad` comment.
2. Find the latest active `## Review Handoff` comment for context only.
3. Reconcile the workpad before new edits: check off completed items, expand/fix the plan, and keep acceptance/validation current.
4. Run the discovery and planning gates before implementation code.
5. Record a concrete reproduction or current-behavior signal before changing code.
6. Run the `pull` skill to sync with `upstream/${SYMPHONY_BASE_BRANCH:-main}` before edits and record merge source, result, and resulting short SHA.
7. Proceed through implementation using `.agents/skills/phase-implementation/SKILL.md`.

## Step 2: Implementation Phase

1. Determine repo state (`branch`, `git status`, `HEAD`) and verify the kickoff sync result is recorded.
2. Implement against the workpad plan and keep the checklist current.
3. For behavior changes, write failing tests first, then implement the minimal passing change.
4. Run validation from the repository's `AGENTS.md`; do not invent project-specific validation commands in this workflow.
5. Re-check all acceptance criteria.
6. Before pushing, run the required validation for the scope and confirm it passes.
7. Use the `commit` and `push` skills to publish a feature branch to `origin` and create/update the PR.
8. Merge latest `upstream/${SYMPHONY_BASE_BRANCH:-main}` into the branch, resolve conflicts, and rerun checks before handoff.
9. Run the PR feedback sweep protocol until no outstanding actionable comments remain or a review timeout/caveat is explicitly handed off.
10. Create a fresh compact `## Review Handoff` comment last, then move the issue to `Human Review`.

## PR Feedback Sweep Protocol

When a ticket has an attached PR:

1. Identify the PR number from issue links or attachments.
2. Gather top-level PR comments, inline review comments, and review summaries/states.
3. Treat every actionable reviewer comment as blocking until code/test/docs are updated or explicit justified pushback is posted on the same thread.
4. Update the workpad plan/checklist with each feedback item and its resolution.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat until no outstanding actionable comments remain and checks are understood.

## Review Handoff Template

Use this structure for every separate handoff comment. Create a new comment last before moving to `Human Review`.

- Keep the `## Review Handoff` heading and `Status:` field as plain top-level text. Do not wrap them in callouts, blockquotes, or `<details>` blocks because workflow routing depends on them.
- For PR review handoffs, include the summary, changed areas, review focus, risks, validation, and follow-ups sections in that order. Prefix section headings with these emoji labels: `📝 变更摘要（summary）`, `📂 变更范围（changed areas）`, `🔎 审核重点（review focus）`, `⚠️ 风险/注意（risks）`, `✅ 验证`, and `📌 后续事项（follow-ups）`. Write `无` for risks or follow-ups when there is nothing to call out.
- In summary, make the first bullet a one-sentence synthesis of intent or result, not a label list; use later bullets for concrete details.
- In changed areas, mark deltas inline with `（新增）/（修改）/（语义变化: X→Y）/（顺序调整）` so reviewers do not need to diff the old template mentally.
- In validation, map evidence back to acceptance criteria（映射回 acceptance criteria）. Prefer a table such as `| 验收项 | 状态 | 证据 |`; use exactly these status-column conventions: `✅ 通过`, `⚠️ 部分通过`, `➖ N/A`, and `❌ 失败`. If an acceptance criterion has no measurable check, say so explicitly with `➖ N/A`.
- In review focus and risks, mark each item as `🚨 blocker` or `💡 nit` so reviewers can distinguish required fixes from non-blocking observations. Do not stack the previous square-bracket plain labels with the emoji labels.
- When risks contain a `🚨 blocker`, wrap the blocker item or risk block in a Linear warning callout using `> [!WARNING]`.
- In `Human action needed`, use a Linear callout or blockquote and give finite options such as `OK → Merging；想改 X → Rework` instead of only asking for review. Prefer `> [!IMPORTANT]` followed by `> 👉 **Human action needed**: ...`.
- Separate major PR handoff sections with horizontal rules (`---`) so Linear renders clear visual breaks.
- When a Review Handoff includes a Before/After comparison, wrap the Before content in `<details>` with a `<summary>` line, and keep After expanded as the visual focus.
- Keep bullets short and scannable in Linear comments. Start changed-area bullets with a file path, module, command, or workflow area when possible.
- Use parentheses or dash side notes for compact context, for example `（由“可省略”改为“无内容写 无”）`, instead of splitting every detail into separate bullets.
- For requirement, plan, or blocker handoffs, omit PR-only sections and include only the decision/blocker sections that apply.

```md
## Review Handoff

Status: Waiting for PR review

📝 变更摘要（summary）:
- <第一条用一句话陈述意图或结果；后续 bullet 补主要决策或用户可见变化>

---

📂 变更范围（changed areas）:
- `<关键文件/模块/流程>`: <用 `（新增）/（修改）/（语义变化: X→Y）/（顺序调整）` 标注 delta，并说明 reviewer 需要知道什么>

---

🔎 审核重点（review focus）:
- 🚨 blocker <需要人工重点查看的文件、流程、边界条件或决策点>
- 💡 nit <非阻塞的措辞、展示或偏好检查>

---

⚠️ 风险/注意（risks）:
> [!WARNING]
> - 🚨 blocker <阻塞风险、回归面或验证 caveat>
- 💡 nit <非阻塞风险或观察；没有则写“无”>

---

✅ 验证:
| 验收项 | 状态 | 证据 |
|---|---|---|
| <acceptance criterion> | ✅ 通过 | <命令或检查结果> |
| <acceptance criterion> | ⚠️ 部分通过 | <已验证范围与需要人工判断的 caveat> |
| <acceptance criterion> | ➖ N/A | <无对应可测项的原因> |
| <acceptance criterion> | ❌ 失败 | <命令、影响和后续处理> |

---

📌 后续事项（follow-ups）:
- <未完成事项、已拆出的 follow-up、非阻塞观察；没有则写“无”>

已回应的问题（如上一轮 human review 提问/质疑/要求证据；否则省略）:
- <直接回答问题，并说明对应证据或修复结果>

问题/选项（仅 requirement/plan confirmation；否则省略）:
- <阻塞决策、选项、推荐默认值、接受默认值后会怎么做>

阻塞（仅 Blocked；否则省略）:
- <blocker、影响、已尝试事项、精确 unblock action>

> [!IMPORTANT]
> 👉 **Human action needed**: <给出有限选项，例如 `OK → Merging；想改 X → Rework`>
```

When including a Before/After comparison in a handoff, format it this way:

```md
<details>
<summary>📜 展开旧模板下的 handoff（仅供对比，可跳过）</summary>

<Before 内容>

</details>

### After（当前模板）

<After 内容>
```

## Workpad Template

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Current Attempt

#### Plan

- [ ] 1. Parent task
  - [ ] 1.1 Child task

#### Acceptance Criteria

- [ ] Criterion 1

#### Validation

- [ ] targeted tests: `<command>`

#### Notes

- <short progress note with timestamp>
````
