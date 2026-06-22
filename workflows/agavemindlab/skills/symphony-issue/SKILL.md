---
name: symphony-issue
description:
  Spin off a new Linear issue discovered mid-execution (follow-up, related,
  blocking, blocked, or sub-issue) under the Symphony unattended policy.
  Autonomously creates low-risk capture issues; proposes flow-changing ones
  for human consent. Uses symphony-linear for the raw GraphQL.
---

# Spawn a Linear issue

Use this when, while working an issue, you find work that belongs in its
**own** Linear ticket. Two entry modes:

- **spawn** — you just discovered the need; classify it and either create or
  propose it.
- **fulfill** — Main Flow detected a human consent reply on an earlier
  proposal comment; create the proposed issue now.

## Scope boundary (read first)

The current issue's task breakdown stays in the **workpad Plan**
(hierarchical checklist, same PR). Only work that needs an **independent
ticket** goes through this skill. Do not file a Linear issue for a checklist
item.

## Kinds and tiers

Classify the discovery into one kind. The kind fixes both the tier and the
Linear relation.

| Kind | Meaning | Relation | Tier |
|------|---------|----------|------|
| follow-up | out-of-scope work to do later | `related` | **A — autonomous** |
| related | loosely related, no dependency | `related` | **A — autonomous** |
| downstream blocked | current `blocks` the new issue | `blocks` (current→new) | **A — autonomous** |
| blocking | current `blocked-by` the new issue | propose only | **B — consent-gated** |
| sub-issue | decompose current into children | `parentId` | **B — consent-gated** |

Also assign a type label: `Bug | Feature | Refactor | Performance | Migration | Chore | Spike | Other`.

## Execution domain routing

Before dedup or creation, classify the discovery against the WORKFLOW
"Canonical project routing registry". Route by the work's execution domain, not
by where it was discovered:

- Use the current issue's project only when the discovery belongs to that same
  execution domain.
- Route operational infrastructure work to `gl-infra`: clusters/namespaces,
  DB/Redis/PVC/storage, secrets, NetworkPolicy, RBAC, GitHub protected
  environments, operator profiles, runtime accounts, reset/seed, and
  feature-flag allowlists.
- If a discovery spans multiple domains, split it into one spawned issue per
  domain. Pick the kind/relation for each split by the real dependency; e.g.
  repo-side staging gate work stays in `grotto`, while `grotto-staging`
  operational prerequisites route to `gl-infra`.
- If the target project is unclear, create/propose nothing. Add a
  `[NEEDS CLARIFICATION: which Linear project should own <work>?]` marker in
  the current phase artifact with the candidate routes and stop per that phase's
  blocked path.

## Safety invariants (every spawned issue)

1. **State = the team's intake state, resolved by `type` (never by name).**
   Pick `type: "triage"` if the team has one, else `type: "backlog"` (see
   symphony-linear "Spawn a Linear issue"). A spawned issue lands outside
   `active_states`, so Symphony never auto-works it.
2. **`assignee` = the current issue's `creator`.** Never assign a spawned
   issue to Symphony's own account.
3. **`team` = current issue's team; `project` = the routed execution-domain
   project.** Resolve the target project's `projectId` and pass it to
   `issueCreate`; omit `projectId` only when the current issue has no project
   and the registry also says there is no project route.
4. **Idempotency.** The workpad `## Spawned Issues` section records every item
   created or proposed on this branch; never recreate a recorded item.
5. **Persist-before-proceed.** After a successful `issueCreate`, immediately
   record the new id in the workpad, then upload a fresh `Symphony agent state`
   Linear issue attachment per the WORKFLOW Persistence section before doing
   anything else. Do not stage the workpad into the PR branch.

## Tier A — autonomous create

1. **Dedup, two layers:**
   - *Hard:* skip anything already in workpad `## Spawned Issues`.
   - *Soft (best-effort):* search the target project, non-terminal states, by
     title keywords. On a clear same-work hit → do **not** duplicate; add the
     relation to the existing issue and note `→ ENG-123` in the artifact. When
     unsure → create (bias to capture) and append `（可能与 ENG-123 重复，待 triage
     合并）` to the description. Never block: on search failure/timeout, create.
2. **Create** (`issueCreate`): `stateId` = intake state, `assigneeId` =
   creator, `teamId` = current issue's team, `projectId` = routed target
   project's id, `labelIds` = the matching
   `Type:Xxx` label. Chinese `title` / `description` (Linear is human-facing).
   Description skeleton:

   ```md
   **来源**: 由 symphony 处理 <当前 issue 的 identifier，如 ENG-123，裸写让 Linear 渲染引用> 时发现
   **执行域 / project**: <execution domain> / <Linear project>
   **背景（why）**: <发现了什么、为什么该独立成一个 issue>
   **建议范围（what）**: <大致要做什么>
   ```

