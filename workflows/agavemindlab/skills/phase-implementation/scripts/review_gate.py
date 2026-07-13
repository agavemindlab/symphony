#!/usr/bin/env python3
"""Fail-closed verifier for Symphony's exact-HEAD review record."""

import hashlib
import json
import os
import pwd
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse


ALWAYS_PASSES = (
    "core-correctness",
    "testing",
    "maintainability",
    "security",
    "performance",
    "red-team",
    "claude-adversarial",
    "codex-adversarial",
    "codex-structured",
)
CONDITIONAL_PASSES = ("api-contract", "migration", "design")
REQUIRED_CONFIG = {
    "telemetry": "off",
    "update_check": False,
    "artifacts_sync_mode": "off",
    "artifacts_sync_mode_prompted": True,
    "cross_project_learnings": False,
    "checkpoint_mode": "explicit",
    "checkpoint_push": False,
    "codex_reviews": "enabled",
}
SEVERITIES = {"P0", "P1", "P2", "P3", "P4"}


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _identity(value):
    return value.strip() if _text(value) else None


def _under(path, root):
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


def _trusted_home():
    return os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)


def _temp_review_path(path):
    return os.path.dirname(path) == os.path.realpath("/tmp") and os.path.basename(path).startswith(
        ("codex-adv-", "codex-review-")
    )


def _allowed_write(raw_path):
    home = _trusted_home()
    expanded = raw_path.replace("$HOME", home, 1) if raw_path.startswith("$HOME/") else raw_path
    path = os.path.realpath(expanded)
    gstack = os.path.join(home, ".gstack")
    codex_sessions = os.path.join(home, ".codex", "sessions")
    codex_index = os.path.join(home, ".codex", "session_index.jsonl")
    return (
        _under(path, gstack)
        or _under(path, codex_sessions)
        or path == codex_index
        or _temp_review_path(path)
    )


def required_passes(record):
    errors = []
    expected = list(ALWAYS_PASSES)
    applicability = record.get("applicability") or {}
    for name in CONDITIONAL_PASSES:
        decision = applicability.get(name) or {}
        if decision.get("required") is True:
            expected.append(name)
        elif decision.get("required") is False:
            if not _text(decision.get("reason")):
                errors.append(f"N/A pass {name} lacks a reason")
        else:
            errors.append(f"pass {name} lacks applicability decision")
    return expected, errors


def _validate_finding(finding, number, errors):
    disposition = finding.get("disposition")
    if disposition not in {"validated", "dismissed", "downgraded"}:
        errors.append(f"finding {number} has invalid disposition")
        return

    path = finding.get("path")
    line = finding.get("line")
    if not _text(path) or type(line) is not int or line < 1:
        errors.append(f"finding {number} lacks file:line evidence")
    if not _text(finding.get("validation_evidence")):
        errors.append(f"finding {number} lacks independent validation evidence")
    reporter = _identity(finding.get("reporter"))
    validator = _identity(finding.get("validator"))
    if not reporter or not validator or validator == reporter:
        errors.append(f"finding {number} lacks an independent validator")

    if disposition in {"validated", "downgraded"}:
        severity = finding.get("final_severity")
        if not _text(finding.get("severity_evidence")) or not severity:
            errors.append(f"finding {number} lacks independent severity audit")
        elif severity not in SEVERITIES:
            errors.append(f"finding {number} has invalid final severity")
        auditor = _identity(finding.get("auditor"))
        if not auditor or auditor in {reporter, validator}:
            errors.append(f"finding {number} lacks an independent severity auditor")
    if disposition in {"validated", "downgraded"} and finding.get("final_severity") in {"P0", "P1"}:
        errors.append(f"audited blocking finding remains: {path}:{line}")


def _feedback_digest(pr, inline_comments):
    evidence = {
        "comments": pr.get("comments") or [],
        "reviews": pr.get("reviews") or [],
        "inline": inline_comments,
    }
    payload = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def _change_request_authors(pr):
    latest = {}
    for review in pr.get("reviews") or []:
        author = (review.get("author") or {}).get("login")
        submitted = review.get("submittedAt") or ""
        if author and (author not in latest or submitted >= latest[author][0]):
            latest[author] = (submitted, review.get("state"))
    return sorted(author for author, (_, state) in latest.items() if state == "CHANGES_REQUESTED")


