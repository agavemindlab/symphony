#!/usr/bin/env sh
set -u

if [ -z "${LINEAR_API_KEY:-}" ] || [ -z "${SYMPHONY_ISSUE_ID:-}" ]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to record Maestro preflight failure" >&2
  exit 0
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
status = os.environ.get("SYMPHONY_MAESTRO_FAILURE_STATUS", "unknown")
reason = os.environ.get("SYMPHONY_MAESTRO_FAILURE_REASON", "after_create failed")


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
query MaestroPreflightFailureIssue($issueId: String!) {
  issue(id: $issueId) {
    id
    state { name }
    comments(first: 50) {
      nodes {
        id
        body
        createdAt
        parent { id }
        resolvedAt
        children(first: 50) {
          nodes { id body createdAt }
        }
      }
    }
  }
}
"""

issue_label_query = """
query MaestroPreflightFailureIssueLabels($issueId: String!, $after: String) {
  issue(id: $issueId) {
    labels(first: 100, after: $after) {
      nodes { id name }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""

comment_create_mutation = """
mutation MaestroPreflightFailureComment($issueId: String!, $parentId: String!, $body: String!) {
  commentCreate(input: {issueId: $issueId, parentId: $parentId, body: $body}) {
    success
  }
}
"""

issue_update_mutation = """
mutation MaestroPreflightFailureCleanup($issueId: String!, $labelIds: [String!]) {
  issueUpdate(id: $issueId, input: {labelIds: $labelIds}) {
    success
  }
}
"""


def safe(action, callback):
    try:
        return callback()
    except Exception as exc:
        print(f"Maestro preflight failure {action} failed: {exc}", file=sys.stderr)
        return None


def require_success(data, field, action):
    result = data.get(field) or {}
    if result.get("success") is not True:
        raise RuntimeError(f"Linear {action} failed: success was not true")


def fetch_issue_labels():
    after = None
    labels = []

    while True:
        data = graphql(issue_label_query, {"issueId": issue_id, "after": after})
        page = ((data.get("issue") or {}).get("labels") or {})
        labels.extend(page.get("nodes") or [])

        page_info = page.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            return labels

        after = page_info.get("endCursor")
        if not after:
            return labels


def phase_artifact(comment):
    body = comment.get("body") or ""
    return any(
        body.startswith(heading)
        for heading in ("## Requirements", "## Design", "## Implementation", "## Deployment")
    )


def phase_closed(comment):
    children = ((comment.get("children") or {}).get("nodes") or [])

    return any(
        (child.get("body") or "").startswith("✅ 已批准")
        or (child.get("body") or "").startswith("⏩ 自动进入")
        for child in children
    )


def current_artifact(comments):
    artifacts = [
        comment
        for comment in comments
        if not (comment.get("parent") or {}).get("id")
        and not comment.get("resolvedAt")
        and phase_artifact(comment)
    ]
    artifacts.sort(key=lambda comment: comment.get("createdAt") or "", reverse=True)

    for artifact in artifacts:
        if not phase_closed(artifact):
            return artifact

    return artifacts[0] if artifacts else None


def record_no_action(issue):
    state = ((issue.get("state") or {}).get("name") or "").strip()
    if state != "Human Review":
        return

    artifact = current_artifact(((issue.get("comments") or {}).get("nodes") or []))
    if not artifact:
        return

    body = (
        "🤖 Maestro 预审核: 未自动执行\n\n"
        f"- 原因: Maestro workflow `after_create` 在 Codex prompt 启动前失败（status `{status}`; {reason}）。\n"
        "- 结果: issue 保持 `Human Review`；已尝试清理 `symphony:maestro`，避免重复预审循环。"
    )

    result = graphql(
        comment_create_mutation,
        {"issueId": issue_id, "parentId": artifact["id"], "body": body},
    )
    require_success(result, "commentCreate", "comment create")


def cleanup_maestro_label():
    labels = fetch_issue_labels()
    label_ids = [
        label["id"]
        for label in labels
        if label.get("id") and label.get("name") != "symphony:maestro"
    ]

    if len(label_ids) == len([label for label in labels if label.get("id")]):
        return

    result = graphql(issue_update_mutation, {"issueId": issue_id, "labelIds": label_ids})
    require_success(result, "issueUpdate", "issue update")


data = safe("issue fetch", lambda: graphql(issue_query, {"issueId": issue_id}))
issue = (data or {}).get("issue")
if not issue:
    sys.exit(0)

safe("commentCreate", lambda: record_no_action(issue))
safe("issueUpdate", cleanup_maestro_label)
PY
