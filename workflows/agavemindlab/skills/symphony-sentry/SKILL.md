---
name: symphony-sentry
description: Read Sentry evidence for Symphony issues. Use when a Linear issue has a `sourceType: sentry` attachment, a phase needs Sentry issue/event detail, stack traces, issue events, or recent Sentry status, or the user explicitly asks Codex to inspect Sentry. Prefer authenticated `sentry-cli` or Sentry REST API evidence over unauthenticated Sentry web URLs.
---

# Symphony Sentry Evidence

Use this skill to turn a Linear Sentry attachment into a small, redacted
evidence summary for Requirements, Design, Implementation, or Deployment.

## Evidence Order

1. Read the Linear attachment and nearby issue context. Extract what is present:
   `org`, `project`, numeric Sentry issue id, short id, and event id.
2. Probe local CLI capability:

   ```sh
   command -v sentry-cli
   sentry-cli info
   ```

3. If CLI auth works, use it for issue/project discovery and recent status.
   Do not treat CLI auth alone as event-detail auth: current `sentry-cli`
   exposes `events list`, but not an issue-event detail or stacktrace command.
   Avoid `--max-rows` for target issue lookup because it can trim away older
   matching issues before the target row is printed. Capture the broad listing
   and filter it locally for the parsed issue id or short id:

   ```sh
   sentry-cli issues list -o "$org" -p "$project" --all |
     awk -v issue_id="$issue_id" -v short_id="${short_id:-}" '
       $0 ~ "\\|[[:space:]]*" issue_id "[[:space:]]*\\|" ||
       (short_id != "" && $0 ~ "\\|[[:space:]]*" short_id "[[:space:]]*\\|")
     '
   ```

   If this does not find the target, say "not found in CLI issue listing" and
   continue to the REST path when a token is available. Do not conclude the
   Sentry issue is absent. Use `sentry-cli events list` only as project-recent
   context; it is not scoped to the parsed issue and does not prove stack
   detail.

4. Use Sentry REST API for issue/event detail and stack traces when CLI output
   is insufficient, when the CLI cannot fetch detail, or when CLI auth is
   unavailable. Pick the token without printing it:

   ```sh
   set +x
   sentry_token="${SENTRY_AUTH_TOKEN:-${SENTRY_TOKEN:-}}"
   ```

   If the CLI exists but global CLI auth failed, retry CLI auth with the env
   token before falling back to raw API calls:

   ```sh
   sentry-cli --auth-token "$sentry_token" info
   sentry-cli --auth-token "$sentry_token" issues list -o "$org" -p "$project" --all |
     awk -v issue_id="$issue_id" -v short_id="${short_id:-}" '
       $0 ~ "\\|[[:space:]]*" issue_id "[[:space:]]*\\|" ||
       (short_id != "" && $0 ~ "\\|[[:space:]]*" short_id "[[:space:]]*\\|")
     '
   ```

   Then call only the needed REST endpoints, and never print raw API JSON. Pipe
   responses through a selector that emits only fields safe for the phase
   artifact:

   ```sh
   curl -fsS "https://sentry.io/api/0/organizations/$org/issues/$issue_id/" \
     -H "Authorization: Bearer $sentry_token" |
     jq '{id, shortId, title, status, lastSeen, project: .project.slug}'

   curl -fsS "https://sentry.io/api/0/organizations/$org/issues/$issue_id/events/?full=1&per_page=5" \
     -H "Authorization: Bearer $sentry_token" |
     jq '[.[] | {eventID, title, dateCreated, location, culprit}]'

   curl -fsS "https://sentry.io/api/0/organizations/$org/issues/$issue_id/events/${event_id:-latest}/" \
     -H "Authorization: Bearer $sentry_token" |
     jq '{eventID, title, dateReceived, dateCreated, error: .metadata, stack: ([.entries[]? | select(.type=="exception") | .data.values[]?.stacktrace.frames[]? | {function, filename, absPath, lineNo, inApp}] | .[-8:])}'

   curl -fsS "https://sentry.io/api/0/projects/$org/$project/events/$event_id/" \
     -H "Authorization: Bearer $sentry_token" |
     jq '{eventID, title, dateReceived, dateCreated, error: .metadata, stack: ([.entries[]? | select(.type=="exception") | .data.values[]?.stacktrace.frames[]? | {function, filename, absPath, lineNo, inApp}] | .[-8:])}'
   ```

   If you must inspect a full payload to locate the stack shape, store it only
   in a mode-600 file under `.issue-secrets/`, summarize the needed fields, and
   delete it before persisting Symphony state or posting artifacts. Do not use
   `.symphony/` for raw Sentry payloads because state attachments may archive
   files from that directory.
   If `jq` is unavailable, use a small Python JSON selector with the same
   allowlist; do not fall back to printing raw JSON.

