---
name: symphony-pr
description: |
  Publish the current branch as a pull request: push to origin, create or
  update the PR, write its body, and request code review. Use when the
  implementation is ready to open or refresh a PR for review.
---

# Publish PR

## Prerequisites

- `gh` CLI is installed and available in `PATH`.
- `gh auth status` succeeds for GitHub operations in this repo.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR against `upstream` if none exists for the branch, otherwise update
  the existing PR.
- Refuse to publish a PR branch diff that contains agent-only cleanup files
  such as `.symphony/workpad.md`; those files are persisted through Linear
  issue attachments instead.
- Request code review for the latest PR head per the project's reviewer
  configuration and handle review feedback before handoff.
- Preserve pending human reviewer requests. Never remove or replace a human
  reviewer request when adding automated review.
- Keep branch history clean when remote has moved.

## Reviewer configuration

The designated automated reviewer is the `AUTOMATED_REVIEWER` environment
variable. If it is non-empty, request review from that account after every PR
create/update with a code, test, or documentation diff. If it is empty, skip
the automated review request and proceed directly to human handoff.

## Related Skills

- `symphony-pull`: use this when push is rejected or sync is not clean
  (non-fast-forward, merge conflict risk, or stale branch).

## Steps

1. Identify current branch and confirm remote state.
2. Run scope-appropriate local validation from `AGENTS.md` before pushing.
3. Ensure agent state is recoverable and the PR branch is clean before pushing:
   - If `.symphony/workpad.md` exists, read its `cleanup` frontmatter list.
   - Confirm the latest cleanup paths have been uploaded as a
     `Symphony agent state` Linear issue attachment.
   - Keep those paths out of the PR branch index. If any cleanup path is
     already tracked on the PR branch, stop and remove it from the PR branch
     history or index before publishing; do not auto-delete the working copy.
   - Do not write review-request timestamps or timeout metadata back into
     `.symphony/workpad.md` after publishing; put those details in the
     Implementation artifact instead.
   - Verify `git diff --name-only upstream/${SYMPHONY_BASE_BRANCH:-main}...HEAD`
     does not list any cleanup path.
4. Push branch to `origin` with upstream tracking if needed, using whatever
   remote URL is already configured.
5. If push is not clean/rejected:
   - If the failure is a non-fast-forward or sync problem, run the `symphony-pull`
     skill to merge `upstream/${SYMPHONY_BASE_BRANCH:-main}`, resolve
     conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth, permissions, or workflow restrictions on
     the configured remote, stop and surface the exact error instead of
     rewriting remotes or switching protocols as a workaround.

6. Ensure a PR exists for the branch:
   - Create and update PRs in the `upstream` repository, with the branch pushed
     to the fork (`origin`) as the PR head.
   - If no PR exists, create one.
   - If a PR exists and is open, update it.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
   - Write a proper PR title that clearly describes the change outcome.
   - For branch updates, explicitly reconsider whether current PR title still
     matches the latest scope; update it if it no longer does.
7. Write/update PR body from `.github/pull_request_template.md` if the
   repository provides one:
   - Treat the template as the source of truth for required PR content.
   - Fill every section with concrete content for this change.
   - Replace all placeholder comments (`<!-- ... -->`).
   - Keep bullets/checkboxes where the template expects them.
   - If PR already exists, refresh body content so it reflects the total PR
     scope, not just the newest commits.
   - Do not reuse stale description text from earlier iterations.
8. Request code review per the project's reviewer configuration:
   - Request review after every PR create/update with a code, test, or
     documentation diff, unless no reviewer is configured.
   - Before requesting an automated reviewer, inspect existing PR review
     requests. If any pending reviewer is a human account, preserve the
     human review request, record that automated review was skipped to avoid
     disturbing the human reviewer, and proceed to human handoff.
   - Do not use `--remove-reviewer`, do not rewrite the requested-reviewer
     set, and do not treat replacing a human reviewer with an automated
     reviewer as acceptable.
   - Record the request timestamp and head SHA in the Implementation artifact
     notes, not in cleanup files that are kept out of the PR branch.
   - Wait up to 20 minutes for automated review feedback, polling about once
     per minute.
   - If the automated reviewer leaves actionable comments or requests
     changes, reply to each substantive feedback item in the same GitHub
     conversation with a `[codex]` response, implement fixes, rerun
     scope-appropriate validation, commit, push, update the PR body if scope
     changed, then reply again with the fix details and commit SHA when the
     initial reply did not already contain the final resolution. Request
     review again after code/test/docs changes.
   - If automated review does not arrive before the timeout, do not block
     forever and do not mark the review as passed. Record the timeout in the
     `## Implementation` artifact's `风险/注意`.
   - If automated review is skipped to preserve a pending human reviewer
     request, do not treat that as success or failure; record the preserved
     reviewer and continue to human PR review handoff.
