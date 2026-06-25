#!/usr/bin/env python3
"""Capture and replay local Symphony artifact-eval cases."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
MISSING_CONTEXT_EXIT = 2
MAX_UNTRACKED_BYTES = 1024 * 1024
SYMPHONY_ALLOWLIST = (
    ".symphony/workpad.md",
    ".symphony/design.md",
    ".symphony/stop-after-turn",
)
WORKFLOW_FILES = (
    "workflows/agavemindlab/WORKFLOW.md",
    "workflows/agavemindlab/skills/phase-{phase}/SKILL.md",
)


class CaseError(RuntimeError):
    """Raised when an eval case is malformed or cannot be replayed."""


@dataclass(frozen=True)
class ReplayResult:
    status: str
    report_path: Path
    draft_path: Path | None
    workspace_path: Path | None


def json_dumps(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True) + "\n"


def run(args: list[str], cwd: Path) -> str:
    completed = subprocess.run(
        args,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise CaseError(completed.stderr.strip() or completed.stdout.strip())
    return completed.stdout


def safe_relative(value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise CaseError(f"Unsafe case path: {value}")
    return path


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise CaseError(f"Invalid JSON: {path}") from exc


def write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json_dumps(data))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_case(case_dir: Path) -> dict[str, Any]:
    case_path = case_dir / "case.json"
    if not case_path.is_file():
        raise CaseError("Missing required file: case.json")
    data = read_json(case_path)
    if data.get("schema_version") != SCHEMA_VERSION:
        raise CaseError(f"Unsupported schema_version: {data.get('schema_version')}")
    return data


def case_file(case_dir: Path, value: str) -> Path:
    relpath = safe_relative(value)
    return case_dir / relpath


def require_case_file(case_dir: Path, value: str) -> None:
    path = case_file(case_dir, value)
    if not path.is_file():
        raise CaseError(f"Missing required file: {value}")


def validate_case(case_dir: Path) -> dict[str, Any]:
    data = load_case(case_dir)
    repo = data.get("repo") or {}
    linear = data.get("linear") or {}
    workflow = data.get("workflow") or {}
    symphony = data.get("symphony") or {}

    for key in ("source_url", "phase"):
        if not data.get(key):
            raise CaseError(f"Missing required field: {key}")

    base_sha = repo.get("base_sha")
    if not base_sha:
        raise CaseError("Missing required field: repo.base_sha")

    require_case_file(case_dir, "repo/base_sha.txt")
    if (case_dir / "repo" / "base_sha.txt").read_text().strip() != base_sha:
        raise CaseError("repo/base_sha does not match repo/base_sha.txt")

    for value in (
        linear.get("issue"),
        linear.get("artifact_thread"),
        repo.get("patch"),
        repo.get("untracked_manifest"),
        workflow.get("current_hashes"),
    ):
        if not isinstance(value, str):
            raise CaseError("Missing required case file reference")
        require_case_file(case_dir, value)

    for value in symphony.get("allowlist", []):
        if not isinstance(value, str):
            raise CaseError("Invalid symphony allowlist entry")
        require_case_file(case_dir, value)

    read_untracked_manifest(case_dir, repo.get("untracked_manifest"))
    return data


def read_untracked_manifest(case_dir: Path, manifest_path: str) -> list[dict[str, str]]:
    manifest = read_json(case_file(case_dir, manifest_path))
    files = manifest.get("files", [])
    if not isinstance(files, list):
        raise CaseError("repo.untracked_manifest files must be a list")
    result: list[dict[str, str]] = []
    for item in files:
        if not isinstance(item, dict):
            raise CaseError("Invalid untracked manifest entry")
        relpath = item.get("path")
        source = item.get("source")
        if not isinstance(relpath, str) or not isinstance(source, str):
            raise CaseError("Invalid untracked manifest entry")
        safe_relative(relpath)
        require_case_file(case_dir, source)
        result.append({"path": relpath, "source": source})
    return result


def missing_context(data: dict[str, Any]) -> list[str]:
    missing: list[str] = []
    for item in data.get("required_context", []):
        if not isinstance(item, dict):
            missing.append("invalid required_context entry")
            continue
        if item.get("captured") is True:
            continue
        kind = item.get("kind", "unknown")
        path = item.get("path") or item.get("name") or "unknown"
        missing.append(f"{kind}: {path}")
    return missing


def ensure_unique_dir(base: Path) -> Path:
    if not base.exists():
        return base
    for index in range(2, 1000):
        candidate = base.with_name(f"{base.name}-{index}")
        if not candidate.exists():
            return candidate
    raise CaseError(f"Could not allocate replay workspace below {base.parent}")


def current_workflow_hashes(repo_root: Path, phase: str) -> list[dict[str, str]]:
    normalized_phase = phase.lower().replace(" ", "-")
    files = []
    for template in WORKFLOW_FILES:
        relpath = template.format(phase=normalized_phase)
        path = repo_root / relpath
        if path.is_file():
            files.append({"path": relpath, "sha256": sha256_file(path)})
    return files


def write_missing_context_report(case_dir: Path, missing: list[str]) -> ReplayResult:
    replay_dir = case_dir / "replay"
    replay_dir.mkdir(parents=True, exist_ok=True)
    report_path = replay_dir / "report.md"
    report_path.write_text(
        "\n".join(
            [
                "# Artifact Eval Replay Report",
                "",
                "Status: MISSING_CONTEXT",
                "",
                "Replay stopped before creating a workspace.",
                "",
                "Missing context:",
                *[f"- {item}" for item in missing],
                "",
            ],
        ),
    )
    return ReplayResult(
        status="MISSING_CONTEXT",
        report_path=report_path,
        draft_path=None,
        workspace_path=None,
    )


def replay_case(case_dir: Path, repo_root: Path, replay_root: Path | None = None) -> ReplayResult:
    case_dir = case_dir.resolve()
    repo_root = repo_root.resolve()
    data = validate_case(case_dir)
    missing = missing_context(data)
    if missing:
        return write_missing_context_report(case_dir, missing)

    replay_root = (replay_root or repo_root / ".symphony" / "artifact-eval" / "replay").resolve()
    workspace_path = ensure_unique_dir(replay_root / case_dir.name)
    base_sha = str(data["repo"]["base_sha"])
    run(["git", "cat-file", "-e", f"{base_sha}^{{commit}}"], cwd=repo_root)
    replay_root.mkdir(parents=True, exist_ok=True)
    run(["git", "clone", "--no-checkout", "--no-hardlinks", str(repo_root), str(workspace_path)], cwd=repo_root)
    run(["git", "checkout", "--detach", base_sha], cwd=workspace_path)

    patch_path = case_file(case_dir, data["repo"]["patch"])
    if patch_path.stat().st_size:
        run(["git", "apply", "--whitespace=nowarn", str(patch_path)], cwd=workspace_path)

    for item in read_untracked_manifest(case_dir, data["repo"]["untracked_manifest"]):
        destination = workspace_path / safe_relative(item["path"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(case_file(case_dir, item["source"]), destination)

    for item in data.get("symphony", {}).get("allowlist", []):
        relpath = safe_relative(item)
        if relpath.parts and relpath.parts[0] == "symphony":
            target_rel = Path(*relpath.parts[1:])
        else:
            target_rel = relpath
        destination = workspace_path / ".symphony" / target_rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(case_file(case_dir, item), destination)

    replay_dir = case_dir / "replay"
    replay_dir.mkdir(parents=True, exist_ok=True)
    current_hashes = current_workflow_hashes(repo_root, str(data["phase"]))
    draft_path = replay_dir / "artifact-draft.md"
    draft_path.write_text(
        "\n".join(
            [
                f"## {data['phase']} Draft",
                "",
                f"Source: {data['source_url']}",
                "",
                "This deterministic draft proves replay uses the current workspace prompts.",
                "",
                "Current workflow inputs:",
                *[f"- `{item['path']}` `{item['sha256']}`" for item in current_hashes],
                "",
            ],
        ),
    )
    report_path = replay_dir / "report.md"
    report_path.write_text(
        "\n".join(
            [
                "# Artifact Eval Replay Report",
                "",
                "Status: PASS",
                "",
                f"Workspace: `{workspace_path}`",
                f"Base SHA: `{base_sha}`",
                f"Patch: `{data['repo']['patch']}`",
                "",
                "Current workflow inputs:",
                *[f"- `{item['path']}` `{item['sha256']}`" for item in current_hashes],
                "",
                f"Draft: `{draft_path}`",
                "",
            ],
        ),
    )
    return ReplayResult(
        status="PASS",
        report_path=report_path,
        draft_path=draft_path,
        workspace_path=workspace_path,
    )


def should_capture_untracked(path: Path) -> bool:
    parts = path.parts
    if not parts:
        return False
    if parts[0] in {".git", ".symphony", ".issue-secrets"}:
        return False
    if path.name == ".env" or path.name.endswith(".env.local"):
        return False
    if path.is_symlink():
        return False
    if not path.is_file():
        return False
    return path.stat().st_size <= MAX_UNTRACKED_BYTES


def capture_case(url: str, linear_json: Path, output_dir: Path, repo_root: Path, phase: str | None) -> Path:
    snapshot = read_json(linear_json)
    issue = snapshot.get("issue")
    artifact_thread = snapshot.get("artifact_thread")
    if not isinstance(issue, dict) or not isinstance(artifact_thread, dict):
        raise CaseError("linear_json must contain issue and artifact_thread objects")

    output_dir.mkdir(parents=True, exist_ok=False)
    (output_dir / "linear").mkdir()
    (output_dir / "repo" / "untracked").mkdir(parents=True)
    (output_dir / "symphony").mkdir()
    (output_dir / "workflow").mkdir()

    write_json(output_dir / "linear" / "issue.json", issue)
    write_json(output_dir / "linear" / "artifact_thread.json", artifact_thread)

    base_sha = run(["git", "rev-parse", "HEAD"], cwd=repo_root).strip()
    (output_dir / "repo" / "base_sha.txt").write_text(f"{base_sha}\n")
    patch = run(["git", "diff", "--binary", "HEAD", "--"], cwd=repo_root)
    (output_dir / "repo" / "workspace.patch").write_text(patch)

    untracked_output = run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=repo_root,
    )
    manifest_files = []
    for raw in untracked_output.split("\0"):
        if not raw:
            continue
        relpath = safe_relative(raw)
        source_path = repo_root / relpath
        if not should_capture_untracked(source_path):
            continue
        target = output_dir / "repo" / "untracked" / relpath
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, target)
        manifest_files.append(
            {
                "path": str(relpath),
                "source": str(Path("repo") / "untracked" / relpath),
            },
        )
    write_json(output_dir / "repo" / "untracked_manifest.json", {"files": manifest_files})

    symphony_files = []
    for relpath in SYMPHONY_ALLOWLIST:
        source = repo_root / relpath
        if not source.is_file():
            continue
        target_rel = Path("symphony") / Path(relpath).relative_to(".symphony")
        target = output_dir / target_rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        symphony_files.append(str(target_rel))

    inferred_phase = phase or infer_phase(artifact_thread.get("body", ""))
    hashes = current_workflow_hashes(repo_root, inferred_phase)
    write_json(output_dir / "workflow" / "hashes.json", {"files": hashes})
    write_json(
        output_dir / "case.json",
        {
            "schema_version": SCHEMA_VERSION,
            "source_url": url,
            "captured_at": datetime.now(UTC).isoformat(),
            "phase": inferred_phase,
            "repo": {
                "base_sha": base_sha,
                "patch": "repo/workspace.patch",
                "untracked_manifest": "repo/untracked_manifest.json",
            },
            "linear": {
                "issue": "linear/issue.json",
                "artifact_thread": "linear/artifact_thread.json",
            },
            "symphony": {"allowlist": symphony_files},
            "workflow": {"current_hashes": "workflow/hashes.json"},
            "required_context": snapshot.get("required_context", []),
        },
    )
    validate_case(output_dir)
    return output_dir


def infer_phase(body: object) -> str:
    text = body if isinstance(body, str) else ""
    for phase in ("Requirements", "Design", "Implementation", "Deployment"):
        if f"## {phase}" in text:
            return phase
    return "unknown"


def materialize_fixture(source: Path, destination: Path, repo_root: Path) -> Path:
    if destination.exists():
        destination = ensure_unique_dir(destination)
    shutil.copytree(source, destination)
    base_sha = run(["git", "rev-parse", "HEAD"], cwd=repo_root).strip()
    for path in destination.rglob("*"):
        if path.is_file():
            text = path.read_text()
            if "__CURRENT_HEAD__" in text:
                path.write_text(text.replace("__CURRENT_HEAD__", base_sha))
    return destination


def verify_fixtures(repo_root: Path) -> int:
    skill_root = Path(__file__).resolve().parents[1]
    fixtures = skill_root / "fixtures"
    minimal = fixtures / "minimal-case"
    missing = fixtures / "missing-context-case"
    linear_snapshot = fixtures / "linear-snapshot.json"
    if not minimal.is_dir() or not missing.is_dir() or not linear_snapshot.is_file():
        raise CaseError("Missing fixture cases")

    run_root = repo_root / ".symphony" / "artifact-eval" / "fixture-runs"
    run_root.mkdir(parents=True, exist_ok=True)
    captured_case = capture_case(
        "https://linear.app/grandline/issue/DEV-5387/fixture#comment-capture",
        linear_snapshot,
        ensure_unique_dir(run_root / "captured-case"),
        repo_root,
        "Design",
    )
    minimal_case = materialize_fixture(minimal, run_root / "minimal-case", repo_root)
    missing_case = materialize_fixture(missing, run_root / "missing-context-case", repo_root)
    broken_case = materialize_fixture(minimal, run_root / "broken-case", repo_root)
    broken_index = read_json(broken_case / "case.json")
    del broken_index["linear"]["issue"]
    write_json(broken_case / "case.json", broken_index)

    validate_case(captured_case)
    validate_case(minimal_case)
    broken_rejected = False
    try:
        validate_case(broken_case)
    except CaseError:
        broken_rejected = True
    minimal_result = replay_case(
        minimal_case,
        repo_root=repo_root,
        replay_root=run_root / "replays",
    )
    missing_result = replay_case(
        missing_case,
        repo_root=repo_root,
        replay_root=run_root / "replays",
    )
    if minimal_result.status != "PASS":
        print(f"minimal-case: {minimal_result.status}", file=sys.stderr)
        return 1
    if missing_result.status != "MISSING_CONTEXT":
        print(f"missing-context-case: {missing_result.status}", file=sys.stderr)
        return 1
    if not broken_rejected:
        print("broken-case: accepted invalid case", file=sys.stderr)
        return 1
    print(f"captured-case: PASS ({captured_case})")
    print(f"minimal-case: PASS ({minimal_result.report_path})")
    print(f"missing-context-case: MISSING_CONTEXT ({missing_result.report_path})")
    print("broken-case: INVALID_CASE")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Capture and replay artifact eval cases.")
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Repository root. Defaults to the current directory.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture = subparsers.add_parser("capture", help="Create a case from read-only Linear JSON.")
    capture.add_argument("url")
    capture.add_argument("--linear-json", required=True, type=Path)
    capture.add_argument("--output", required=True, type=Path)
    capture.add_argument("--phase")

    replay = subparsers.add_parser("replay", help="Replay a captured case.")
    replay.add_argument("case", type=Path)
    replay.add_argument("--replay-root", type=Path)

    subparsers.add_parser("verify-fixtures", help="Run bundled fixture checks.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo_root = Path(args.repo_root).resolve()
    try:
        if args.command == "capture":
            case_dir = capture_case(
                args.url,
                args.linear_json,
                args.output,
                repo_root,
                args.phase,
            )
            print(case_dir)
            return 0
        if args.command == "replay":
            result = replay_case(args.case, repo_root=repo_root, replay_root=args.replay_root)
            print(result.report_path)
            return MISSING_CONTEXT_EXIT if result.status == "MISSING_CONTEXT" else 0
        if args.command == "verify-fixtures":
            return verify_fixtures(repo_root)
    except CaseError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    raise CaseError(f"Unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
