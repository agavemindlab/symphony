#!/usr/bin/env python3
"""Fail-closed verifier for Symphony's exact-HEAD review record."""

import hashlib
import json
import os
import pwd
import re
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
WRITE_POLICY = (
    "workspace",
    "$HOME/.gstack",
    "$HOME/.codex/sessions",
    "$HOME/.codex/session_index.jsonl",
    "/tmp/codex-{adv,review}-*",
)
PRODUCER = Path(__file__).with_name("review_producer.py")
TRUSTED_TOOL_CANDIDATES = {
    "git": (Path("/usr/bin/git"), Path("/opt/homebrew/bin/git")),
    "gh": (
        Path("/usr/bin/gh"),
        Path("/opt/homebrew/bin/gh"),
        Path("/usr/local/bin/gh"),
    ),
}


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
    root = Path("/tmp").resolve()
    candidate = Path(path).resolve()
    try:
        parts = candidate.relative_to(root).parts
    except ValueError:
        return False
    return bool(parts) and parts[0].startswith(("codex-adv-", "codex-review-"))


def _allowed_write(raw_path):
    home = _trusted_home()
    expanded = (
        raw_path.replace("$HOME", home, 1)
        if raw_path.startswith("$HOME/")
        else raw_path
    )
    path = os.path.abspath(expanded)
    gstack = os.path.join(home, ".gstack")
    codex_sessions = os.path.join(home, ".codex", "sessions")
    codex_index = os.path.join(home, ".codex", "session_index.jsonl")
    if _under(path, codex_sessions):
        if os.path.islink(path):
            return os.path.basename(path) == "auth.json" and os.path.realpath(
                path
            ) == os.path.realpath(os.path.join(home, ".codex", "auth.json"))
        return _under(os.path.realpath(path), codex_sessions)
    return (
        _under(os.path.realpath(path), gstack)
        or path == codex_index
        or _temp_review_path(path)
    )


def _sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _trusted_tool(name):
    candidates = TRUSTED_TOOL_CANDIDATES[name]
    workspace = Path.cwd().resolve()
    for candidate in candidates:
        if not candidate.exists():
            continue
        resolved = candidate.resolve()
        mode = resolved.stat().st_mode
        if (
            resolved.is_file()
            and not resolved.is_relative_to(workspace)
            and not mode & 0o022
        ):
            return str(candidate)
    raise ValueError(f"trusted {name} executable is unavailable")


