---
name: phase-implementation
description:
  Run Gate 3 (implementation plan and execution) of the Symphony workflow.
  Turn a locked Spec into working code, tests, and a PR ready for human
  review. Use after Gate 1 + Gate 2 exit (Spec complete with no
  `[NEEDS CLARIFICATION]` markers; approach + diagram filled). Owns the
  Workpad format, the PR feedback sweep, the `Waiting for PR review`
  handoff (the most-touched handoff in the workflow), and the `Blocked`
  handoff for external blockers.
---

# Phase 3: Implementation Plan and Execution

## Goal

Produce working code + tests + a PR that the reviewer can pass / 打回 /
提问 in 30 seconds based on a fresh `Waiting for PR review` handoff. To
get there, this phase manages the persistent `## Codex Workpad` comment
(Plan / Acceptance / Validation / Notes), the PR feedback sweep loop,
and the writing of the `Waiting for PR review` (or `Blocked`) handoff at
the end.

## Inputs (from Gate 2 exit)

- `## Spec` is current: `Primary:` set, `要解决的问题` / `为什么解决` /
  `验收标准` / `解决方案（approach）` all filled, every `S<N>` satisfies
  the 5 rules, no `[NEEDS CLARIFICATION:...]` markers.
- For non-trivial designs, the approach has a diagram inline.

If any of the above is missing, return to Gate 1 (`phase-clarification`)
or Gate 2 (`phase-design`) to fix it; do not paper over with workpad
notes.

## Default skills to invoke

- `writing-plans` (superpowers, if available) — produce the hierarchical
  Plan that goes into the Workpad. If unavailable, construct the plan
  manually in the Workpad using the same hierarchical checklist format.
- `subagent-driven-development` (superpowers, if available and tasks are
  parallelizable) — delegate plan items to subagents instead of doing all
  the work in the main session. Use when independent subtasks exist that
  can be safely dispatched in parallel. Critical for prompt economy on
  large plans.
- `test-driven-development` (superpowers, if available) — for any new
  behavior, write the failing test first. If unavailable, follow the
  red-green-refactor discipline manually.
- `commit` (.agents/skills) — produce clean, logical commits.
- `push` (.agents/skills) — push to `origin`, publish PR, request a
  code review per the project's reviewer configuration while preserving
  active human reviewer requests.
- `pull` (.agents/skills) — keep the branch current with
  `upstream/${SYMPHONY_BASE_BRANCH:-main}` before handoff.
- `verification-before-completion` (superpowers, if available) — gate
  before claiming the work is done.

If any of the above is skipped, record `Skipped <skill>: <reason>` in
workpad `Notes` per WORKFLOW.md `Related skills`.

## Output: `## Codex Workpad` comment

The Workpad is for **the next agent's continuation**, not for the human
reviewer. Keep `Plan`, `Acceptance Criteria`, `Validation`, and `Notes`
accurate so a fresh agent can resume without losing state. Keep the
current attempt near the top; move old attempts to `Previous Attempts`
only when preserving prior attempts is useful.

### Template

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Current Attempt

#### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

#### Acceptance Criteria

Mirror every Spec `S<N>` as an executable checkbox (do not restate text); add execution items below.

- [ ] S1: <executable check that proves Spec S1 is met>
- [ ] S2: <executable check that proves Spec S2 is met>
- [ ] lint passes
- [ ] targeted tests pass
- [ ] local runtime acceptance complete (when app-touching)
- [ ] PR feedback addressed and replies posted

#### Validation

- [ ] targeted tests: `<command>`

#### Notes

- <short progress note with timestamp>
- `Skills invoked: <comma-separated names>` — append on first visit and as more skills run; one running line, not per-event.
- `Skipped <skill>: <reason>` — one line per skip; required when a default skill at any gate was bypassed.

#### Confusions

- <only include this subsection when something was confusing during execution>

### Previous Attempts

- <only include when preserving prior attempts>
````

### Workpad rules

- Environment stamp at the top is required (`<host>:<abs-workdir>@<short-sha>`).
- Do not include the PR URL in the workpad; PR linkage lives on the
  issue via attachment / link fields.
- `Acceptance Criteria` mirrors every Spec `S<N>` with executable
  checks plus execution items (lint / targeted tests / local acceptance
  / PR feedback). Do not restate the Spec criterion text.
- `## Codex Workpad` is one persistent comment ID per issue. Update in
  place; never create a duplicate. Preserve the comment ID across
  attempts and full resets.

## Implementation flow

1. **Plan** — invoke `writing-plans` (or construct manually) to produce
   the hierarchical Plan; write it to the Workpad. Acceptance Criteria
   mirrors Spec `S<N>`.
2. **Delegate** — if `subagent-driven-development` is available and the
   plan contains independent subtasks, invoke it to dispatch plan items
   to subagents. Avoid doing implementation in the main session when
   subagents can parallelize independent tasks and protect main context.
