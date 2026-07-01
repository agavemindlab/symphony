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
      for skill in "$project_workflow_dir"/skills/*; do
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
  issue_running: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    sh "$SYMPHONY_WORKFLOW_DIR/mark-running-issue.sh" running
  issue_stopped: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    sh "$SYMPHONY_WORKFLOW_DIR/mark-running-issue.sh" stopped
agent:
  max_concurrent_agents: 5
  max_turns: 1
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
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

Approvals and no-action keep the issue in `Human Review`.
Do not move the issue to `Merging` or `Done`.

- If `$maestro` says `request changes` / `rework`, reply in the current artifact
  thread with the Maestro-chosen request-changes content, include the
  artifact id and head, move the issue to `Rework`, then remove
  `symphony:maestro`.
- If `$maestro` says `approve`, reply in the current artifact thread with the
  Maestro-chosen approval content, include the artifact id and head, add a
  `0-10` confidence score plus short rationale, keep the issue in
  `Human Review`, then remove `symphony:maestro`.
- If `$maestro` has no actionable approve/rework decision, reply with a concise
  no-action reason when there is a safe artifact thread, keep the issue in
  `Human Review`, then remove `symphony:maestro`.

Every review/no-action reply starts with `🤖 Maestro 预审核:`. Do not write
phase-closing replies such as `✅ 已批准` or `⏩ 自动进入`.

If label cleanup fails after a reply, stop anyway; the same artifact/head marker
prevents duplicate review and the next pickup must retry cleanup before doing
anything else.
