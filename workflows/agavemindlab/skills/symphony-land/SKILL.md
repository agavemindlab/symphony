---
name: symphony-land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  post-merge verification runs; use when asked to land, merge, or shepherd
  a PR to completion.
---

# Land

## Goals

- Ensure the PR is conflict-free with `upstream/${SYMPHONY_BASE_BRANCH:-main}`.
- Ensure the PR commit history is organized before merge, rewriting only when
  the history is scattered or fixup-heavy.
- Keep PR CI and post-merge verification runs green.
- Use the approved `## Implementation` artifact's `Acceptance mapping` and
  `合并风险判断` as the Merging gate, plus `Merge 后验证` when any criterion is
  `延迟验收`.
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
   and read the approved `## Requirements` and `## Implementation` artifacts
   before merging. Use Requirements' `关键假设` as the source of truth for
   `延迟验收`; Implementation must supply a merge-safety read plus a matching
   post-merge verification plan for each such criterion:
   - A merge-safety read: the `Acceptance mapping` and `合并风险判断` sections establish
     whether the PR is safe to merge and whether any remaining issue could
     crash services, corrupt/lose data, break background jobs, or only affect
     a bounded path.
   - A post-merge verification plan: the `Merge 后验证` section lists the
     exact runnable checks to run after merge (required when any acceptance
     criterion is `延迟验收` — see phase-requirements' Verifiability
     classification).
   A missing merge-safety read always blocks merging. A missing post-merge
   verification plan blocks merging only when an acceptance criterion is
   `延迟验收`. Note the gap in the `## Implementation` thread and return the
   issue to `Human Review`.
3. Confirm the relevant `AGENTS.md` validation is green locally before any push.
4. If the working tree has uncommitted changes, commit with the `symphony-commit` skill
   and push with the `symphony-pr` skill before proceeding.
5. Check mergeability and conflicts against
   `upstream/${SYMPHONY_BASE_BRANCH:-main}`.
6. If conflicts exist, use the `symphony-pull` skill to fetch/merge the upstream base
   and resolve conflicts, then use the `symphony-pr` skill to publish the updated branch.
7. **Commit organization gate:** before watching checks or merging, inspect the
   PR commit list (`gh pr view --json commits` or the equivalent GitHub API)
   and decide one of:
   - `no organization needed`: one clean commit, or multiple clean logical
     commits with distinct scopes, including a standalone test commit. Record
     the commit SHAs/messages in the workpad and Deployment evidence and do not
     rewrite the branch.
   - `reorganized`: fixup/squash commits, WIP commits, review-iteration
     commits, late lint/test repairs, repeated "address review" commits, or
     several small adjustment commits in the same logical scope. Capture the
     pre-rewrite remote SHA and tree hash; require local `HEAD` to equal that
     remote SHA before using a non-interactive
     rebase/autosquash or an equivalent semantic rewrite. The post-rewrite tree
     hash must match; otherwise stop and return to Implementation review. Abort
     if the remote moved, then publish with
     `--force-with-lease=refs/heads/<branch>:<expected-old-sha>` and request
     review again. Record the before/after commit list and `reorganized`
     decision.
   Record the resulting PR head as `gated_head`.
   Re-run this gate after any later fix, conflict-resolution, CI, or review
   feedback commit. Merge with `--match-head-commit "$gated_head"` so a later
   push cannot bypass the recorded decision.
8. Ensure any automated review comments (if present) are acknowledged and any
   required fixes are handled before merging.
9. Watch checks until complete, or until the bounded watcher reports that no PR
   checks were configured/triggered for this branch.
10. If checks fail, pull logs, fix the issue, commit with the `symphony-commit` skill,
   push with the `symphony-pr` skill, and re-run checks.
11. When all checks are green (or no checks appear after the bounded no-check
    wait) and review feedback is addressed, squash-merge using the PR
    title/body for the merge subject/body.
12. Immediately capture the merge commit SHA and watch `main` workflow runs for
    that SHA. Follow the project's deployment trigger paths documented in
    `AGENTS.md` to determine which workflows may run after a merge to `main`.
13. Execute the post-merge verification plan from the latest handoff. Record
    concrete evidence in the workpad: workflow/deploy run URLs or SHAs, service
    health signals, smoke-test request/response, logs/error dashboard signal,
    worker/job result, or data-safe read-only verification.
14. If a post-merge run fails, is cancelled, times out, or does not appear when
    expected, inspect the run logs and report the deployment risk immediately.
15. If any planned post-merge verification fails or cannot be run, keep the issue
    out of `Done`, record the failed signal, and report the risk immediately.
16. Automatically rollback only when the rollback guardrails below prove it is
    data-safe; otherwise stop and ask for human direction.
17. **Context guard:** Before implementing review feedback, confirm it does not
    conflict with the user's stated intent or task context. If it conflicts,
    respond inline with a justification and ask the user before changing code.