def _safe_write(path, content):
    if path.is_symlink():
        raise ValueError(f"refusing to write symlinked review evidence: {path}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(content)


def _workspace_record(record_path):
    workspace = Path.cwd().resolve()
    if record_path.is_symlink():
        raise ValueError("review record path may not traverse symlinks")
    candidate = record_path.resolve()
    if not candidate.is_relative_to(workspace):
        raise ValueError("review record must stay inside the workspace")
    current = workspace
    for part in candidate.relative_to(workspace).parts:
        current /= part
        if current.is_symlink():
            raise ValueError("review record path may not traverse symlinks")
    return candidate


def _receipt_path(record, record_path):
    reference = record.get("evidence_receipt") or {}
    raw_path = reference.get("path")
    if not _text(raw_path) or Path(raw_path).is_absolute():
        raise ValueError("evidence receipt requires a relative path")
    expected = (
        record_path.parent
        / "review-evidence"
        / str(record.get("review_head"))
        / "run.json"
    )
    candidate = record_path.parent / raw_path
    path = candidate.resolve()
    components = (
        record_path.parent,
        expected.parent.parent,
        expected.parent,
        candidate,
    )
    if (
        path != expected.resolve()
        or any(item.is_symlink() for item in components)
        or not path.is_file()
    ):
        raise ValueError(
            "evidence receipt is missing or outside the exact-HEAD evidence directory"
        )
    return path


def _load_receipt(record, record_path):
    path = _receipt_path(record, record_path)
    expected_sha = (record.get("evidence_receipt") or {}).get("sha256")
    if (
        not re.fullmatch(r"[0-9a-f]{64}", str(expected_sha or ""))
        or _sha256(path) != expected_sha
    ):
        raise ValueError("evidence receipt sha256 mismatch")
    return json.loads(path.read_text())


def _receipt_errors(record, record_path):
    try:
        receipt = _load_receipt(record, Path(record_path))
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        return [str(exc)]
    errors = []
    if receipt.get("schema") != 1:
        errors.append("evidence receipt has an unsupported schema")
    if receipt.get("review_base") != record.get("review_base") or receipt.get(
        "review_head"
    ) != record.get("review_head"):
        errors.append("evidence receipt reviewed a different range")
    producer = receipt.get("producer") or {}
    if (
        producer.get("kind") != "fixed-review-producer"
        or producer.get("sha256") != _sha256(PRODUCER)
        or any(
            not re.fullmatch(r"[0-9a-f]{64}", str(producer.get(name) or ""))
            for name in (
                "config_sha256",
                "sandbox_profile_sha256",
                "codex_sha256",
                "claude_sha256",
                "git_sha256",
                "zsh_sha256",
                "auth_sha256",
                "output_sha256",
            )
        )
    ):
        errors.append("evidence receipt lacks controlled producer provenance")
    output_path = (
        Path(record_path).parent
        / "review-evidence"
        / str(record.get("review_head"))
        / "producer.json"
    )
    if (
        output_path.is_symlink()
        or not output_path.is_file()
        or _sha256(output_path) != producer.get("output_sha256")
    ):
        errors.append("evidence receipt producer output is missing or modified")
    if tuple(receipt.get("write_policy") or ()) != WRITE_POLICY:
        errors.append("evidence receipt write policy is not the narrow review policy")
    for name in (
        "config",
        "writes",
        "preamble",
        "passes",
        "raw_findings",
        "findings",
        "runtime_errors",
    ):
        if receipt.get(name) != record.get(name):
            errors.append(f"evidence receipt does not match record {name}")
    return errors


def _fixed_producer(record_path):
    if PRODUCER.is_symlink() or not PRODUCER.is_file():
        raise ValueError("fixed review producer is missing or symlinked")
    env = {
        "HOME": _trusted_home(),
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PYTHONNOUSERSITE": "1",
    }
    if os.environ.get("SYMPHONY_BASE_BRANCH"):
        env["SYMPHONY_BASE_BRANCH"] = os.environ["SYMPHONY_BASE_BRANCH"]
    result = subprocess.run(
        [sys.executable, PRODUCER, record_path],
        capture_output=True,
        text=True,
        timeout=1600,
        env=env,
    )
    if result.returncode != 0:
        raise ValueError(f"fixed review producer failed: {result.stdout.strip()}")
    return json.loads(result.stdout), result.stdout


def _capture(record_path):
    record_path = _workspace_record(record_path)
    record = json.loads(record_path.read_text())
    if _run(["git", "rev-parse", "--show-toplevel"]) != str(Path.cwd().resolve()):
        raise ValueError("git is not bound to the assigned workspace")
    head = _run(["git", "rev-parse", "HEAD"])
    base_ref = f"upstream/{os.environ.get('SYMPHONY_BASE_BRANCH', 'main')}"
    base = _run(["git", "merge-base", base_ref, head])
    if record.get("review_head") != head or record.get("review_base") != base:
        raise ValueError(
            "capture range does not match current HEAD and upstream merge-base"
        )
    if _run(["git", "status", "--porcelain"]):
        raise ValueError("capture requires a clean worktree")
    output, raw_output = _fixed_producer(record_path)
    producer = output.get("producer") or {}
    if producer.get("kind") != "fixed-review-producer" or producer.get(
        "sha256"
    ) != _sha256(PRODUCER):
        raise ValueError("review output did not come from the fixed producer")
    if tuple(output.get("write_policy") or ()) != WRITE_POLICY:
        raise ValueError("fixed producer did not enforce the narrow write policy")
    if _run(["git", "rev-parse", "HEAD"]) != head or _run(
        ["git", "status", "--porcelain"]
    ):
        raise ValueError("HEAD or worktree changed during fixed review")
    receipt = {
        "schema": 1,
        "review_base": base,
        "review_head": head,
        "producer": producer,
        "write_policy": list(WRITE_POLICY),
        **{
            name: output.get(name, [] if name not in {"config", "preamble"} else {})
            for name in (
                "config",
                "writes",
                "preamble",
                "passes",
                "raw_findings",
                "findings",
                "runtime_errors",
            )
        },
    }
    evidence_dir = record_path.parent / "review-evidence" / head
    if (
        record_path.parent.is_symlink()
        or (record_path.parent / "review-evidence").is_symlink()
    ):
        raise ValueError("review evidence directory may not traverse symlinks")
    evidence_dir.mkdir(parents=True, exist_ok=True)
    if evidence_dir.is_symlink():
        raise ValueError("review evidence directory may not traverse symlinks")
    output_path = evidence_dir / "producer.json"
    if output_path.is_symlink():
        raise ValueError("review producer output may not be a symlink")
    _safe_write(output_path, raw_output)
    receipt["producer"]["output_sha256"] = _sha256(output_path)
    receipt_path = evidence_dir / "run.json"
    _safe_write(receipt_path, json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    record.update(
        {
            name: receipt[name]
            for name in (
                "config",
                "writes",
                "preamble",
                "passes",
                "raw_findings",
                "findings",
                "runtime_errors",
            )
        }
    )
    record["evidence_receipt"] = {
        "path": str(receipt_path.relative_to(record_path.parent)),
        "sha256": _sha256(receipt_path),
    }
    _safe_write(record_path, json.dumps(record, indent=2, sort_keys=True) + "\n")
    return receipt


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
    if disposition in {"validated", "downgraded"} and finding.get("final_severity") in {
        "P0",
        "P1",
    }:
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
        state = review.get("state")
        if state not in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
            continue
        if author and (author not in latest or submitted >= latest[author][0]):
            latest[author] = (submitted, state)
    return sorted(
        author for author, (_, state) in latest.items() if state == "CHANGES_REQUESTED"
    )


def _feedback_ids(pr):
    ids = {
        f"review:{review['id']}"
        for review in pr.get("reviews") or []
        if _text(review.get("body")) and review.get("id")
    }
    ids.update(
        f"comment:{item['id']}"
        for item in pr.get("comments") or []
        if _text(item.get("body")) and item.get("id")
    )
    ids.update(
        f"inline:{item['id']}"
        for item in pr.get("_inline") or []
        if _text(item.get("body")) and item.get("id")
    )
    return ids


def _check_feedback_dispositions(pr, record, errors):
    dispositions = record.get("pr_feedback_dispositions") or []
    by_id = {}
    for item in dispositions:
        item_id = item.get("id")
        if not _text(item_id) or item_id in by_id:
            errors.append("PR feedback dispositions require unique non-empty ids")
            continue
        by_id[item_id] = item
        if item.get("disposition") not in {
            "addressed",
            "dismissed",
            "superseded",
        } or not _text(item.get("evidence")):
            errors.append(f"PR feedback disposition lacks evidence: {item_id}")
    if set(by_id) != _feedback_ids(pr):
        errors.append("PR feedback dispositions do not match current feedback ids")


def _check_pr(pr, record, errors):
    if pr.get("url") != record.get("pr_url"):
        errors.append("canonical PR URL does not match review record")
    if pr.get("baseRefName") != record.get("pr_base_branch"):
        errors.append("PR base branch does not match review record")
    if pr.get("baseRefOid") != record.get("review_base"):
        errors.append("PR base commit does not match review base")
    if pr.get("state") != "OPEN":
        errors.append("PR is not open")
    change_request_authors = _change_request_authors(pr)
    if pr.get("reviewDecision") == "CHANGES_REQUESTED" or change_request_authors:
        errors.append(
            f"PR has unresolved change requests: {', '.join(change_request_authors) or 'reviewDecision'}"
        )
    _check_feedback_dispositions(pr, record, errors)
    checks = pr.get("statusCheckRollup") or []
    if not checks:
        errors.append("PR status checks are empty")
    for check in checks:
        conclusion = check.get("conclusion") or check.get("state")
        status = check.get("status")
        if status and status != "COMPLETED":
            errors.append(
                f"PR check is not complete: {check.get('name') or check.get('context')}"
            )
        if conclusion not in {"SUCCESS", "SKIPPED", "NEUTRAL"}:
            errors.append(
                f"PR check is not successful: {check.get('name') or check.get('context')}"
            )


def _check_final_snapshot(
    pr, final_pr, feedback_digest, final_feedback_digest, record, errors
):
    _check_pr(final_pr, record, errors)
    if final_pr.get("headRefOid") != pr.get("headRefOid"):
        errors.append("PR head changed during gate verification")
    if final_feedback_digest != feedback_digest:
        errors.append("PR feedback changed during gate verification")


def _flatten_pages(value):
    return (
        [item for page in value for item in page]
        if value and isinstance(value[0], list)
        else value
    )


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

    preamble = record.get("preamble") or {}
    preamble_provenance = preamble.get("provenance") or {}
    preamble_helpers = preamble.get("helper_sha256") or {}
    if (
        preamble.get("name") != "gstack-review-preamble"
        or preamble.get("status") != "completed"
        or preamble.get("review_head") != head
        or not _text(preamble.get("evidence"))
        or not re.fullmatch(r"[0-9a-f]{64}", str(preamble.get("skill_sha256") or ""))
        or set(preamble_helpers)
        != {
            "gstack-update-check",
            "gstack-config",
            "gstack-repo-mode",
            "gstack-slug",
            "gstack-timeline-log",
        }
        or any(
            not re.fullmatch(r"[0-9a-f]{64}", str(value or ""))
            for value in preamble_helpers.values()
        )
        or not _text(preamble_provenance.get("session_id"))
        or not isinstance(preamble_provenance.get("argv"), list)
        or not preamble_provenance.get("argv")
        or preamble_provenance.get("exit_code") != 0
        or type(preamble_provenance.get("started_ns")) is not int
        or type(preamble_provenance.get("completed_ns")) is not int
        or preamble_provenance.get("completed_ns", 0)
        < preamble_provenance.get("started_ns", 0)
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(preamble_provenance.get("output_sha256") or "")
        )
    ):
        errors.append("mandatory gstack review preamble lacks controlled evidence")

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
        provenance = item.get("provenance") or {}
        if (
            not _text(provenance.get("session_id"))
            or not isinstance(provenance.get("argv"), list)
            or not provenance.get("argv")
            or provenance.get("exit_code") != 0
            or type(provenance.get("started_ns")) is not int
            or type(provenance.get("completed_ns")) is not int
            or provenance.get("completed_ns", 0) < provenance.get("started_ns", 0)
            or not re.fullmatch(
                r"[0-9a-f]{64}", str(provenance.get("output_sha256") or "")
            )
            or not re.fullmatch(
                r"[0-9a-f]{64}", str(provenance.get("checklist_sha256") or "")
            )
        ):
            errors.append(f"required pass {name} lacks fixed producer provenance")
        if item.get("review_base") != base or item.get("review_head") != head:
            errors.append(f"required pass {name} reviewed a different range")

    raw_findings = record.get("raw_findings") or []
    raw_ids = [finding.get("id") for finding in raw_findings]
    final_findings = record.get("findings") or []
    final_ids = [finding.get("raw_finding_id") for finding in final_findings]
    if any(not _text(finding_id) for finding_id in raw_ids) or len(raw_ids) != len(
        set(raw_ids)
    ):
        errors.append("raw findings require unique non-empty ids")
    if any(not _text(finding_id) for finding_id in final_ids) or len(final_ids) != len(
        set(final_ids)
    ):
        errors.append("final findings require unique raw_finding_id values")
    if set(raw_ids) != set(final_ids):
        errors.append("every raw finding requires exactly one final disposition")
    for number, finding in enumerate(final_findings, start=1):
        _validate_finding(finding, number, errors)
    return errors


def _run(command):
    name = command[0]
    if name not in {"git", "gh"}:
        raise ValueError(f"gate refuses untrusted command: {name}")
    command = [_trusted_tool(name), *command[1:]]
    env = {
        "HOME": _trusted_home(),
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    if name == "git":
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        command = [command[0], "-C", str(Path.cwd().resolve()), *command[1:]]
    else:
        for variable in ("GH_TOKEN", "GITHUB_TOKEN"):
            if os.environ.get(variable):
                env[variable] = os.environ[variable]
    return subprocess.run(
        command, capture_output=True, text=True, check=True, env=env
    ).stdout.strip()


def _pr_identity(pr_url):
    parsed = urlparse(pr_url)
    parts = parsed.path.strip("/").split("/")
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or len(parts) != 4
        or parts[2] != "pull"
        or not parts[3].isdigit()
    ):
        raise ValueError("review record lacks a canonical PR URL")
    return parsed.hostname.lower(), "/".join(parts[:2]), parts[3]


def _remote_identity(remote):
    if remote.startswith("git@"):
        authority, path = remote.split(":", 1)
        host = authority.split("@", 1)[1]
    else:
        parsed = urlparse(remote)
        host, path = parsed.hostname, parsed.path
    parts = path.removesuffix(".git").strip("/").split("/")
    return (host.lower(), "/".join(parts[-2:])) if host and len(parts) >= 2 else None


def _github_snapshot(record):
    pr_url = record.get("pr_url")
    if not _text(pr_url):
        raise ValueError("review record lacks canonical PR URL")
    host, repo, pr_number = _pr_identity(pr_url)
    allowed_targets = {
        identity
        for remote in ("origin", "upstream")
        if (identity := _remote_identity(_run(["git", "remote", "get-url", remote])))
    }
    if (host, repo) not in allowed_targets:
        raise ValueError("canonical PR URL does not match origin or upstream")
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
                "headRefOid,baseRefName,baseRefOid,state,url,reviewDecision,statusCheckRollup,reviews,comments",
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
    feedback_digest = _feedback_digest(pr, inline)
    pr["_inline"] = inline
    return pr, feedback_digest


def main(argv):
    if len(argv) == 3 and argv[1] == "--capture":
        try:
            receipt = _capture(Path(argv[2]))
        except (
            OSError,
            ValueError,
            TypeError,
            json.JSONDecodeError,
            subprocess.SubprocessError,
        ) as exc:
            print(json.dumps({"verdict": "non-clean", "errors": [str(exc)]}, indent=2))
            return 1
        print(
            json.dumps(
                {"captured": receipt["review_head"], "verdict": "recorded"}, indent=2
            )
        )
        return 0
    if len(argv) not in {2, 3} or (
        len(argv) == 3 and argv[1] not in {"--plan", "--snapshot"}
    ):
        print(
            "usage: review_gate.py [--plan|--snapshot] RECORD.json\n"
            "       review_gate.py --capture RECORD.json",
            file=sys.stderr,
        )
        return 2
    try:
        record_path = Path(argv[-1])
        record = json.loads(record_path.read_text())
        if len(argv) == 3 and argv[1] == "--plan":
            passes, errors = required_passes(record)
            print(
                json.dumps(
                    {"passes": passes, "errors": errors}, indent=2, sort_keys=True
                )
            )
            return 0 if not errors else 1
        trusted_home = _trusted_home()
        if os.path.realpath(os.environ.get("HOME", "")) != trusted_home:
            raise ValueError("HOME does not match the current OS account")
        if _run(["git", "rev-parse", "--show-toplevel"]) != str(Path.cwd().resolve()):
            raise ValueError("git is not bound to the assigned workspace")
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
                        "pr_feedback_ids": sorted(_feedback_ids(pr)),
                        "pr_head": pr.get("headRefOid"),
                        "pr_url": pr.get("url"),
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
            return 0
        receipt_errors = _receipt_errors(record, record_path)
        if receipt_errors:
            raise ValueError("; ".join(receipt_errors))
        receipt = _load_receipt(record, record_path)
        record.update(
            {
                name: receipt[name]
                for name in (
                    "config",
                    "writes",
                    "preamble",
                    "passes",
                    "raw_findings",
                    "findings",
                )
            }
        )
        status = _run(["git", "status", "--porcelain"])
        record["current_head"] = head
        record["pr_head"] = pr.get("headRefOid")
        record["pr_base_branch"] = base_branch
        record["worktree_clean"] = status == ""
        runtime_errors = list(record.get("runtime_errors") or [])
        record["runtime_errors"] = runtime_errors
        if record.get("review_base") != actual_base:
            runtime_errors.append(
                f"review base does not match merge-base of {base_ref}"
            )
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
    except (
        KeyError,
        OSError,
        ValueError,
        TypeError,
        subprocess.SubprocessError,
    ) as exc:
        errors = [f"invalid review record: {exc}"]
        record = {}
    print(
        json.dumps(
            {
                "verdict": "clean" if not errors else "non-clean",
                "handoff_actions": (
                    ["publish_implementation_artifact", "move_human_review"]
                    if not errors
                    else []
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
