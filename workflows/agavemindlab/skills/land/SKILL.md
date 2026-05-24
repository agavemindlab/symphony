---
name: land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  post-merge verification runs; use when asked to land, merge, or shepherd
  a PR to completion.
---

# Land

## Goals

- Ensure the PR is conflict-free with `upstream/${SYMPHONY_BASE_BRANCH:-main}`.
- Keep PR CI and post-merge verification runs green.
- Use the latest `## Review Handoff` merge safety assessment and post-merge
  verification plan as the Merging gate.
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
2. Read the latest Linear `## Review Handoff` or human approval comment before
   merging. Confirm it approves Merging and that the latest PR-review handoff
   includes:
   - A merge-safety assessment: whether the PR is safe to merge and whether
     any remaining issue could crash services, corrupt/lose data, break
     background jobs, or only affect a bounded path.
   - A post-merge verification plan: the exact checks to run after merge.
   If either element is missing, do not merge; update the handoff and return
   the issue to `Human Review`.
3. Confirm the relevant `AGENTS.md` validation is green locally before any push.
4. If the working tree has uncommitted changes, commit with the `commit` skill
   and push with the `push` skill before proceeding.
5. Check mergeability and conflicts against
   `upstream/${SYMPHONY_BASE_BRANCH:-main}`.
6. If conflicts exist, use the `pull` skill to fetch/merge the upstream base
   and resolve conflicts, then use the `push` skill to publish the updated branch.
7. Ensure any automated review comments (if present) are acknowledged and any
   required fixes are handled before merging.
8. Watch checks until complete, or until the bounded watcher reports that no PR
   checks were configured/triggered for this branch.
9. If checks fail, pull logs, fix the issue, commit with the `commit` skill,
   push with the `push` skill, and re-run checks.
10. When all checks are green (or no checks appear after the bounded no-check
    wait) and review feedback is addressed, squash-merge using the PR
    title/body for the merge subject/body.
11. Immediately capture the merge commit SHA and watch `main` workflow runs for
    that SHA. Follow the project's deployment trigger paths documented in
    `AGENTS.md` to determine which workflows may run after a merge to `main`.
12. Execute the post-merge verification plan from the latest handoff. Record
    concrete evidence in the workpad: workflow/deploy run URLs or SHAs, service
    health signals, smoke-test request/response, logs/error dashboard signal,
    worker/job result, or data-safe read-only verification.
13. If a post-merge run fails, is cancelled, times out, or does not appear when
    expected, inspect the run logs and report the deployment risk immediately.
14. If any planned post-merge verification fails or cannot be run, keep the issue
    out of `Done`, record the failed signal, and report the risk immediately.
15. Automatically rollback only when the rollback guardrails below prove it is
    data-safe; otherwise stop and ask for human direction.
16. **Context guard:** Before implementing review feedback, confirm it does not
    conflict with the user's stated intent or task context. If it conflicts,
    respond inline with a justification and ask the user before changing code.
17. **Pushback template:** When disagreeing, reply inline with: acknowledge +
    rationale + offer alternative.
18. **Ambiguity gate:** When ambiguity blocks progress, use the clarification
    flow (assign PR to current GH user, mention them, wait for response). Do not
    implement until ambiguity is resolved.
    - If you are confident you know better than the reviewer, you may proceed
      without asking the user, but reply inline with your rationale.
19. **Per-comment mode:** For each review comment, choose one of: accept,
    clarify, or push back. Reply inline stating the mode before changing code.
20. **Reply before change:** Always respond with intended action before pushing
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
  # Run the `pull` skill to handle fetch + merge + conflict resolution.
  # Then run the `push` skill to publish the updated branch.
  :
fi

# Watch review feedback, PR checks, mergeability, and PR head updates.
# Implement a polling loop appropriate to the project's CI setup, or
# use the project's land watcher script if one exists under .agents/skills/land/.
python3 .agents/skills/land/scripts/land_watch.py 2>/dev/null || \
  echo "No land_watch.py found; poll manually with: gh pr checks && gh pr view --json reviews" >&2

# Squash-merge
gh pr merge --squash --subject "$pr_title" --body "$pr_body"

# Watch post-merge main workflow runs for the merge commit.
# Use gh run list --branch main --commit <sha> --event push
# or the project's post-merge watcher script if one exists.
```

## Async Watch Helper

If the project provides an asyncio watcher script at
`.agents/skills/land/scripts/land_watch.py`, prefer it to monitor review
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
  fix locally, commit with the `commit` skill, push with the `push` skill, and
  re-run the watch.
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
```

