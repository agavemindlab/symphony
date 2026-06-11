#!/usr/bin/env bash
set -euo pipefail

event="${SYMPHONY_HOOK_EVENT:-${1:-}}"

case "$event" in
  running|stopped) ;;
  *)
    echo "Unsupported SYMPHONY_HOOK_EVENT: ${event:-<empty>}" >&2
    exit 0
    ;;
esac

if [ -z "${LINEAR_API_KEY:-}" ] || [ -z "${SYMPHONY_ISSUE_ID:-}" ]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to update the Linear running marker" >&2
  exit 1
fi

python3 <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request


endpoint = os.environ.get("LINEAR_API_ENDPOINT", "https://api.linear.app/graphql")
token = os.environ["LINEAR_API_KEY"]
issue_id = os.environ["SYMPHONY_ISSUE_ID"]
event = os.environ["SYMPHONY_HOOK_EVENT"]

label_name = os.environ.get("SYMPHONY_RUNNING_LABEL")
if not label_name:
    agent_id = (
        os.environ.get("SYMPHONY_AGENT_ID")
        or os.environ.get("SYMPHONY_PROFILE")
        or "default"
    )
    label_name = f"symphony:running:{agent_id}"


def graphql(query, variables):
    request = urllib.request.Request(
        endpoint,
        data=json.dumps({"query": query, "variables": variables}).encode("utf-8"),
        headers={"Authorization": token, "Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Linear API HTTP {error.code}: {body}") from error

    if payload.get("errors"):
        raise RuntimeError(f"Linear GraphQL errors: {payload['errors']}")

    return payload.get("data") or {}


issue_query = """
query SymphonyRunningMarkerIssue($issueId: String!) {
  issue(id: $issueId) {
    labels {
      nodes { id name }
    }
    team {
      id
      labels(first: 100) {
        nodes { id name }
      }
    }
  }
}
"""

label_create_mutation = """
mutation SymphonyRunningMarkerCreateLabel($teamId: String!, $name: String!) {
  issueLabelCreate(input: {teamId: $teamId, name: $name}) {
    success
    issueLabel { id name }
  }
}
"""

issue_update_mutation = """
mutation SymphonyRunningMarkerUpdateIssue($issueId: String!, $labelIds: [String!]) {
  issueUpdate(id: $issueId, input: {labelIds: $labelIds}) {
    success
  }
}
"""


issue = graphql(issue_query, {"issueId": issue_id}).get("issue")
if not issue:
    sys.exit(0)

current_labels = issue.get("labels", {}).get("nodes", [])
team = issue.get("team") or {}
team_id = team.get("id")
team_labels = team.get("labels", {}).get("nodes", [])

current_ids = [label["id"] for label in current_labels if label.get("id")]
label_id = next((label["id"] for label in team_labels if label.get("name") == label_name), None)

if event == "running":
    if not label_id:
        if not team_id:
            raise RuntimeError("Linear issue team id missing; cannot create running marker label")

        created = graphql(label_create_mutation, {"teamId": team_id, "name": label_name})
        label_id = created["issueLabelCreate"]["issueLabel"]["id"]

    updated_ids = list(dict.fromkeys(current_ids + [label_id]))
else:
    if not label_id:
        sys.exit(0)

    updated_ids = [label_id_current for label_id_current in current_ids if label_id_current != label_id]

if updated_ids == current_ids:
    sys.exit(0)

graphql(issue_update_mutation, {"issueId": issue_id, "labelIds": updated_ids})
PY
