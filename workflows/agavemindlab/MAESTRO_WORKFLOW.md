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

    workflow_file="$SYMPHONY_WORKFLOW_DIR/MAESTRO_WORKFLOW.md"
    shared_workflow_dir="$SYMPHONY_WORKFLOW_DIR"
    if [ -L "$workflow_file" ]; then
      link_target="$(readlink "$workflow_file")"
      case "$link_target" in
        /*) shared_workflow_dir="$(cd "$(dirname "$link_target")" && pwd -P)" ;;
        *) shared_workflow_dir="$(cd "$(dirname "$workflow_file")/$(dirname "$link_target")" && pwd -P)" ;;
      esac
    fi

    maestro_after_create_failed() {
      status="$1"
      [ -n "${SYMPHONY_ISSUE_ID:-}" ] || return 0
      [ -f "$shared_workflow_dir/maestro-preflight-failure.sh" ] || return 0
      SYMPHONY_MAESTRO_FAILURE_STATUS="$status" \
        SYMPHONY_MAESTRO_FAILURE_REASON="pre-prompt after_create failed" \
        sh "$shared_workflow_dir/maestro-preflight-failure.sh" || true
    }

    trap 'status=$?; if [ "$status" -ne 0 ]; then maestro_after_create_failed "$status"; fi' EXIT

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

    trap - EXIT
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
label. It is a new top-level workflow session, not a fork of the working
session (`fork_context=false` equivalent). You are running under the Maestro
profile, so Linear writes must use the Maestro OAuth app identity.

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

   If checkout fails, use `linear_graphql` to find the current artifact thread
   if possible, write a `🤖 Maestro 预审核:` no-action reason there, remove
   `symphony:maestro` if Linear auth works, then stop.
3. Act as the Maestro reviewer directly in this session. Read
   `.codex/skills/maestro/agents/maestro-reviewer.md`, but use it only for
   review lenses, evidence requirements, and output schema. Its read-only
   mutation ban is superseded by this workflow's Apply section after you decide
   the review outcome. Collect Linear / GitHub / repository evidence and decide
   the review outcome here. Do not invoke the `$maestro` launcher or spawn a
   subagent; this workflow session is already the isolated reviewer.
4. Identify the current awaiting-review phase artifact and current PR/head when
   one exists. If there is already a `🤖 Maestro 预审核:` reply for the same
   artifact/head, write no second review. Remove `symphony:maestro` and stop.

## Apply The Recommendation

Always remove `symphony:maestro` before stopping, after any best-effort
reply/state update.

Approvals, ask-clarification, no-reply, and no-action keep the issue in
`Human Review`. Ignore any Maestro status recommendation to move an approve
result to `In Progress`; `Human Review` remains the human gate.
Do not move the issue to `Merging` or `Done`.

- If the review decision is `request changes` / `rework`, reply in the current
  artifact thread with the Maestro-chosen request-changes content, include the
  artifact id and head, then move the issue to `Rework`.
- If the review decision is `approve`, reply in the current artifact thread with
  the Maestro-chosen approval content, include the artifact id and head, add a
  `0-10` confidence score plus short rationale, keep the issue in
  `Human Review`.
- If the reviewer would address a human (`ask clarification`, `no reply yet`, or
  another non-approve/rework outcome), reply with that human-facing draft or a
  concise no-action reason when there is a safe artifact thread, then keep the
  issue in `Human Review`.

Every review/no-action reply starts with `🤖 Maestro 预审核:`. Do not write
phase-closing replies such as `✅ 已批准` or `⏩ 自动进入`.

If label cleanup fails after a reply, stop anyway; the same artifact/head marker
prevents duplicate review and the next pickup must retry cleanup before doing
anything else.