---

Now for the WORKFLOW.md additions. Below I identify the exact insertion location for each new section and provide the draft content.

---

```
=== WORKFLOW.md ADDITIONS ===
```

**1. New section: `## Skill interaction protocol (unattended bridge)`**

Insert after the `## Related Skills` section and before `## Discovery and Planning Gates`.

```markdown
## Skill interaction protocol (unattended bridge)

This workflow runs the agent unattended via `codex app-server`. There is no
interactive UI: tools like `AskUserQuestion` are not reachable, and the only
channel back to the human is the Linear issue (`## Spec` / `## Codex Workpad`
/ `## Review Handoff` comments).

Many optional skills (discovery tools, engineering-review tools,
planning skills) assume interactive operation. When **any** invoked skill
needs to ask the human a question (directly via `AskUserQuestion`, indirectly
via "wait for user confirmation" prose, or by stalling on ambiguity), bridge
it to Linear instead of dropping the question, outputting it to chat, or
auto-deciding silently.

This protocol is the canonical bridge for **every** invoked skill in this
session. It supersedes any per-skill "AskUserQuestion fallback" or "output
prose to chat" instruction. When a phase skill references the "Skill
interaction protocol", "Non-interactive human question protocol", or
"bridge", it points here.

### Bridge rules

1. **Collect, don't sequentially ask.** Capture every question the skill
   (or the agent itself) would have asked the human across the entire active
   gate. Do not stop and ask one at a time. Do not output a prose question
   to the chat hoping a human will see it — they won't.
2. **Consider all branches per question.** For each question, write 2-4
   concrete options the agent considered, why the question matters, and what
   the agent will do if the human accepts the recommendation.
3. **Recommend with reason.** Mark one option as `推荐 (recommended)` with a
   one-sentence rationale. The recommendation is the agent's judgment under
   current evidence — make it concrete, not a hedge.
4. **Mark in the persistent artifact.**
   - For ambiguity in `要解决的问题` / `为什么解决` / `验收标准` — write
     `[NEEDS CLARIFICATION: <question>]` inline in the `## Spec` comment at
     the relevant field.
   - For ambiguity in `解决方案（approach）` / `风险/注意` — write
     `[NEEDS CLARIFICATION: <question>]` inline in the `## Spec` comment at
     the relevant field.
   - For execution / runtime / tooling ambiguity that the Spec cannot capture
     — write a brief blocker note in the `## Codex Workpad` `Notes` section.
5. **Batch into one Review Handoff** matching the active gate (status enum →
   owning skill mapping in `Review handoff lifecycle`):
   - Gate 1 questions → `Status: Waiting for requirement confirmation`
     (sub-template in `phase-clarification`).
   - Gate 2 questions → `Status: Waiting for plan confirmation` (sub-template
     in `phase-design`).
   - Gate 3 execution blocker → `Status: Blocked` (sub-template in
     `phase-implementation`).
   The handoff's `阻塞决策` (or `阻塞`) section must contain a 1:1 reflection
   of every unresolved Spec marker / Workpad blocker note: same question text,
   options considered, recommended option, and what the agent will do if the
   recommendation is accepted.
6. **Cap at five.** If there are more than five blocking questions for one
   human round, propose a narrowed scope or split the issue rather than
   sending an oversized questionnaire — five distinct uncertainties is a
   signal the design isn't ready.
7. **Move issue to `Human Review`** with the chosen status. Do not continue
   work past the gate while markers are unresolved.
8. **On resume**, the agent's first edit replaces each resolved marker in the
   Spec / Workpad with the answered value (or `Brief 假设: <value>` if the
   agent took its recommendation), then re-syncs Workpad `Acceptance Criteria`
   if affected, then continues from the gate that was paused.

### What this means for invoked optional skills

- Discovery tool (e.g., `office-hours` equivalent): if it walks through
  questions interactively, bridge them instead — agent records each
  question's answer-options as it would have asked, then batches all
  unresolved ones into one Spec markers + `Waiting for requirement
  confirmation` handoff at Gate 1 exit.