3. **Implement with TDD** — for any new behavior, follow
   `test-driven-development` (or the red-green-refactor discipline
   manually): red test → minimal code → green → refactor.
4. **Commit** — invoke `commit` skill for each logical change. One
   coherent change per commit.
5. **Push** — invoke `push` skill to publish to `origin` and request
   code review per the project's reviewer configuration. Preserve any
   active human reviewer requests.
6. **Local runtime acceptance** — for any app-behavior change, start
   the development environment per `AGENTS.md` and exercise the feature
   against the running service before considering implementation complete.
   If local acceptance is impossible because required secrets / external
   services / hardware / data / permissions are unavailable, do not
   silently downgrade to unit tests: record what was attempted, why it
   is blocked, the closest safe alternative proof, and surface the
   caveat in the handoff `风险/注意`. Use the `Status: Blocked`
   sub-template if the missing local acceptance prevents confident review.
7. **Verify** — invoke `verification-before-completion` (if available).
   No completion claims without fresh verification evidence.
8. **PR feedback sweep** — see protocol below.
9. **Handoff** — write `Waiting for PR review` (or `Blocked`)
   sub-template; move issue to `Human Review`.

## PR feedback sweep protocol (required)

When the issue has an attached PR, run this loop before moving to
`Human Review`:

1. Identify the PR number from issue links / attachments.
2. Ensure a code review has been requested for the latest pushed PR
   head per the project's reviewer configuration:
   - The `push` skill owns the concrete review request and bounded wait
     commands; use it after every PR creation/update.
   - Do not request or re-request automated review if there is already
     a pending human reviewer request for the current handoff and no
     new code/test/docs changes were pushed in this run. Human review
     in progress takes precedence.
   - Never remove, replace, or overwrite pending human reviewer
     requests when requesting automated review. If adding an automated
     reviewer would disturb a human reviewer request, skip the
     automated request and call out the reason in the workpad and
     handoff.
   - Record the review request time, PR head SHA, and result in the
     workpad `Validation` or `Notes`.
   - If automated review times out without feedback, do not treat the
     PR as approved. Record the timeout evidence in the workpad,
     keep the PR linked, and make the handoff status
     `Waiting for PR review` with `风险/注意` calling out that
     automated review did not arrive.
3. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries / states (`gh pr view --json reviews`).
4. Treat every substantive reviewer comment (human, automated,
   top-level, review summary, inline) as **requiring a same-thread
   reply** in GitHub:
   - If addressed with code/test/docs: reply after the fix with what
     changed, where, and the relevant commit SHA.
   - If correct but deferred / split: reply with the deferral reason
     and linked follow-up issue.
   - If not applied: reply with explicit technical pushback.
   - For inline review comments: reply inline; do not replace with a
     top-level PR comment.
   - Ignore only automated status / check comments that contain no
     review feedback.
   - Do not consider a feedback item resolved merely because code
     changed; it is resolved only after the reviewer-facing reply is
     posted.
5. Update the workpad `Plan` / `Acceptance Criteria` to include each
   feedback item, its code resolution status, and the URL or thread
   identity of the posted reply.
6. Re-run validation after feedback-driven changes and push updates.
7. After pushing feedback fixes, request code review again for the new
   PR head unless the only change was an explicit pushback / comment
   response with no code, test, or doc diff, or a human reviewer
   request is already pending and should not be disturbed.
8. Repeat until no outstanding actionable comments remain and either:
   - every substantive reviewer comment has a same-thread reply,
   - automated feedback has been addressed, or
   - the bounded wait timed out and the timeout is explicitly handed
     off for human PR review.

### `receiving-code-review` discipline

When responding to feedback, if `superpowers:receiving-code-review` is
available follow it: verify before implementing, ask before assuming,
technical correctness over social comfort. Forbidden phrases include
"You're absolutely right" and "Great point". Restate the technical
requirement, then act.

## Blocked-access escape hatch

Use only when completion is blocked by missing required tools or
auth/permissions that cannot be resolved in-session.

- The project's code hosting service is **not** a valid blocker by
  default. Always try fallback strategies first (alternate remote / auth
  mode, then continue publish/review flow).
- Do not move to `Human Review` for code hosting access/auth until all
  fallback strategies have been attempted and documented in the workpad.
- If a non-hosting required tool is missing, or required non-hosting
  auth is unavailable, write a blocker brief in the workpad covering:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Reflect the brief in the `Status: Blocked` handoff sub-template
  below before moving to `Human Review`.

## Handoff at exit

Lifecycle invariants (marker, status enum, fresh-comment-per-transition,
shared writing rules) live in WORKFLOW.md `Review handoff lifecycle`.
Use the matching sub-template below.