9. Reply with the PR URL from `gh pr view --repo "$upstream_repo"`.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)

repo_slug_from_remote_url() {
  printf '%s\n' "$1" |
    sed -E \
      -e 's#^git@github.com:#https://github.com/#' \
      -e 's#^ssh://git@github.com/##' \
      -e 's#^https://github.com/##' \
      -e 's#\.git$##'
}

upstream_url=$(git remote get-url upstream)
origin_url=$(git remote get-url origin)
upstream_repo=$(repo_slug_from_remote_url "$upstream_url")
origin_repo=$(repo_slug_from_remote_url "$origin_url")
fork_owner=${origin_repo%%/*}
pr_head="$fork_owner:$branch"

# Scope-appropriate validation gates from AGENTS.md.
# Run the commands that match the files changed; record exactly what ran
# in the PR template.

# Keep cleanup files out of the PR.
# Prefer the cleanup list from .symphony/workpad.md when it exists.
if [ -f .symphony/workpad.md ]; then
  cleanup_paths=$(
    awk '
      BEGIN { in_yaml=0; in_cleanup=0 }
      NR == 1 && $0 == "---" { in_yaml=1; next }
      in_yaml && $0 == "---" { exit }
      in_yaml && /^cleanup:/ { in_cleanup=1; next }
      in_yaml && in_cleanup && /^  - / { sub(/^  - /, ""); print; next }
      in_yaml && in_cleanup && /^[^[:space:]]/ { in_cleanup=0 }
    ' .symphony/workpad.md
  )

  if [ -n "$cleanup_paths" ]; then
    tracked_cleanup=$(
      printf '%s\n' "$cleanup_paths" | while IFS= read -r cleanup_path; do
        [ -n "$cleanup_path" ] || continue
        git ls-files --error-unmatch "$cleanup_path" >/dev/null 2>&1 && printf '%s\n' "$cleanup_path"
      done
    )
    if [ -n "$tracked_cleanup" ]; then
      echo "Refusing to publish PR with cleanup files tracked on the PR branch:" >&2
      echo "$tracked_cleanup" >&2
      echo "Upload them as a Linear state attachment and remove them from the PR branch index/history before publishing." >&2
      exit 1
    fi

    staged_cleanup=$(
      printf '%s\n' "$cleanup_paths" | while IFS= read -r cleanup_path; do
        [ -n "$cleanup_path" ] || continue
        git diff --cached --name-only -- "$cleanup_path" | sed '/^$/d'
      done
    )
    if [ -n "$staged_cleanup" ]; then
      echo "Refusing to publish PR with cleanup files staged:" >&2
      echo "$staged_cleanup" >&2
      exit 1
    fi
  fi
fi

base_ref="upstream/${SYMPHONY_BASE_BRANCH:-main}"
if git rev-parse --verify "$base_ref" >/dev/null 2>&1 && [ -n "${cleanup_paths:-}" ]; then
  pr_files=$(git diff --name-only "$base_ref"...HEAD)
  cleanup_file=$(mktemp)
  pr_file=$(mktemp)
  printf '%s\n' "$cleanup_paths" | sort -u >"$cleanup_file"
  printf '%s\n' "$pr_files" | sort -u >"$pr_file"
  leaked_cleanup=$(
    comm -12 "$cleanup_file" "$pr_file"
  )
  rm -f "$cleanup_file" "$pr_file"
  if [ -n "$leaked_cleanup" ]; then
    echo "Refusing to publish PR with cleanup files in diff:" >&2
    echo "$leaked_cleanup" >&2
    exit 1
  fi
fi

# Initial push: push feature branches to the fork (`origin`).
git push -u origin HEAD

# If that failed because the remote moved, use the symphony-pull skill.
# After pull-skill resolution and re-validation, retry the normal push:
git push -u origin HEAD

# If the configured remote rejects the push for auth, permissions, or
# workflow restrictions, stop and surface the exact error.

# Only if history was rewritten locally:
git push --force-with-lease origin HEAD

if [ -z "$upstream_repo" ] || [ "$upstream_repo" = "$upstream_url" ]; then
  echo "Could not derive GitHub upstream repo from remote URL: $upstream_url" >&2
  exit 1
fi

if [ -z "$fork_owner" ] || [ "$fork_owner" = "$origin_repo" ]; then
  echo "Could not derive fork owner from origin remote URL: $origin_url" >&2
  exit 1
fi

# Ensure a PR exists in upstream (create only if missing)
pr_lookup=$(
  gh pr list --repo "$upstream_repo" --head "$branch" --state all \
    --json number,state,headRepositoryOwner \
    --jq "map(select(.headRepositoryOwner.login == \"$fork_owner\"))[0] // empty"
)
pr_number=$(printf '%s\n' "$pr_lookup" | jq -r '.number // ""')
pr_state=$(printf '%s\n' "$pr_lookup" | jq -r '.state // ""')
if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  echo "Current branch is tied to a closed PR; create a new branch + PR." >&2
  exit 1
fi

# Write a clear, human-friendly title that summarizes the shipped change.
pr_title="<clear PR title written for this change>"
tmp_pr_body=$(mktemp)
if [ -f .github/pull_request_template.md ]; then
  cp .github/pull_request_template.md "$tmp_pr_body"
fi
# Edit "$tmp_pr_body" so every template section is concrete for this PR
# and no placeholder comments remain.

if [ -z "$pr_state" ]; then
  pr_url=$(gh pr create --repo "$upstream_repo" --base "${SYMPHONY_BASE_BRANCH:-main}" \
    --head "$pr_head" --title "$pr_title" --body-file "$tmp_pr_body"
  )
  pr_number=$(gh pr view "$pr_url" --repo "$upstream_repo" --json number -q .number)
else
  # Reconsider title on every branch update; edit if scope shifted.
  gh pr edit "$pr_number" --repo "$upstream_repo" --title "$pr_title" \
    --body-file "$tmp_pr_body"
fi
rm -f "$tmp_pr_body"

pr_head_sha=$(gh pr view "$pr_number" --repo "$upstream_repo" --json headRefOid -q .headRefOid)
review_requested_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Request review from the project's configured automated reviewer.
# Check AGENTS.md or the workflow env for the reviewer account name.
# If no reviewer is configured, skip this block.
# If a human reviewer is already requested, preserve it and skip.
automated_reviewer="${AUTOMATED_REVIEWER:-}"

if [ -z "$automated_reviewer" ]; then
  echo "No automated reviewer configured; proceeding to human handoff." >&2
else
  human_reviewers=$(
    gh pr view "$pr_number" --repo "$upstream_repo" --json reviewRequests --jq \
      ".reviewRequests[] | (.login // .slug // .name // \"\") | select(. != \"\" and . != \"$automated_reviewer\" and (. | test(\"(\\\\[bot\\\\]|-bot)\$\") | not))" \
      2>/dev/null || true
  )

  if [ -n "$human_reviewers" ]; then
    echo "Pending human reviewer request(s) already exist; preserving them and skipping automated review request." >&2
    echo "$human_reviewers" >&2
    gh pr view "$pr_number" --repo "$upstream_repo" --json url -q .url
    exit 6
  fi

  review_request_error=$(mktemp)
  if ! gh pr edit "$pr_number" --repo "$upstream_repo" --add-reviewer "$automated_reviewer" 2>"$review_request_error"; then
    if gh pr view "$pr_number" --repo "$upstream_repo" --json reviewRequests --jq '.reviewRequests[].login' | grep -qx "$automated_reviewer"; then
      echo "Automated review was already requested"
    else
      cat "$review_request_error" >&2
      rm -f "$review_request_error"
      exit 1
    fi
  fi
  rm -f "$review_request_error"
fi

# Bounded review wait.
# Exit codes:
# - 0: review completed with no pending actionable feedback
# - 2: actionable feedback detected; address it, push fixes, and rerun this skill
# - 6: no automated approval (timeout or preserved human reviewer); continue to
#      human PR review handoff and record the reason
# Implement or adapt a polling loop appropriate to the project's CI setup.

# Show PR URL for the reply
gh pr view "$pr_number" --repo "$upstream_repo" --json url -q .url
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as the last resort.
- Distinguish sync problems from remote auth/permission problems:
  - Use the `symphony-pull` skill for non-fast-forward or stale-branch issues.
  - Surface auth, permissions, or workflow restrictions directly instead of
    changing remotes or protocols.
- Reviewer timeout and "preserve pending human reviewer" exits use status 6.
  This is a bounded fallback to human PR review, not success, so Symphony
  can stop waiting without losing the review signal or disturbing human
  reviewers.
