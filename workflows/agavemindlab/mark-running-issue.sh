#!/usr/bin/env sh
set -eu

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

if [ -z "${SSL_CERT_FILE:-}" ] && [ -z "${REQUESTS_CA_BUNDLE:-}" ] && [ -z "${CURL_CA_BUNDLE:-}" ]; then
  for ca_bundle in \
    /etc/ssl/cert.pem \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/ssl/ca-bundle.pem \
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  do
    if [ -f "$ca_bundle" ]; then
      export SSL_CERT_FILE="$ca_bundle"
      break
    fi
  done
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
    team {
      id
    }
  }
}
"""

issue_label_query = """
query SymphonyRunningMarkerIssueLabels($issueId: String!, $after: String) {
  issue(id: $issueId) {
    labels(first: 100, after: $after) {
      nodes { id name }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""

team_label_query = """
query SymphonyRunningMarkerTeamLabels($issueId: String!, $after: String) {
  issue(id: $issueId) {
    team {
      labels(first: 100, after: $after) {
        nodes { id name }
        pageInfo { hasNextPage endCursor }
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


def find_label_id(labels, name):
    return next(
        (label["id"] for label in labels if label.get("name") == name and label.get("id")),
        None,
    )


def require_success(data, field, action):
    result = data.get(field) or {}
    if result.get("success") is not True:
        raise RuntimeError(f"Linear {action} failed: success was not true")

    return result


def fetch_issue_labels():
    after = None
    current_labels = []

    while True:
        data = graphql(issue_label_query, {"issueId": issue_id, "after": after})
        labels = (data.get("issue") or {}).get("labels", {})
        current_labels.extend(labels.get("nodes", []))

        page_info = labels.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            return current_labels

        after = page_info.get("endCursor")
        if not after:
            return current_labels


def find_team_label_id(name):
    after = None

    while True:
        data = graphql(team_label_query, {"issueId": issue_id, "after": after})
        labels = (
            ((data.get("issue") or {}).get("team") or {})
            .get("labels", {})
        )
        label_id_found = find_label_id(labels.get("nodes", []), name)
        if label_id_found:
            return label_id_found

        page_info = labels.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            return None

        after = page_info.get("endCursor")
        if not after:
            return None


issue = graphql(issue_query, {"issueId": issue_id}).get("issue")
if not issue:
    sys.exit(0)

team = issue.get("team") or {}
team_id = team.get("id")
current_labels = fetch_issue_labels()
current_ids = [label["id"] for label in current_labels if label.get("id")]
current_label_id = find_label_id(current_labels, label_name)

if event == "running":
    label_id = current_label_id or find_team_label_id(label_name)
    if not label_id:
        if not team_id:
            raise RuntimeError("Linear issue team id missing; cannot create running marker label")

        created = graphql(label_create_mutation, {"teamId": team_id, "name": label_name})
        create_result = require_success(created, "issueLabelCreate", "issue label create")
        label_id = (create_result.get("issueLabel") or {}).get("id")
        if not label_id:
            raise RuntimeError("Linear issue label create did not return an issueLabel id")

    updated_ids = list(dict.fromkeys(current_ids + [label_id]))
else:
    label_id = current_label_id
    if not label_id:
        sys.exit(0)

    updated_ids = [label_id_current for label_id_current in current_ids if label_id_current != label_id]

if updated_ids == current_ids:
    sys.exit(0)

update_result = graphql(issue_update_mutation, {"issueId": issue_id, "labelIds": updated_ids})
require_success(update_result, "issueUpdate", "issue update")
PY
