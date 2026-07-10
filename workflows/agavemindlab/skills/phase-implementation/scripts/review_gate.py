#!/usr/bin/env python3
"""Fail-closed verifier for Symphony's exact-HEAD review record."""

import json
import os
import subprocess
import sys
from pathlib import Path


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


def _under(path, root):
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


def _allowed_write(raw_path):
    home = os.path.realpath(os.path.expanduser("~"))
    expanded = raw_path.replace("$HOME", home, 1) if raw_path.startswith("$HOME/") else raw_path
    path = os.path.realpath(expanded)
    gstack = os.path.join(home, ".gstack")
    codex_sessions = os.path.join(home, ".codex", "sessions")
    codex_index = os.path.join(home, ".codex", "session_index.jsonl")
    tmp_parent = os.path.dirname(path)
    tmp_name = os.path.basename(path)
    return (
        _under(path, gstack)
        or _under(path, codex_sessions)
        or path == codex_index
        or (
            tmp_parent in {os.path.realpath("/tmp"), "/private/tmp"}
            and tmp_name.startswith(("codex-adv-", "codex-review-"))
        )
    )


def _validate_finding(finding, number, errors):
    disposition = finding.get("disposition")
    if disposition not in {"validated", "dismissed", "downgraded"}:
        errors.append(f"finding {number} has invalid disposition")
        return

    path = finding.get("path")
    line = finding.get("line")
    if not path or not isinstance(line, int) or line < 1:
        errors.append(f"finding {number} lacks file:line evidence")
    if not finding.get("validation_evidence"):
        errors.append(f"finding {number} lacks independent validation evidence")
    if not finding.get("reporter") or finding.get("validator") in {None, finding.get("reporter")}:
        errors.append(f"finding {number} lacks an independent validator")

    if disposition in {"validated", "downgraded"}:
        severity = finding.get("final_severity")
        if not finding.get("severity_evidence") or not severity:
            errors.append(f"finding {number} lacks independent severity audit")
        elif severity not in SEVERITIES:
            errors.append(f"finding {number} has invalid final severity")
        if finding.get("auditor") in {
            None,
            finding.get("reporter"),
            finding.get("validator"),
        }:
            errors.append(f"finding {number} lacks an independent severity auditor")
    if disposition == "validated" and finding.get("final_severity") in {"P0", "P1"}:
        errors.append(f"validated blocking finding remains: {path}:{line}")


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
        if config.get(name) != expected:
            errors.append(f"config {name} must be {expected!r}")

    writes = record.get("writes") or []
    if not writes:
        errors.append("write audit is empty")
    for raw_path in writes:
        if not isinstance(raw_path, str) or not _allowed_write(raw_path):
            errors.append(f"write outside review allowlist: {raw_path}")

    expected_passes = list(ALWAYS_PASSES)
    applicability = record.get("applicability") or {}
    for name in CONDITIONAL_PASSES:
        decision = applicability.get(name) or {}
        if decision.get("required") is True:
            expected_passes.append(name)
        elif decision.get("required") is False:
            if not decision.get("reason"):
                errors.append(f"N/A pass {name} lacks a reason")
        else:
            errors.append(f"pass {name} lacks applicability decision")

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
        if not item.get("evidence"):
            errors.append(f"required pass {name} lacks evidence")
        if item.get("review_base") != base or item.get("review_head") != head:
            errors.append(f"required pass {name} reviewed a different range")

    for number, finding in enumerate(record.get("findings") or [], start=1):
        _validate_finding(finding, number, errors)
    return errors


def main(argv):
    if len(argv) != 2:
        print("usage: review_gate.py RECORD.json", file=sys.stderr)
        return 2
    try:
        record = json.loads(Path(argv[1]).read_text())
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
        ).stdout.strip()
        base_ref = f"upstream/{os.environ.get('SYMPHONY_BASE_BRANCH', 'main')}"
        actual_base = subprocess.run(
            ["git", "merge-base", base_ref, head], capture_output=True, text=True, check=True
        ).stdout.strip()
        remote_head = subprocess.run(
            [
                "gh",
                "pr",
                "view",
                record["pr_url"],
                "--json",
                "headRefOid",
                "--jq",
                ".headRefOid",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        status = subprocess.run(
            ["git", "status", "--porcelain"], capture_output=True, text=True, check=True
        ).stdout
        record["current_head"] = head
        record["pr_head"] = remote_head or None
        record["worktree_clean"] = status == ""
        if record.get("review_base") != actual_base:
            record.setdefault("runtime_errors", []).append(
                f"review base does not match merge-base of {base_ref}"
            )
        errors = evaluate(record)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        errors = [f"invalid review record: {exc}"]
        record = {}
    print(
        json.dumps(
            {
                "verdict": "clean" if not errors else "non-clean",
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
