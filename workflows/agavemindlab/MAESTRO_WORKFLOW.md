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
3. Identify the current awaiting-review phase artifact and current PR/head when
   one exists. Record that artifact/head and the latest human feedback/state
   activity as the pre-review snapshot. A prior reply qualifies for
   deduplication only when it is a Maestro preflight reply, matches the same
   artifact/head, and no newer human feedback or human-authored state action
   exists. For a qualifying reply, write no second review. If it carries the
   auto-rework marker below but the issue is still in `Human Review`, retry the
   `Rework` state update before removing `symphony:maestro`; otherwise keep
   `Human Review`, remove the label, and stop.
4. Read `.agents/skills/maestro/agents/maestro-reviewer.md` and apply it directly
   in this fresh preflight session, collecting Linear / GitHub / repository
   evidence plus Codex session transcripts referenced by phase artifact
   footers. Do not invoke `$maestro` or spawn a nested reviewer.
5. Immediately after reaching a recommendation and before any reply, state, or
   label write, re-read Linear and GitHub. Require `Human Review` with both labels,
   the same awaiting artifact and PR head as the pre-review snapshot, and no
   newer human feedback or human-authored state action. On any mismatch, discard
   the stale recommendation and stop without mutating Linear; an otherwise
   eligible item can receive a fresh dispatch.

## Apply The Recommendation

Every reply starts with `🤖 Maestro 预审核:`, includes `建议回复方式` and
`置信度：<N>/10`, and records the reviewed artifact id and Head. When
confidence is below 10/10, name the concrete evidence gap, ambiguity, or risk
that prevents a higher score and link it to `依据` or `注意`.

### Auto-rework ordinary request changes

- When the recommendation is `request changes`, reply in the reviewer-selected
  artifact thread with its exact `/rework <phase> ...` draft. Unless
  `MAESTRO_AUTO_REWORK` is `false`/`0`, end the reply with
  `🤖 auto: 已自动将 issue 置为 Rework`, move the issue to `Rework`, then remove
  `symphony:maestro`. This applies to ordinary Requirements, Design,
  Implementation, and Deployment review, except an `ESCALATED` Implementation review.
  With auto-rework disabled, leave the issue in `Human Review` and remove the
  label.
- For `Review verdict: ESCALATED`, require the reviewer recommendation to cite
  decisive Codex-session events and draft either `/rework implementation ...`,
  `/rework design ...`, or a human clarification. Never auto-rework it: leave
  the issue in `Human Review`, remove `symphony:maestro`, and wait for a newer
  human action.
- For every other recommendation, reply in the reviewer-selected artifact
  thread, leave the issue in `Human Review`, then remove `symphony:maestro`. A
  merge nudge may mention untidy commits, but must not rewrite history or
  reactivate the issue.

Do not write phase-closing replies such as `✅ 已批准` or `⏩ 自动进入`.

If label cleanup fails after a reply, stop anyway; the same artifact/head marker
prevents duplicate review and the next pickup must retry cleanup before doing
anything else.