### Sub-template: `Status: Waiting for PR review`

This is the most-touched handoff in the workflow. Get it right.

Required elements: status line, link metadata line, TL;DR prose (3-5
sentences, no `-` bullets, paragraph breaks allowed), `Human action
needed`. All H3 sections are optional and default to omitted.

````md
## Review Handoff

**Status**: Waiting for PR review
[Spec](URL) · [PR #NNNN](URL) `<short-sha>` · [CI green|red](URL) · <automated review approved | automated review 未响应 | 未请求：<原因>>

<TL;DR：3-5 句中文 prose，不带 label / 粗体 / H3 / `-` bullet。可用空行拆 1-2 段以改善扫读，但保持每段是连贯叙述、不要回到逐点形式。
作为连贯叙述回答：解决了什么问题；选定方案是什么；为什么改是对的（含 headline 数字 inline，或具体可验证证据）；
是否仍有 reviewer 应该知道的不放心点；建议下一步。
读完 reviewer 应能 30 秒内决定 merge / 打回 / 提问。>

### 已回应（仅当上一轮 reviewer 提了具体问题/质疑/要求证据；否则整段省略）
- <问题摘要> → <答案> → [证据/commit/test](URL)

### 看哪里（仅当 diff 中有不读代码看不出的微妙点；机械改动如新增 test、import 调整、rename 不写；否则整段省略）
- [`path/file` L120-L145](URL) — <一句：这段做了什么 + 为什么需要 reviewer 注意>

### 已验证（仅当验证方式有非常规之处：本地不可达、production-only、特殊 evaluation suite。普通 tests+CI 绿在 TL;DR 中说"CI 全过"即可；否则整段省略）
- <一行：执行了什么 + 观察到的可验证结果>

### Merge 后验证（仅当 Spec `S<N>` 中有真正需要 post-merge 观察、且未被自动化/本地覆盖的项；不要为了凑足某个最小项数新造 `S<N>`；否则整段省略）
- S<N>: <metric ID / dashboard URL / alert name + 观察窗口>

### 风险（仅当有真实未消除的 trade-off / 刻意未覆盖范围；resolved env 问题、PR-unrelated infra caveat 不写；否则整段省略）
- <一句>

**Human action needed**: <一句中文，动词开头；不重复顶部已有的 PR 链接 / Spec 链接 / 状态>
````

#### Anti-patterns specific to `Waiting for PR review`

- **Don't fill optional sections to look thorough.** A handoff with
  only TL;DR + `Human action needed` is normal and correct when no
  other section would change reviewer judgment.
- **Don't put the headline result outside TL;DR.** Evaluation counts,
  error rates, or key metrics must be in the prose paragraph, not
  buried in `已验证`.
- **Don't pad `看哪里` with mechanical files** (test fixtures, import
  reorderings, renames). Zero bullets is acceptable; the section
  disappears entirely.
- **Don't invent post-merge metrics to fill `Merge 后验证`.** If every
  Spec `S<N>` is already covered by automation/local acceptance, the
  section is fully omitted. Exception: production-only-repro issues
  must include real post-merge entries (see WORKFLOW.md `Completion
  bar before Human Review`).
- **Don't restate Spec content in TL;DR.** TL;DR carries this round's
  incremental story (especially for multi-PR iterations); the Spec
  link tells the long story.
- **Don't write reviewer-as-instructor commentary** ("reviewer 应确
  认 X" / "请关注 X 模块"). Use engineer voice instead.

### Sub-template: `Status: Blocked`

````md
## Review Handoff

**Status**: Blocked

### 阻塞
- **现象**: <一句>
- **影响**: <为什么这阻塞了完成；缺哪个验收/验证不能补>
- **已尝试**: <列表，每条一句 + 链接证据>
- **精确 unblock action**: <一句具体动作请求>

**Human action needed**: <一句>
````

## Exit conditions

This phase exits when **all** of:

- Workpad `Plan` and `Acceptance Criteria` (mirroring Spec `S<N>`)
  are complete; every checkbox the agent owns is checked.
- For app-behavior changes, local runtime acceptance has been run per
  `AGENTS.md` and produced concrete evidence (screenshots, logs,
  reproduction). If unreachable, the substitution path
  (characterization tests + `本地验收不可达` declaration) is in
  place per Spec / WORKFLOW.md `Completion bar before Human Review`.
- Validation/tests are green for the latest commit.
- PR is pushed; PR checks are green; PR is linked on the issue.
- PR feedback sweep is complete: every substantive reviewer comment
  has a same-thread reply, automated review either approved or
  documented as timed out.
- A fresh `Waiting for PR review` (or `Blocked`) handoff has been
  posted; issue is moved to `Human Review`.

The next agent (post-approval) runs Gate 4 (`phase-merge-and-confirm`).
