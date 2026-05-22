---
name: debug
description:
  Investigate stuck Symphony runs and execution failures by tracing logs with
  issue and session identifiers.
---

# Debug

## Goals

- Find why a run is stuck, retrying, or failing.
- Correlate Linear issue identity to the agent session.
- Capture concrete evidence before proposing a fix.

## Correlation Keys

- `issue_identifier`: human ticket key.
- `issue_id`: Linear UUID.
- `session_id`: agent session or turn identifier when present.
- `workspace`: local workspace path.

## Workflow

1. Confirm the ticket, project, and workspace under investigation.
2. Search runtime logs by `issue_identifier` first, then by `issue_id` if needed.
3. Extract the session identifier and trace that session from start to terminal event.
4. Classify the failure: hook failure, startup failure, turn failure, timeout/stall, retry loop, or cleanup failure.
5. Record the exact command/log slice and probable root cause in the workpad.
6. Fix only after root cause is supported by evidence.

## Commands

```sh
rg -n "issue_identifier=<KEY>" log/*
rg -n "issue_id=<UUID>" log/*
rg -o "session_id=[^ ;]+" log/* | sort -u
rg -n "session_id=<SESSION>" log/*
rg -n "hook failed|timed out|scheduling retry|turn_failed|ended with error" log/*
```

## Notes

- Prefer `rg` over `grep`.
- Keep evidence narrow enough to avoid exposing secrets or unrelated user data.
