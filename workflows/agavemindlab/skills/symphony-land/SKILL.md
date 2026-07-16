---
name: symphony-land
description:
  Land a PR by detecting conflicts, waiting for checks, and running post-merge
  verification; use when asked to land, merge, or shepherd a PR to completion.
---

# Land

## Goals

- Preserve the approved Implementation artifact's exact reviewed Head through
  GitHub's atomic merge guard; treat Base as best-effort audit evidence.
- Ensure the PR is conflict-free with `upstream/${SYMPHONY_BASE_BRANCH:-main}`.
- Keep PR CI and post-merge verification runs green.
- Use the approved `## Implementation` artifact — its `风险/注意` (merge
  safety) and `Merge 后验证` (post-merge verification plan) sections — as the
  Merging gate.
- Squash-merge the PR once checks pass, then watch the `main` workflows for
  the merge commit.
- Do not yield to the user until the PR is merged and the post-merge runs are
  complete, or until a failure has been reported and a rollback decision is made.
- No need to delete remote branches after merge if the repo auto-deletes head
  branches; check `AGENTS.md` for the project's branch deletion policy.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch with a clean working tree.

## Steps

1. Locate the PR for the current branch.
2. Confirm the human approved Merging (the issue is in the `Merging` state)
   and read the approved `## Implementation` artifact before merging. It must
   supply three gate elements:
   - Full audit-evidence `Base` and `Head`; carry them as `reviewed_base` and
     `reviewed_head`.
   - A merge-safety read: the `验收对照` and `风险/注意` sections establish
     whether the PR is safe to merge and whether any remaining issue could
     crash services, corrupt/lose data, break background jobs, or only affect
     a bounded path.
   - A post-merge verification plan: the `Merge 后验证` section lists the
     exact runnable checks to run after merge (required when any acceptance
     criterion is `延迟验收` — see phase-requirements' Verifiability
     classification).
   If any element is missing, do not merge; note the gap in the
   `## Implementation` thread and return the issue to `Human Review`.
3. Query the current PR and fork branch Heads; require both and local `HEAD` to
   equal `reviewed_head`. Record current Base versus `reviewed_base` as a
   best-effort comparison. A missing or mismatched Head ends the landing attempt.
4. Confirm the relevant `AGENTS.md` validation is green without changing the
   worktree. Uncommitted changes end the landing attempt.
5. Check mergeability and conflicts. If conflict resolution, commit
   organization, a CI fix, review fix, or any push is needed, stop before changing
   Head and return to a fresh Implementation review.
6. Ensure automated and human review feedback is addressed. Feedback requiring
   code changes returns to Implementation; do not edit, commit, or push here.
7. Watch checks until complete, or until the bounded watcher reports that no PR
   checks were configured/triggered for this branch.
8. If checks fail, pull logs and return to Implementation; do not fix the
   reviewed Head during landing.
9. Recheck PR, local, and fork Heads. When checks and feedback are clear,
   squash-merge with `--match-head-commit "$reviewed_head"`.
10. Immediately capture the merge commit SHA and watch `main` workflow runs for
    that SHA. Follow the project's deployment trigger paths documented in
    `AGENTS.md` to determine which workflows may run after a merge to `main`.
11. Execute the post-merge verification plan from the latest handoff. Record
    concrete evidence in the workpad: workflow/deploy run URLs or SHAs, service
    health signals, smoke-test request/response, logs/error dashboard signal,
    worker/job result, or data-safe read-only verification.
12. If a post-merge run fails, is cancelled, times out, or does not appear when
    expected, inspect the run logs and report the deployment risk immediately.
13. If any planned post-merge verification fails or cannot be run, keep the issue
    out of `Done`, record the failed signal, and report the risk immediately.
14. Automatically rollback only when the rollback guardrails below prove it is
   data-safe; otherwise stop and ask for human direction.

## Commands

```sh
# Ensure branch and PR context
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)

# Bind the artifact-reviewed Head before any mutable operation.
reviewed_base='<artifact Base>'
reviewed_head='<artifact Head>'
current_base=$(gh pr view --json baseRefOid -q .baseRefOid)
current_head=$(gh pr view --json headRefOid -q .headRefOid)
test "$current_head" = "$reviewed_head"
test "$(git rev-parse HEAD)" = "$reviewed_head"
branch=$(git branch --show-current)
test "$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')" = "$reviewed_head"
printf 'Reviewed Base: %s; current Base: %s\n' "$reviewed_base" "$current_base"

# Check mergeability and conflicts without changing Head.
mergeable=$(gh pr view --json mergeable -q .mergeable)

if [ "$mergeable" = "CONFLICTING" ]; then
  echo "Conflict resolution requires a fresh Implementation review." >&2
  exit 1
fi

# Inspect commit organization, but return to Implementation if it needs a rewrite.
gh pr view --json commits --jq '.commits[] | [.oid, .messageHeadline] | @tsv'
git log --stat --format='%H %s' "upstream/${SYMPHONY_BASE_BRANCH:-main}..HEAD"

# Wait for the current reviewed Head's checks without activating a separate
# feedback/check reducer.
check_count=$(gh pr view --json statusCheckRollup --jq '.statusCheckRollup | length')
test "$check_count" -eq 0 || gh pr checks --watch --fail-fast

# Squash-merge only the Head recorded in the approved artifact.
test "$(gh pr view --json headRefOid -q .headRefOid)" = "$reviewed_head"
gh pr merge --squash --match-head-commit "$reviewed_head" \
  --subject "$pr_title" --body "$pr_body"

# Watch post-merge main workflow runs for the merge commit.
# Use gh run list --branch main --commit <sha> --event push
# or the project's post-merge watcher script if one exists.
```