18. **Pushback template:** When disagreeing, reply inline with: acknowledge +
    rationale + offer alternative.
19. **Ambiguity gate:** When ambiguity blocks progress, use the clarification
    flow (assign PR to current GH user, mention them, wait for response). Do not
    implement until ambiguity is resolved.
    - If you are confident you know better than the reviewer, you may proceed
      without asking the user, but reply inline with your rationale.
20. **Per-comment mode:** For each review comment, choose one of: accept,
    clarify, or push back. Reply inline stating the mode before changing code.
21. **Reply before change:** Always respond with intended action before pushing
    code changes (inline for review comments, issue thread for automated reviews).

## Commands

```sh
# Ensure branch and PR context
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)

# Check mergeability and conflicts
mergeable=$(gh pr view --json mergeable -q .mergeable)

if [ "$mergeable" = "CONFLICTING" ]; then
  # Run the `symphony-pull` skill to handle fetch + merge + conflict resolution.
  # Then run the `symphony-pr` skill to publish the updated branch.
  :
fi

# Commit organization gate: inspect PR commits and per-commit patches before
# checks/merge.
# Record `no organization needed` for clean logical history. For fixup/squash,
# WIP, review-iteration, lint/test repair, or repeated adjustment commits, run
# a non-interactive rebase/autosquash or equivalent semantic rewrite. Preserve
# the tree hash and use an explicit expected-old-SHA lease.
branch=$(git branch --show-current)
expected_old_sha=$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')
test "$(git rev-parse HEAD)" = "$expected_old_sha"
before_tree=$(git rev-parse 'HEAD^{tree}')
gh pr view --json commits --jq '.commits[] | [.oid, .messageHeadline] | @tsv'
git log --stat --format='%H %s' "upstream/${SYMPHONY_BASE_BRANCH:-main}..HEAD"

# Set `gate_decision` to one exact decision after inspection. The clean branch
# deliberately performs no rewrite or push.
case "$gate_decision" in
  "no organization needed")
    ;;
  reorganized)
    test "$(git rev-parse 'HEAD^{tree}')" = "$before_tree"
    test "$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')" = "$expected_old_sha"
    git push origin "HEAD:refs/heads/$branch" \
      --force-with-lease="refs/heads/$branch:$expected_old_sha"
    ;;
  *)
    echo "Record a valid commit organization decision before continuing." >&2
    exit 1
    ;;
esac

gated_head=$(gh pr view --json headRefOid -q .headRefOid)

# Watch review feedback, PR checks, mergeability, and PR head updates.
# Implement a polling loop appropriate to the project's CI setup, or
# use the project's land watcher script if one exists under .agents/skills/symphony-land/.
python3 .agents/skills/symphony-land/scripts/land_watch.py 2>/dev/null || \
  echo "No land_watch.py found; poll manually with: gh pr checks && gh pr view --json reviews" >&2

# Squash-merge only the head that passed the gate.
gh pr merge --squash --match-head-commit "$gated_head" \
  --subject "$pr_title" --body "$pr_body"

# Watch post-merge main workflow runs for the merge commit.
# Use gh run list --branch main --commit <sha> --event push
# or the project's post-merge watcher script if one exists.
```

## Async Watch Helper

If the project provides an asyncio watcher script at
`.agents/skills/symphony-land/scripts/land_watch.py`, prefer it to monitor review
comments, CI, and head updates in parallel. Typical exit codes:

- 2: Review comments detected (address feedback)
- 3: CI checks failed
- 4: PR head updated (autofix commit detected)

If no watcher script is present, poll manually using:
- `gh pr checks` for CI status
- `gh pr view --json reviews` for review state
- `gh pr view --json mergeable` for mergeability

## Failure Handling

- If checks fail, pull details with `gh pr checks` and `gh run view --log`, then
  fix locally, commit with the `symphony-commit` skill, push with the `symphony-pr` skill, and
  re-run the commit organization gate and watch.
- If no PR checks appear after the bounded wait, continue only after review
  feedback and mergeability are clean; the post-merge watch still decides
  whether a `main` workflow run was expected.
- Use judgment to identify flaky failures. If a failure is a flake (e.g., a
  timeout on only one platform), you may proceed without fixing it.
- If CI pushes an auto-fix commit (authored by GitHub Actions), it does not
  trigger a fresh CI run. Detect the updated PR head, pull locally, merge
  the upstream base if needed, add a real author commit, and force-push to
  retrigger CI, then restart the checks loop.
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
- If feedback requires changes:
  - Reply with intended fixes `[codex] ...` inline to the original review
    comment using the review comment endpoint and `in_reply_to`.
  - Implement fixes, commit, push.
  - Reply with the fix details and commit SHA in the same place you
    acknowledged the feedback.

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