- Engineering-review tool (e.g., `plan-eng-review` equivalent): if it calls
  `AskUserQuestion` per finding, bridge them instead — agent collects all
  findings the human must approve, batches into Spec `approach` / `风险/注意`
  markers + `Waiting for plan confirmation` handoff at Gate 2 exit. Findings
  the agent can resolve unilaterally (per WORKFLOW.md `Discovery and planning
  gates` Gate 2 high-impact category list) are recorded in the workpad and
  resolved without bouncing.
- Any other optional skill: same bridge. If the skill wants to ask the human,
  the agent batches and posts; otherwise the agent decides and records the
  decision (and rationale) in the workpad.
```

---

**2. Three-comment model and priority hierarchy — insert inside `## Default Posture`**

Find the existing paragraph in `## Default Posture` that starts with:
> "Treat the persistent `## Codex Workpad` comment as the agent continuation record."

Insert the following block **after** that paragraph (before "Treat `## Review Handoff` comments..."):

```markdown
- The three persistent comments have non-overlapping ownership: **Spec** owns
  the issue-level contract (what to solve, why, chosen approach, observable
  acceptance signals); **Workpad** owns execution state (plan, validation,
  attempt history, notes); **Handoff** owns per-round routing and human
  action. When the Linear description, Spec, Workpad, or human comments
  disagree, the precedence is:
  **human comment > Spec > Workpad > original Linear description**.
  Reconcile by updating the Spec to absorb the human comment's intent, then
  sync the Workpad, then write code.
- Investigation code (reproductions, temporary logging, ad-hoc scripts to
  characterize a bug or measure a baseline) is allowed before the Spec is
  finalized. Product implementation code (changes that will land in the PR
  diff) must wait until the Spec is complete with no unresolved
  `[NEEDS CLARIFICATION: ...]` markers.
```

---

**3. Subagent authorization — insert as item 4 in the `Instructions:` numbered list**

The existing `Instructions:` list in the WORKFLOW.md front matter ends at item 3. Add:

```markdown
4. **Subagent use is explicitly authorized when available.** This workflow
   invokes `subagent-driven-development` (superpowers) at Gate 3 when the
   skill is present and the approved plan contains independent subtasks that
   can be safely delegated. Invoking this workflow constitutes explicit
   authorization to dispatch subagents for those tasks. Do not wait for
   additional user confirmation before using subagents during implementation.
```

---

**4. Completion bar additions — add to `## Step 2: Implementation Phase` completion bar (item 10)**

In the current Step 2 completion bar (the checklist under item 10), add the following items after the existing "All required validation from `AGENTS.md` is passing" check:

```markdown
    - [ ] A `## Spec` comment exists, contains `Primary: Type:<...>`, has no
          unresolved `[NEEDS CLARIFICATION]` markers, and uses stable `S<N>`
          IDs on every `验收标准` entry. The Workpad `Acceptance Criteria`
          mirrors each `S<N>` (rather than restating text).
    - [ ] The Spec passes the type-specific quality gate from
          `phase-clarification` (the `要解决的问题` / `为什么解决` /
          `验收标准` side) and `phase-design` (the `解决方案（approach）`
          side) for the Spec's `Primary:` type. Re-read both skills'
          "Type-specific writing emphasis" sections matching the Spec type
          and verify each emphasis bullet is satisfied. If any bullet fails,
          the Spec must be revised before transitioning to `Human Review`.
    - [ ] If the Spec uses the `Trivial Spec` compact form, the changes in the
          PR diff contain no behavior/data/security/API/migration/performance
          impact; if any of those impact categories are detected, escalate to
          the full Spec template before handoff.
    - [ ] If the Spec's `关键假设` contains `本地验收不可达：<原因>` (a
          production-only-repro issue), the following substitution gates apply
          instead of standard local runtime acceptance:
          - The Workpad `Acceptance Criteria` includes characterization tests
            covering each key invariant of the fix path (one entry per
            invariant; grep the fix-touching functions and confirm each has a
            corresponding test).
          - The handoff's `Merge 后验证` section is required (not optional).
            Every entry names a specific metric ID, dashboard URL, or alert
            name plus an explicit observation time window. Generic "observe
            the alert clears" without a concrete signal target fails the gate.
          - The handoff's TL;DR or rollback statement names the rollback path
            concretely (feature flag toggle, image revert, replica rollback,
            etc.), not just "revert PR if it goes wrong".
          - The handoff explicitly states `本地验収不可达：<原因>` (in the
            TL;DR or in the `已验証` section if used) rather than omitting
            the local-acceptance evidence.
