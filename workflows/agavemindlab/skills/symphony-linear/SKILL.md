---
name: symphony-linear
description: |
  Use Symphony's `linear_graphql` client tool for raw Linear GraphQL
  operations such as comment editing and upload flows.
---

# Linear GraphQL

Use this skill for raw Linear GraphQL work during Symphony app-server sessions.

## Primary tool

Use the `linear_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Linear auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.

## Discovering unfamiliar operations

When you need an unfamiliar mutation, input type, or object field, use targeted
introspection through `linear_graphql`.

List mutation names:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Inspect a specific input object:

```graphql
query CommentCreateInputShape {
  __type(name: "CommentCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Common workflows

### Query an issue by key, identifier, or id

Use these progressively:

- Start with `issue(id: $key)` when you have a ticket key such as `MT-686`.
- Fall back to `issues(filter: ...)` when you need identifier search semantics.
- Once you have the internal issue id, prefer `issue(id: $id)` for narrower reads.

Lookup by issue key:

```graphql
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    branchName
    url
    description
    updatedAt
    links {
      nodes {
        id
        url
        title
      }
    }
  }
}
```

Lookup by identifier filter:

```graphql
query IssueByIdentifier($identifier: String!) {
  issues(filter: { identifier: { eq: $identifier } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
      project {
        id
        name
      }
      branchName
      url
      description
      updatedAt
    }
  }
}
```

Resolve a key to an internal id:

```graphql
query IssueByIdOrKey($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Read the issue once the internal id is known:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
        createdAt
      }
    }
  }
}
```

### Query team workflow states for an issue

Use this before changing issue state when you need the exact `stateId`:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Query active issue comments

Returns the issue's Phase artifacts and their reply threads. Linear may return
reply comments in `comments.nodes`, so use `parent` to keep replies attached to
the artifact they belong to. Each top-level comment carries `resolvedAt`
(non-null once resolved) and its `children` (replies, e.g. approval replies and
rework-change summaries).

Before routing phase feedback, normalize both representations: inspect each
artifact's `children` / thread replies, and exclude any `comments.nodes` item
with `parent { id }` from standalone top-level comments.

**Default contract**: this read returns *active* state only. Drop every node
whose `resolvedAt` is non-null before using the result — resolved comments are
historical rework versions and must not enter context. Also exclude any
top-level Phase artifact whose thread already contains a phase-closing reply
(`✅ 已批准...` or `⏩ 自动进入...`); if it is still `resolvedAt: null`, resolve it
as stale cleanup before routing. The GraphQL response includes resolved and
stale-closed comments, so apply the drop client-side. Callers receive only
unresolved comments with no closing reply, which represent the current state of
each phase.

**Exception — explicit back-reference**: dropping resolved comments is a default,
not a prohibition. When current human feedback refers back to an earlier round
(e.g. "上次"/"之前提到的"/"我前面说的 X"), read the specific resolved
comment(s) needed to resolve that reference, then act on it. Pull only what the
reference requires; do not reload the whole resolved history.

```graphql
query IssueComments($issueId: String!) {
  issue(id: $issueId) {
    comments(first: 50) {
      nodes {
        id
        body
        parent {
          id
        }
        resolvedAt
        user {
          name
        }
        children(first: 50) {
          nodes {
            id
            body
            user {
              name
            }
            createdAt
          }
        }
      }
    }
  }
}
```

### Reply to a comment thread

Use `commentCreate` with `parentId` to add a reply to an existing comment.
Use this to write approval replies and rework-change summaries.

```graphql
mutation ReplyToComment($issueId: String!, $parentId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, parentId: $parentId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Resolve a comment

Resolves the comment and collapses it (with its thread) in the Linear UI.
Use this after replying with the rework-change summary, before posting a
fresh Phase artifact.

```graphql
mutation ResolveComment($id: String!) {
  commentResolve(id: $id) {
    success
    comment {
      id
      resolvedAt
    }
  }
}
```

### Edit an existing comment

Use `commentUpdate` through `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

### Create a comment

Use `commentCreate` through `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Move an issue to a different state

Use `issueUpdate` with the destination `stateId`:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

### Attach a GitHub PR to an issue

Use the GitHub-specific attachment mutation when linking a PR:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

If you only need a plain URL attachment and do not care about GitHub-specific
link metadata, use:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

### Spawn a Linear issue (create + link)

Used by the `symphony-issue` skill. Resolve the routed target project from the
WORKFLOW project routing registry, then gather ids, create, and link.

**1. Read the fields needed to spawn from the current issue** — its
`creator`, `team`, and current `project`:

```graphql
query SpawnContext($id: String!) {
  issue(id: $id) {
    id
    identifier
    url
    creator { id }
    team { id }
    project { id name }
  }
}
```

**2. Resolve the routed `projectId`.** If the routing registry names a target
project, look it up and pass its id to `issueCreate`:

```graphql
query ProjectByName($name: String!) {
  projects(filter: { name: { eqIgnoreCase: $name } }, first: 2) {
    nodes { id name }
  }
}
```

If the route is unclear, do not create a likely wrong issue; let
`symphony-issue` ask for human routing clarification in the current phase
artifact.

**3. Resolve the intake `stateId` by `type`, never by name.** Reuse the
`IssueTeamStates` query above; from `team.states.nodes`, pick the state with
`type == "triage"` if one exists, else `type == "backlog"`. Teams rename
states, so matching the literal name "Backlog" is wrong — match on `type`.

**4. Resolve the `Type:Xxx` `labelId`** from the team's labels:

```graphql
query TeamLabels($id: String!) {
  issue(id: $id) {
    team {
      id
      labels(first: 100) {
        nodes { id name }
      }
    }
  }
}
```

**5. Create the issue.** `parentId` only for sub-issues; omit otherwise.

```graphql
mutation CreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      url
    }
  }
}
```

`input`: `{ teamId, title, description, stateId, assigneeId, labelIds, projectId?, parentId? }`.

**6. Link the issue** (skip for sub-issues — parent-child is set via
`parentId` above, not a relation):

```graphql
mutation CreateIssueRelation($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) {
    success
    issueRelation { id type }
  }
}
```

`input`: `{ issueId, relatedIssueId, type }`. `type` is an `IssueRelationType`
— `related` for follow-up/related; `blocks` for "current blocks new"
(downstream blocked, with `issueId` = current, `relatedIssueId` = new).
"Blocked-by" is the reverse `blocks`. If the exact enum values are unclear,
introspect them:

```graphql
query IssueRelationTypeValues {
  __type(name: "IssueRelationType") {
    enumValues { name }
  }
}
```

### Introspection patterns used during schema discovery

Use these when the exact field or mutation shape is unclear:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

```graphql
query IssueFieldArgs {
  __type(name: "Query") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
}
```

### Upload a video to a comment

Do this in three steps:

1. Call `linear_graphql` with `fileUpload` to get `uploadUrl`, `assetUrl`, and
   any required upload headers.
2. Upload the local file bytes to `uploadUrl` with `curl -X PUT` and the exact
   headers returned by `fileUpload`.
3. Call `linear_graphql` again with `commentCreate` (or `commentUpdate`) and
   include the resulting `assetUrl` in the comment body.

Useful mutations:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

### Persist and restore Symphony agent state

Use Linear attachments for agent-only files that must survive session loss but
must not enter the GitHub PR diff, such as `.symphony/workpad.md`,
`.symphony/design.md`, and other paths listed in the workpad `cleanup`
frontmatter.

Persist:

1. Create a tarball containing agent state:

   ```sh
   tar -czf /tmp/symphony-agent-state.tgz .symphony/
   ```

2. Upload it with `fileUpload` using filename
   `symphony-agent-state-<issue-identifier>-<timestamp>.tgz`,
   content type `application/gzip`, and `makePublic: false` when supported.
3. Upload the file bytes to the returned `uploadUrl` with the exact headers
   returned by `fileUpload`.
4. Attach/link the returned `assetUrl` to the issue with title
   `Symphony agent state (<branch>, <timestamp>)` using `attachmentLinkURL`.
   Do not create or update a Linear comment for state pointers; the attachment
   title and `createdAt` are the index.

Restore:

1. Query issue attachments and select the latest attachment whose title starts
   with `Symphony agent state (`. Prefer the greatest `createdAt`.
2. Download its `url` to a temporary file.
3. Unpack it into the workspace root:

   ```sh
   tar -xzf /tmp/symphony-agent-state.tgz
   grep -qxF '.symphony/' .git/info/exclude || printf '\n.symphony/\n' >> .git/info/exclude
   ```

Do not include secrets or credentials in state attachments. Keep the tarball
limited to files listed in the workpad `cleanup` field.

## Usage rules

- Use `linear_graphql` for comment edits, uploads, and ad-hoc Linear API
  queries.
- Prefer the narrowest issue lookup that matches what you already know:
  key -> identifier search -> internal id.
- For state transitions, fetch team states first and use the exact `stateId`
  instead of hardcoding names inside mutations.
- Prefer `attachmentLinkGitHubPR` over a generic URL attachment when linking a
  GitHub PR to a Linear issue.
- Do not introduce new raw-token shell helpers for GraphQL access.
- If you need shell work for uploads, only use it for signed upload URLs
  returned by `fileUpload`; those URLs already carry the needed authorization.