## Failure Handling

- If checks fail, pull details with `gh pr checks` and `gh run view --log`, then
  return to Implementation without changing the reviewed Head.
- If no PR checks appear after the bounded wait, continue only after review
  feedback and mergeability are clean; the post-merge watch still decides
  whether a `main` workflow run was expected.
- Use judgment to identify flaky failures. If a failure is a flake (e.g., a
  timeout on only one platform), you may proceed without fixing it.
- If CI or any actor pushes a commit, stop; the new Head needs a fresh
  Implementation review even when its tree is equivalent.
- If mergeability is `UNKNOWN`, wait and re-check.
- Do not merge while review comments (human or automated) are outstanding.

## Post-Merge Verification

After merging, identify the squash merge SHA and watch all `push` workflow
runs on `main` for that SHA. The specific workflows and deployment triggers
are documented in `AGENTS.md` — follow them to determine what to watch.

- If no runs appear and the PR only touched files outside deploy-triggered
  paths, record that no deploy was triggered.
- If deploy-triggered files changed and no run appears after a short wait,
  report that as a deployment signal failure.
- If any post-merge run fails, is cancelled, times out, or requires action,
  inspect logs with `gh run view <run-id> --log-failed` and report
  immediately: failed workflow/job, run URL, suspected cause, user impact,
  and rollback recommendation.
- Do not silently keep debugging a broken post-merge deploy. Report first,
  then continue remediation only when it is clearly safe.

## Rollback Guardrails

Automatic rollback means creating a normal revert of the merge commit. Do not
force-push, reset, or push directly to `main` or any protected base branch.

You may automatically create and land a revert PR only when all are true:

- The failed post-merge run is for the merge SHA you just landed.
- No newer production-affecting commit has landed on `main` after that SHA.
- The merged PR did not include database migrations, schema changes, data
  backfills, destructive data operations, persisted job/message format changes,
  payment/auth/security behavior changes, or infrastructure state changes.
- Reverting the merge commit applies cleanly and only undoes that PR.
- The rollback is expected to restore the previous deployed behavior without
  causing data loss or data/model/version skew.

If any condition is false or uncertain, do not rollback automatically. Report
the failure, state why rollback is unsafe or unclear, and ask for human
direction.

## Review Handling

- Automated review comments arrive as comments on the PR (format varies by
  project). Treat any comment that includes substantive feedback as requiring
  acknowledgement before merge.
- Human review comments are blocking and must be addressed (responded to and
  resolved) before requesting a new review or merging.
- If multiple reviewers comment in the same thread, respond to each comment
  (batching is fine) before closing the thread.
- Fetch review comments via `gh api` and reply with a `[codex]`-prefixed
  comment.
- Use review comment endpoints (not issue comments) to find inline feedback:
  - List PR review comments:
    ```
    gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
    ```
  - PR issue comments (top-level discussion):
    ```
    gh api repos/{owner}/{repo}/issues/<pr_number>/comments
    ```
  - Reply to a specific review comment:
    ```
    gh api -X POST /repos/{owner}/{repo}/pulls/<pr_number>/comments \
      -f body='[codex] <response>' -F in_reply_to=<comment_id>
    ```
- `in_reply_to` must be the numeric review comment id, not the GraphQL node id.
- All GitHub comments generated by this agent must be prefixed with `[codex]`.
- If feedback requires changes, reply that a fresh Implementation review is
  required and return without changing the reviewed Head.

## Scope + PR Metadata

- The PR title and description should reflect the full scope of the change, not
  just the most recent fix.
- Classify each review comment as one of: correctness, design, style,
  clarification, scope.
- For correctness feedback, provide concrete validation (test, log, or
  reasoning) before closing it.
- When accepting feedback, include a one-line rationale in the root-level
  update.
- When declining feedback, offer a brief alternative or follow-up trigger.
- Prefer a single consolidated "review addressed" root-level comment after a
  batch of fixes instead of many small updates.
