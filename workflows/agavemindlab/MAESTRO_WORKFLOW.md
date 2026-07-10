---
tracker:
  kind: linear
  project_slug: $SYMPHONY_PROJECT_SLUG
  project_slugs: $SYMPHONY_PROJECT_SLUGS
  project_name: $SYMPHONY_PROJECT_NAME
  project_names: $SYMPHONY_PROJECT_NAMES
  required_labels: ["symphony", "symphony:maestro"]
  active_states:
    - Human Review
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 60000
workspace:
  root: $SYMPHONY_MAESTRO_WORKSPACE_ROOT
hooks:
  after_create: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"

    if [ -f "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh" ]; then
      . "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh"
    fi

    project_workflow_dir="${SYMPHONY_PROJECT_DIR:-$SYMPHONY_WORKFLOW_DIR}"

    fork_owner="${GITHUB_FORK_OWNER:-$(gh api user -q .login)}"
    : "${SYMPHONY_REPO:?SYMPHONY_REPO is not set}"
    fork_repo="$fork_owner/$SYMPHONY_REPO"
    base_branch="${SYMPHONY_BASE_BRANCH:-main}"

    gh repo clone "$fork_repo" .

    if ! git remote get-url upstream >/dev/null 2>&1; then
      git remote add upstream "https://github.com/agavemindlab/$SYMPHONY_REPO.git"
    fi

    git fetch upstream "$base_branch" --prune
    git checkout -B "$base_branch" "upstream/$base_branch"

    if [ -f "$project_workflow_dir/setup.sh" ]; then
      "$project_workflow_dir/setup.sh"
    fi

    mkdir -p .agents/skills
    if [ -d "$project_workflow_dir/skills" ]; then
      for skill in "$project_workflow_dir"/skills/* "$SYMPHONY_WORKFLOW_DIR"/../../.codex/skills/maestro; do
        [ -d "$skill" ] || continue
        name="${skill##*/}"
        target=".agents/skills/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
          continue
        fi
        skill_path="$(cd "$skill" && pwd -P)"
        ln -s "$skill_path" "$target"
        if [ -d .git/info ]; then
          exclude_entry=".agents/skills/$name"
          grep -Fxq "$exclude_entry" .git/info/exclude 2>/dev/null || printf '%s\n' "$exclude_entry" >> .git/info/exclude
        fi
      done
    fi
agent:
  max_concurrent_agents: 5
  max_turns: 1
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.6-sol"' --config model_reasoning_effort=high app-server
  # The session blocks silently on the $maestro reviewer subagent for 10-20
  # minutes; the default 5m stall detector would kill every review mid-wait.
  stall_timeout_ms: 1800000
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are the Maestro preflight workflow for Linear issue `{{ issue.identifier }}`.

This is a fresh Codex session. It exists only because the normal Symphony
workflow moved the issue to `Human Review` and added the `symphony:maestro`
label. You are running under the Maestro profile, so Linear writes must use the
Maestro OAuth app identity.

## 引擎预计算的路由事实

{{ routing_brief }}

## Required Checks

1. Re-read the issue with `linear_graphql`. Continue only if it is still in
   `Human Review` and has both `symphony` and `symphony:maestro`.
2. Ensure this workspace is on the project main branch. The target ref is
   `upstream/${SYMPHONY_BASE_BRANCH:-main}`:

   ```sh
   base_branch="${SYMPHONY_BASE_BRANCH:-main}"
   git fetch upstream "$base_branch" --prune
   git checkout -B "$base_branch" "upstream/$base_branch"
   git status --short
   ```

   If checkout fails, remove `symphony:maestro` if Linear auth works, then stop.
3. Use `$maestro {{ issue.identifier }}`. The `$maestro` skill must run with
   context forking disabled and collect only Linear / GitHub / repository
   evidence. Do not pass it facts from this prompt beyond the issue key.
4. Identify the current awaiting-review phase artifact and current PR/head when
   one exists. If there is already a `🤖 Maestro 预审核:` reply for the same
   artifact/head, write no second review. Remove `symphony:maestro` and stop.

## Apply The Recommendation

Never move the issue to `Merging` or `Done`. Every review/no-action reply
starts with `🤖 Maestro 预审核:` and carries two machine-readable lines so
analytics can score the verdict later: `建议回复方式: <approve | request
changes | ask clarification | merge nudge | completion confirmation | no reply
yet>` and, when a confidence score exists, `置信度：<N>/10`.

- If `$maestro` says `request changes` / `rework`, reply in the current
  artifact thread with the Maestro-chosen request-changes content, include the
  artifact id and head. Unless the env `MAESTRO_AUTO_REWORK` is `false`/`0`,
  end the reply with the line `🤖 auto: 已自动将 issue 置为 Rework` and move
  the issue to `Rework` (reversible — a human who disagrees moves it back with
  a reason); with auto-rework disabled, keep the issue in `Human Review`.
  Then remove `symphony:maestro`.
- If `$maestro` says `approve`, reply in the current artifact thread with the
  Maestro-chosen approval content, include the artifact id and head, add a
  `0-10` confidence score plus short rationale. Only when ALL hold — env
  `MAESTRO_AUTO_APPROVE` is `true`/`1`; the awaiting phase is Requirements or
  Design (never Implementation, Deployment, or Spike findings); confidence >=
  `MAESTRO_AUTO_APPROVE_MIN_CONFIDENCE` (default 9) out of 10; and the
  artifact has no unresolved `[NEEDS CLARIFICATION]` marker and no 🔴
  high-impact open question — end the reply with the line
  `🤖 auto: 已自动批准，置为 In Progress` and move the issue to `In Progress`.
  Otherwise keep the issue in `Human Review`. Then remove `symphony:maestro`.
- If `$maestro` has no actionable approve/rework decision, reply with a concise
  no-action reason when there is a safe artifact thread, keep the issue in
  `Human Review`, then remove `symphony:maestro`.

Do not write phase-closing replies such as `✅ 已批准` or `⏩ 自动进入`.

If label cleanup fails after a reply, stop anyway; the same artifact/head marker
prevents duplicate review and the next pickup must retry cleanup before doing
anything else.