5. Only after CLI and API fail, check the Sentry web URL as fallback evidence.
   A redirect to `/auth/login/...` means the web session is not authenticated;
   it does not mean Symphony lacks Sentry capability or that no stack trace
   exists.

## Extracting IDs

Use structured Linear attachment fields first. From a Sentry web URL, parse the
stable pieces before query parameters:

- `/organizations/<org>/issues/<issue_id>/`
- `/organizations/<org>/issues/<issue_id>/events/<event_id>/`
- `?project=<project id or slug>` when present

If the project slug is missing, retrieve the issue by organization + issue id
first; the issue response includes project data. Do not guess a project slug
from the Linear project name.

## Auth Boundaries

- `sentry-cli info` may succeed through global CLI login even when no token env
  var is present. Use that for CLI discovery only.
- Event detail and stack traces require an authenticated detail path: a REST
  bearer token from env, or a future CLI subcommand that actually returns
  issue-event detail. With current CLI-only global auth, report issue discovery
  as available and detail auth as missing instead of pretending stack detail was
  read.
- For REST API, prefer `SENTRY_AUTH_TOKEN`, then `SENTRY_TOKEN`. Do not extract
  a token from `sentry-cli` config files.
- In the `grandline` aggregate workflow, do not assume a child project's
  `workflows/<project>/project.env.local` was sourced. Put shared Sentry auth
  in the selected operator profile, the aggregate workflow env, or the global
  `sentry-cli` login.
- Never read or print env files just to discover a token. Report the variable
  names and auth state, not values.

## Failure Reporting

When auth is unavailable, report the missing capability precisely:

```md
Sentry evidence unavailable through CLI/API.
- Parsed: org `<org|unknown>`, project `<project|unknown>`, issue `<id|unknown>`, event `<id|none>`
- Tried: `command -v sentry-cli` -> <result>
- Tried: `sentry-cli info` -> <result>
- CLI issue lookup: <matched issue row|not found in listing|not attempted>
- CLI detail capability: <no issue-event detail command in this sentry-cli|available command + result>
- Tried: `sentry-cli --auth-token "$sentry_token" info` -> <result|not attempted>
- Tried: REST token env -> `SENTRY_AUTH_TOKEN` <present|absent>, `SENTRY_TOKEN` <present|absent>
- API result: <401|403|missing token|not attempted because org/issue missing>
- Web fallback: <not attempted|redirected to /auth/login/...>
```

Do not write "no Sentry capability" unless both CLI and API paths were probed
and failed for captured reasons.

## DEV-5439 Sanity Check

Use this issue as a safe, redacted fixture when validating the runbook shape:

```sh
org=gl-test
project=grotto
issue_id=7597426195
short_id=GROTTO-HD
```

Known behavior on `sentry-cli 3.4.1`:

- `sentry-cli info` can succeed through global CLI auth while
  `SENTRY_AUTH_TOKEN` and `SENTRY_TOKEN` are absent in the agent shell.
- `sentry-cli issues list -o gl-test -p grotto -i 7597426195 --max-rows 5`
  returns recent rows that may exclude `GROTTO-HD`; do not use this as the
  target lookup.
- `sentry-cli issues list -o gl-test -p grotto --all | rg '7597426195|GROTTO-HD'`
  finds the target row: issue `7597426195`, short id `GROTTO-HD`, title
  `TimeoutError: QueuePool limit...`, last seen `2026-07-07T04:23:17.617737Z`,
  status `unresolved`.
- With no REST token env, the correct outcome is CLI issue discovery plus
  "event-detail auth missing"; do not claim stack/function/path evidence was
  retrieved.

## Safe Summary Shape

Write only the smallest useful evidence into Linear, PRs, commit messages, and
logs:

```md
Sentry evidence:
- Issue: `<issue_id>` / `<short_id>` - status `<status>` - last seen `<lastSeen>`
- Event: `<event_id>` - title `<title>` - received `<dateReceived|dateCreated>`
- Error: `<exception type>` `<message summary>`
- Key stack:
  - `<function>` at `<path>:<line>` (`in_app=<true|false>`)
  - `<function>` at `<path>:<line>`
- Recent events: `<count>` checked, newest `<timestamp>`
- Evidence path: `<sentry-cli|Sentry REST API>`
```

Never paste tokens, cookies, request headers, full request bodies, full event
payloads, user emails, IP addresses, or raw context variables. If a stack frame
or message contains sensitive values, redact the value and keep the function,
path, line, and error class.