def _check_pr(pr, record, errors):
    if pr.get("url") != record.get("pr_url"):
        errors.append("canonical PR URL does not match review record")
    if pr.get("baseRefName") != record.get("pr_base_branch"):
        errors.append("PR base branch does not match review record")
    if pr.get("state") != "OPEN":
        errors.append("PR is not open")
    change_request_authors = _change_request_authors(pr)
    if pr.get("reviewDecision") == "CHANGES_REQUESTED" or change_request_authors:
        errors.append(f"PR has unresolved change requests: {', '.join(change_request_authors) or 'reviewDecision'}")
    checks = pr.get("statusCheckRollup") or []
    if not checks:
        errors.append("PR status checks are empty")
    for check in checks:
        conclusion = check.get("conclusion") or check.get("state")
        status = check.get("status")
        if status and status != "COMPLETED":
            errors.append(f"PR check is not complete: {check.get('name') or check.get('context')}")
        if conclusion not in {"SUCCESS", "SKIPPED", "NEUTRAL"}:
            errors.append(f"PR check is not successful: {check.get('name') or check.get('context')}")


def _check_final_snapshot(pr, final_pr, feedback_digest, final_feedback_digest, record, errors):
    _check_pr(final_pr, record, errors)
    if final_pr.get("headRefOid") != pr.get("headRefOid"):
        errors.append("PR head changed during gate verification")
    if final_feedback_digest != feedback_digest:
        errors.append("PR feedback changed during gate verification")


def _flatten_pages(value):
    return [item for page in value for item in page] if value and isinstance(value[0], list) else value


def evaluate(record):
    errors = list(record.get("runtime_errors") or [])
    base = record.get("review_base")
    head = record.get("review_head")

    if not isinstance(base, str) or len(base) != 40:
        errors.append("review base must be a full SHA")
    if not isinstance(head, str) or len(head) != 40:
        errors.append("review head must be a full SHA")
    if record.get("current_head") != head:
        errors.append("current HEAD does not match review HEAD")
    if record.get("pr_head") != head:
        errors.append("PR HEAD does not match review HEAD")
    if record.get("worktree_clean") is not True:
        errors.append("worktree is not clean")

    config = record.get("config") or {}
    for name, expected in REQUIRED_CONFIG.items():
        actual = config.get(name)
        if type(actual) is not type(expected) or actual != expected:
            errors.append(f"config {name} must be {expected!r}")

    writes = record.get("writes") or []
    if not writes:
        errors.append("write audit is empty")
    for raw_path in writes:
        if not isinstance(raw_path, str) or not _allowed_write(raw_path):
            errors.append(f"write outside review allowlist: {raw_path}")
        elif _temp_review_path(os.path.realpath(raw_path)) and os.path.lexists(
            os.path.realpath(raw_path)
        ):
            errors.append(f"temporary review path was not cleaned: {raw_path}")

    expected_passes, plan_errors = required_passes(record)
    errors.extend(plan_errors)

    passes = {}
    for item in record.get("passes") or []:
        name = item.get("name")
        if name in passes:
            errors.append(f"duplicate pass: {name}")
        passes[name] = item

    for name in expected_passes:
        item = passes.get(name)
        if item is None:
            errors.append(f"missing required pass: {name}")
            continue
        status = item.get("status")
        if status != "completed":
            errors.append(f"required pass {name} is {status}")
        if not _text(item.get("evidence")):
            errors.append(f"required pass {name} lacks evidence")
        if item.get("review_base") != base or item.get("review_head") != head:
            errors.append(f"required pass {name} reviewed a different range")

    raw_findings = record.get("raw_findings") or []
    raw_ids = [finding.get("id") for finding in raw_findings]
    final_findings = record.get("findings") or []
    final_ids = [finding.get("raw_finding_id") for finding in final_findings]
    if any(not _text(finding_id) for finding_id in raw_ids) or len(raw_ids) != len(set(raw_ids)):
        errors.append("raw findings require unique non-empty ids")
    if any(not _text(finding_id) for finding_id in final_ids) or len(final_ids) != len(set(final_ids)):
        errors.append("final findings require unique raw_finding_id values")
    if set(raw_ids) != set(final_ids):
        errors.append("every raw finding requires exactly one final disposition")
    for number, finding in enumerate(final_findings, start=1):
        _validate_finding(finding, number, errors)
    return errors


def _run(command):
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout.strip()