3. **Link** (`issueRelationCreate`): `related` for follow-up/related;
   current `blocks` new for downstream blocked.
4. **Record + persist**: write the new issue's identifier into workpad `## Spawned Issues`
   (status `已创建`), then upload a fresh state attachment (invariant 5).
5. **Surface**: return the new issue's identifier to the calling phase, which lists it in its
   artifact (Design 未覆盖范围 / Implementation 风险 / Deployment 后续事项).

**Failure handling:** `issueCreate` ok but `issueRelationCreate` fails → do
**not** roll back; note `关系未设成，请人工补` in the artifact. Creation itself
fails in a non-blocking context → record in workpad notes, downgrade the item
to a `建议新建` list entry, never stall the main flow.

## Tier B — propose, then create on consent

Create **nothing** yet. Post the proposal as its **own top-level comment**
(not inside the phase artifact) — one comment per proposal — so its reply
thread is a dedicated consent channel:

```md
## 建议新建 issue：<建议标题>
- **类型**: blocking / sub-issue
- **类型标签**: Type:Xxx
- **执行域 / project**: <execution domain> / <Linear project>
- **关系**: 阻塞当前 issue（裸 identifier，如 ENG-123）/ 当前 issue 的子任务
- **理由**: <为什么需要、为什么不能并进当前 issue>

> 👉 回复本条评论「同意 / 建吧」即由 symphony 代建；回复「不用了」则放弃。
```

Record it in workpad `## Spawned Issues` as `待同意` with the proposal comment
id. Why a separate comment: consent and phase-approval are both human replies;
only a separate comment lets reply-position disambiguate them (a reply in the
**proposal** thread = consent; a reply in the **artifact** thread = phase
intent).

Flow impact by kind:

- **blocking** — a true blocker. Also write a callout on the current phase
  artifact and stop:
  ```md
  > 🚧 **被阻塞**：<one sentence>。需先创建并完成上述前置 issue。
  ```
  Move the issue to `Human Review` and stop (no `Blocked` state exists). This
  is a **hard stop**, like a phase's "When blocked" path: it short-circuits
  the phase skill's normal advance/stop handback to Main Flow. Even after the
  blocker is created on consent, the current issue stays `blocked-by` it and
  remains in `Human Review` — creation ≠ unblocking.
- **sub-issue** — a proposal, **not** blocking. Finish the current phase
  artifact normally and attach the proposal comment. (If you genuinely cannot
  continue without the split, it is really a blocker — take the blocking
  path.)

## Fulfill mode (on human consent)

Main Flow scans unresolved `## 建议新建 issue` comments for a new reply, then
interprets the reply's **intent** (not a fixed keyword list):

- **Consent** (e.g. `同意 / 建吧 / 可以 / 👍`) → create the recorded item with
  the Tier A create/link/record/persist steps (intake state, assignee =
  creator, relation or `parentId`), reply `已创建 ENG-123` in the proposal thread,
  resolve the proposal comment, flip the workpad entry `待同意 → 已创建`.
- **Rejection** (e.g. `不用了 / 先不建`) → resolve the proposal comment, flip
  to `已放弃`; never re-propose.
- **Unclear** → treat as ordinary discussion; create nothing.

A human may also hand-create the issue instead; if you see it already exists,
record it and move on. Both paths coexist.

## Workpad `## Spawned Issues`

```md
## Spawned Issues
- 已创建 ENG-123 — <title> · related/blocks/parent · <one-line why>
- 待同意 <proposal-comment-id> — <title> · blocking/sub-issue
- 已放弃 <proposal-comment-id> — <title> · <reason>
```

## Worked examples

- **independent follow-up during Implementation** → `related` issue created in
  the intake state, assignee = creator, listed in the `## Implementation`
  artifact; workpad `已创建 ENG-123`.
- **implementation ticket that depends on the current artifact** → `downstream
  blocked`, linked as current `blocks` new.
- **repo gate plus operational prerequisites** → split into `grotto` repo-side
  work and `gl-infra` operational work, as in DEV-5236/DEV-5324; link them by
  the dependency that actually blocks execution.
- **blocking dependency found** → proposal comment + blocker callout on the
  artifact + `Human Review`; nothing created until consent.
- **consent reply in a proposal thread** → issue created, `已创建 ENG-123`
  replied, proposal comment resolved, workpad `待同意 → 已创建`.
- **rejection reply** → proposal comment resolved, workpad `已放弃`.
- **resume with the item already recorded** → skipped, not recreated.
- **soft-search hit** → no duplicate; relation added to the existing issue,
  `→ ENG-123` noted in the artifact.