def _repo_identity(remote):
    if remote.startswith("git@"):
        authority, path = remote.split(":", 1)
        host = authority.split("@", 1)[1]
    else:
        parsed = urlparse(remote)
        host, path = parsed.hostname, parsed.path
    if not host:
        raise ValueError(f"upstream remote lacks a canonical host: {remote}")
    parts = path.removesuffix(".git").strip("/").split("/")
    if len(parts) < 2:
        raise ValueError(f"cannot derive GitHub repository from upstream remote: {remote}")
    return host.lower(), "/".join(parts[-2:])


def _pr_number(pr_url, host, repo):
    parsed = urlparse(pr_url)
    parts = parsed.path.strip("/").split("/")
    if (
        parsed.scheme != "https"
        or parsed.hostname != host
        or len(parts) != 4
        or "/".join(parts[:2]) != repo
        or parts[2] != "pull"
        or not parts[3].isdigit()
    ):
        raise ValueError("canonical PR URL does not belong to the upstream repository")
    return parts[3]


def _github_snapshot(record):
    host, repo = _repo_identity(_run(["git", "remote", "get-url", "upstream"]))
    pr_url = record.get("pr_url")
    if not _text(pr_url):
        raise ValueError("review record lacks canonical PR URL")
    pr_number = _pr_number(pr_url, host, repo)
    pr = json.loads(
        _run(
            [
                "gh",
                "pr",
                "view",
                pr_url,
                "--repo",
                f"{host}/{repo}",
                "--json",
                "headRefOid,baseRefName,state,url,reviewDecision,statusCheckRollup,reviews,comments",
            ]
        )
    )
    inline = _flatten_pages(
        json.loads(
            _run(
                [
                    "gh",
                    "api",
                    "--hostname",
                    host,
                    "--paginate",
                    "--slurp",
                    f"repos/{repo}/pulls/{pr_number}/comments",
                ]
            )
            or "[]"
        )
    )
    return pr, _feedback_digest(pr, inline)


def main(argv):
    if len(argv) not in {2, 3} or (len(argv) == 3 and argv[1] not in {"--plan", "--snapshot"}):
        print("usage: review_gate.py [--plan|--snapshot] RECORD.json", file=sys.stderr)
        return 2
    try:
        record = json.loads(Path(argv[-1]).read_text())
        if len(argv) == 3 and argv[1] == "--plan":
            passes, errors = required_passes(record)
            print(json.dumps({"passes": passes, "errors": errors}, indent=2, sort_keys=True))
            return 0 if not errors else 1
        trusted_home = _trusted_home()
        if os.path.realpath(os.environ.get("HOME", "")) != trusted_home:
            raise ValueError("HOME does not match the current OS account")
        head = _run(["git", "rev-parse", "HEAD"])
        base_branch = os.environ.get("SYMPHONY_BASE_BRANCH", "main")
        base_ref = f"upstream/{base_branch}"
        actual_base = _run(["git", "merge-base", base_ref, head])
        pr, feedback_digest = _github_snapshot(record)
        if len(argv) == 3:
            print(
                json.dumps(
                    {
                        "pr_feedback_digest": feedback_digest,
                        "pr_head": pr.get("headRefOid"),
                        "pr_url": pr.get("url"),
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
            return 0
        status = _run(["git", "status", "--porcelain"])
        record["current_head"] = head
        record["pr_head"] = pr.get("headRefOid")
        record["pr_base_branch"] = base_branch
        record["worktree_clean"] = status == ""
        runtime_errors = list(record.get("runtime_errors") or [])
        record["runtime_errors"] = runtime_errors
        if record.get("review_base") != actual_base:
            runtime_errors.append(f"review base does not match merge-base of {base_ref}")
        _check_pr(pr, record, runtime_errors)
        if record.get("pr_feedback_digest") != feedback_digest:
            runtime_errors.append("PR feedback snapshot changed or was not recorded")
        final_head = _run(["git", "rev-parse", "HEAD"])
        final_pr, final_feedback_digest = _github_snapshot(record)
        final_status = _run(["git", "status", "--porcelain"])
        if final_head != head:
            runtime_errors.append("local HEAD changed during gate verification")
        _check_final_snapshot(
            pr, final_pr, feedback_digest, final_feedback_digest, record, runtime_errors
        )
        if final_status:
            runtime_errors.append("worktree changed during gate verification")
        errors = evaluate(record)
    except (KeyError, OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        errors = [f"invalid review record: {exc}"]
        record = {}
    print(
        json.dumps(
            {
                "verdict": "clean" if not errors else "non-clean",
                "handoff_actions": (
                    ["publish_implementation_artifact", "move_human_review"] if not errors else []
                ),
                "review_head": record.get("review_head"),
                "errors": errors,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
