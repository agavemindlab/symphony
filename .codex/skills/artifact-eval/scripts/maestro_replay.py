#!/usr/bin/env python3
"""Replay labeled review and routing cases against their prompts and score them.

`replay` runs one non-interactive codex session per case (`codex exec
--sandbox read-only`, prompt on stdin) with the full maestro-reviewer prompt
plus a time-travel preamble, and appends predictions incrementally so an
interrupted run keeps partial results and a rerun resumes. `routing-replay`
does the same for Main Flow steps 3-5 target-phase routing cases from
`mix symphony.eval.routing`, prompting with the WORKFLOW.md "Phase Map" +
"Main Flow" excerpt and parsing a final `TARGET_PHASE:` line. `score`
compares predictions against the labels (`--field expected_phase` scores
routing predictions against the ground-truth target phase).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DEFAULT_CODEX_CMD = "codex exec --sandbox read-only"
DEFAULT_OUTPUT_DIR = "eval/reviews/replay"
DEFAULT_LABELS = "approve,request_changes"
DEFAULT_CONCURRENCY = 2
DEFAULT_TIMEOUT_S = 600.0
RAW_TAIL_CHARS = 2000
SCOREABLE_LABELS = {"approve": "approve", "request_changes": "request changes"}
# Longest markers first so "request changes" is not shadowed by a bare "approve".
RECOMMENDATIONS = (
    "completion confirmation",
    "ask clarification",
    "request changes",
    "merge nudge",
    "no reply yet",
    "approve",
)
REVIEWER_PROMPT_RELPATH = Path(".codex/skills/maestro/agents/maestro-reviewer.md")
RECOMMENDATION_LINE_RE = re.compile(r"recommendation\s*[:：]\s*(.+)", re.IGNORECASE)
CONFIDENCE_LINE_RE = re.compile(r"confidence\s*[:：]\s*(\d+(?:\.\d+)?)", re.IGNORECASE)
DEFAULT_ROUTING_OUTPUT_DIR = "eval/routing/replay"
PHASES = ("Requirements", "Design", "Implementation", "Deployment")
WORKFLOW_RELPATH = Path("workflows/agavemindlab/WORKFLOW.md")
ROUTING_EXCERPT_START = "## Phase Map"
ROUTING_EXCERPT_END = "## Skill Interaction Protocol"
TARGET_PHASE_LINE_RE = re.compile(r"target[ _]?phase\s*[:：]\s*(.+)", re.IGNORECASE)


class ReplayError(RuntimeError):
    """Raised when replay inputs are missing or malformed."""


def read_jsonl(path: Path) -> list[dict]:
    """Reads JSONL records; malformed lines (e.g. an interrupted append) are skipped."""
    if not path.is_file():
        raise ReplayError(f"Missing file: {path}")
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def case_id(case: dict) -> str:
    """Review cases are keyed by artifact, routing cases by their publish event."""
    return str(case.get("artifact_comment_id") or case.get("published_event_id") or "")


def select_cases(
    cases: list[dict],
    *,
    labels: set[str] | None = None,
    phase: str | None = None,
    sample: int | None = None,
    phase_field: str = "phase",
) -> list[dict]:
    """Deterministic selection: filter, then stable-sort by case id, then head."""
    selected = [case for case in cases if labels is None or case.get("label") in labels]
    if phase:
        selected = [case for case in selected if case.get(phase_field) == phase]
    selected = sorted(selected, key=case_id)
    if sample is not None:
        selected = selected[:sample]
    return selected


def compose_prompt(reviewer_prompt: str, case: dict) -> str:
    issue = case.get("issue_identifier") or "unknown"
    artifact = case.get("artifact_comment_id") or "unknown"
    published_at = case.get("published_at") or "unknown"
    preamble = (
        f"回放评审 {issue} 的 artifact {artifact}（发布于 {published_at}）。"
        f"时间旅行纪律：只考虑 createdAt <= {published_at} 的 Linear 评论与当时已存在的 PR 状态；"
        "忽略之后发生的一切。不得写入任何东西。"
        "禁止读取任何本地日志或会话记录（elixir/log、.symphony、.codex/sessions、~/.codex 等）——"
        "那里可能包含事后信息；只允许 linear / gh 只读工具与 Linear/GitHub 内容本身。"
        "最后两行输出且仅输出："
        "`CONFIDENCE: <0-10>`（你的置信分）与 "
        "`RECOMMENDATION: <approve|request changes|ask clarification|merge nudge|"
        "completion confirmation|no reply yet>`"
    )
    return reviewer_prompt.rstrip() + "\n\n" + preamble + "\n"


def routing_excerpt(workflow_text: str) -> str:
    """The WORKFLOW.md "Phase Map" + "Main Flow" sections, verbatim."""
    start = workflow_text.find(ROUTING_EXCERPT_START)
    end = workflow_text.find(ROUTING_EXCERPT_END, start + 1) if start != -1 else -1
    if start == -1 or end == -1:
        raise ReplayError(
            f"Workflow prompt is missing the {ROUTING_EXCERPT_START!r}..{ROUTING_EXCERPT_END!r} routing sections",
        )
    return workflow_text[start:end].rstrip()


def compose_routing_prompt(workflow_excerpt: str, case: dict) -> str:
    issue = case.get("issue_identifier") or "unknown"
    dispatch_at = case.get("dispatch_at") or "unknown"
    state = case.get("state") or "unknown"
    preamble = (
        f"回放路由决策：issue {issue} 在 {dispatch_at} 以状态 {state} 被派发。"
        f"时间旅行纪律：只考虑 createdAt <= {dispatch_at} 的 Linear 评论。"
        "只做步骤 3-5 的路由判断，不执行任何阶段工作、不写入任何东西。"
        "禁止读取任何本地日志或会话记录（elixir/log、.symphony、.codex/sessions、~/.codex 等）——"
        "那里包含派发之后的事后信息；只允许 linear / gh 只读工具。"
        "最后一行输出且仅输出 `TARGET_PHASE: <Requirements|Design|Implementation|Deployment>`"
    )
    return workflow_excerpt.rstrip() + "\n\n" + preamble + "\n"


def parse_target_phase(output: str) -> str:
    """Parse the LAST `TARGET_PHASE:` line, tolerating markdown decoration."""
    for line in reversed(output.splitlines()):
        match = TARGET_PHASE_LINE_RE.search(line)
        if not match:
            continue
        value = match.group(1).lower()
        for phase in PHASES:
            if phase.lower() in value:
                return phase
        return "unparsed"
    return "unparsed"


def parse_confidence(output: str):
    """Parse the LAST `CONFIDENCE:` line; None when absent or unparseable."""
    for line in reversed(output.splitlines()):
        match = CONFIDENCE_LINE_RE.search(line)
        if match:
            try:
                return float(match.group(1))
            except ValueError:
                return None
    return None


def parse_recommendation(output: str) -> str:
    """Parse the LAST `RECOMMENDATION:` line, tolerating markdown decoration."""
    for line in reversed(output.splitlines()):
        match = RECOMMENDATION_LINE_RE.search(line)
        if not match:
            continue
        normalized = re.sub(r"[_/-]", " ", match.group(1).lower())
        normalized = re.sub(r"[^a-z ]", " ", normalized)
        normalized = " ".join(normalized.split())
        for recommendation in RECOMMENDATIONS:
            if recommendation in normalized:
                return recommendation
        return "unparsed"
    return "unparsed"


def _as_text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    if isinstance(value, str):
        return value
    return ""


_REPLAY_WORKDIR: list[str] = []


def _replay_workdir() -> str:
    """Empty scratch cwd for replay sessions: relative repo/log paths must not
    resolve — post-hoc engine logs contain the answers (anti-leakage)."""
    if not _REPLAY_WORKDIR:
        _REPLAY_WORKDIR.append(tempfile.mkdtemp(prefix="maestro-replay-cwd-"))
    return _REPLAY_WORKDIR[0]


def run_case(case: dict, *, codex_argv: list[str], prompt: str, timeout_s: float, parse_prediction=parse_recommendation) -> dict:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            codex_argv,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
            cwd=_replay_workdir(),
        )
        output = completed.stdout + ("\n" + completed.stderr if completed.stderr else "")
        prediction = parse_prediction(output)
    except subprocess.TimeoutExpired as exc:
        output = _as_text(exc.stdout) + _as_text(exc.stderr)
        prediction = "timeout"
    duration_s = round(time.monotonic() - started, 1)
    return {
        **case,
        "prediction": prediction,
        "confidence": parse_confidence(output),
        "raw_tail": output[-RAW_TAIL_CHARS:],
        "duration_s": duration_s,
    }


def load_done_ids(predictions_path: Path) -> set[str]:
    if not predictions_path.is_file():
        return set()
    return {case_id(record) for record in read_jsonl(predictions_path)}


def ensure_trailing_newline(path: Path) -> None:
    """Seal a partial line left by an interrupted run so appends stay parseable."""
    if not path.is_file() or not path.stat().st_size:
        return
    with path.open("rb+") as handle:
        handle.seek(-1, os.SEEK_END)
        if handle.read(1) != b"\n":
            handle.write(b"\n")


def execute_replay(cases: list[dict], *, args: argparse.Namespace, prompt_fn, parse_prediction) -> int:
    """Shared run/resume plumbing: one codex session per not-yet-predicted case."""
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    predictions_path = output_dir / "predictions.jsonl"
    ensure_trailing_newline(predictions_path)
    done = load_done_ids(predictions_path)
    todo = [case for case in cases if case_id(case) not in done]
    skipped = len(cases) - len(todo)

    codex_argv = shlex.split(args.codex_cmd)
    write_lock = threading.Lock()

    def run_and_record(case: dict) -> str:
        prediction = run_case(
            case,
            codex_argv=codex_argv,
            prompt=prompt_fn(case),
            timeout_s=args.timeout,
            parse_prediction=parse_prediction,
        )
        with write_lock, predictions_path.open("a") as handle:
            handle.write(json.dumps(prediction, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        return prediction["prediction"]

    with ThreadPoolExecutor(max_workers=max(args.concurrency, 1)) as executor:
        predictions = list(executor.map(run_and_record, todo))

    print(
        f"Replayed {len(predictions)} case(s) ({skipped} already present, resumed) "
        f"-> {predictions_path}",
    )
    return 0


def replay(args: argparse.Namespace) -> int:
    reviewer_prompt_path = Path(args.reviewer_prompt) if args.reviewer_prompt else default_reviewer_prompt_path()
    if not reviewer_prompt_path.is_file():
        raise ReplayError(f"Missing reviewer prompt: {reviewer_prompt_path}")
    reviewer_prompt = reviewer_prompt_path.read_text()

    labels = {label.strip() for label in args.labels.split(",") if label.strip()}
    cases = select_cases(read_jsonl(Path(args.cases)), labels=labels, phase=args.phase, sample=args.sample)
    return execute_replay(
        cases,
        args=args,
        prompt_fn=lambda case: compose_prompt(reviewer_prompt, case),
        parse_prediction=parse_recommendation,
    )


def routing_replay(args: argparse.Namespace) -> int:
    workflow_path = Path(args.workflow) if args.workflow else default_workflow_path()
    if not workflow_path.is_file():
        raise ReplayError(f"Missing workflow prompt: {workflow_path}")
    excerpt = routing_excerpt(workflow_path.read_text())

    cases = select_cases(read_jsonl(Path(args.cases)), phase=args.phase, sample=args.sample, phase_field="expected_phase")
    return execute_replay(
        cases,
        args=args,
        prompt_fn=lambda case: compose_routing_prompt(excerpt, case),
        parse_prediction=parse_target_phase,
    )


def default_reviewer_prompt_path() -> Path:
    return Path(__file__).resolve().parents[4] / REVIEWER_PROMPT_RELPATH


def default_workflow_path() -> Path:
    return Path(__file__).resolve().parents[4] / WORKFLOW_RELPATH


def empty_stats() -> dict:
    return {"total": 0, "agreed": 0, "disagreed": 0}


def finish_stats(stats: dict) -> dict:
    decided = stats["agreed"] + stats["disagreed"]
    stats["agreement_rate"] = round(stats["agreed"] / decided, 4) if decided else None
    return stats


def review_expected(case: dict) -> str | None:
    label = case.get("label")
    return SCOREABLE_LABELS.get(label) if isinstance(label, str) else None


def score_predictions(
    cases: list[dict],
    predictions: list[dict],
    *,
    expected_fn=review_expected,
    label_fn=lambda case: case.get("label"),
    phase_fn=lambda case: case.get("phase") or "unknown",
) -> dict:
    """Pure scoring: agreement overall/by-phase/by-label, confusion, disagreements.

    `expected_fn` maps a case to its expected prediction string (None excludes
    the case); `label_fn`/`phase_fn` pick the grouping keys — the defaults are
    the review-eval shape, routing scoring passes expected/state/expected-phase.
    Predictions are deduplicated by case id (last occurrence wins): concurrent
    replay processes appending to one file must not double-count a case.
    """
    label_by_id = {case_id(case): case for case in cases if case_id(case)}
    predictions = list({case_id(p): p for p in predictions}.values())
    overall = empty_stats()
    by_phase: dict[str, dict] = {}
    by_label: dict[str, dict] = {}
    confusion: dict[str, dict[str, int]] = {}
    disagreements: list[dict] = []
    excluded = 0

    for prediction in predictions:
        case = label_by_id.get(case_id(prediction))
        if case is None:
            excluded += 1
            continue
        expected = expected_fn(case)
        if expected is None:
            excluded += 1
            continue
        label = label_fn(case)
        phase = phase_fn(case)
        predicted = prediction.get("prediction") or "unparsed"
        agreed = predicted == expected

        for stats in (
            overall,
            by_phase.setdefault(phase, empty_stats()),
            by_label.setdefault(label, empty_stats()),
        ):
            stats["total"] += 1
            stats["agreed" if agreed else "disagreed"] += 1
        confusion.setdefault(label, {})[predicted] = confusion.setdefault(label, {}).get(predicted, 0) + 1
        if not agreed:
            disagreements.append(
                {
                    "issue_identifier": case.get("issue_identifier"),
                    "phase": phase,
                    "label": label,
                    "prediction": predicted,
                    "artifact_comment_id": case_id(case),
                },
            )

    return {
        "overall": finish_stats(overall),
        "by_phase": {phase: finish_stats(stats) for phase, stats in by_phase.items()},
        "by_label": {label: finish_stats(stats) for label, stats in by_label.items()},
        "confusion": confusion,
        "disagreements": disagreements,
        "excluded": excluded,
    }


def format_rate(rate: float | None) -> str:
    return "n/a" if rate is None else f"{round(rate * 100, 1)}%"


def stats_table(header: str, rows: list[tuple[str, dict]]) -> str:
    lines = [
        f"| {header} | Total | Agreed | Disagreed | Agreement rate |",
        "| --- | --- | --- | --- | --- |",
    ]
    for name, stats in rows:
        lines.append(
            f"| {name} | {stats['total']} | {stats['agreed']} | {stats['disagreed']} "
            f"| {format_rate(stats['agreement_rate'])} |",
        )
    return "\n".join(lines)


def confusion_table(confusion: dict[str, dict[str, int]]) -> str:
    if not confusion:
        return "No scored predictions."
    predicted_values = sorted({predicted for row in confusion.values() for predicted in row})
    lines = [
        "| Label \\ Prediction | " + " | ".join(predicted_values) + " |",
        "| --- |" + " --- |" * len(predicted_values),
    ]
    for label in sorted(confusion):
        cells = [str(confusion[label].get(predicted, 0)) for predicted in predicted_values]
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def disagreement_lines(disagreements: list[dict]) -> str:
    if not disagreements:
        return "None."
    return "\n".join(
        f"- {item['issue_identifier'] or 'unknown'} — {item['phase']}: label {item['label']}, "
        f"predicted {item['prediction']} (artifact {item['artifact_comment_id']})"
        for item in disagreements
    )


def render_report(result: dict, *, title: str = "# Maestro Reviewer Replay Report") -> str:
    return "\n".join(
        [
            title,
            "",
            f"{result['overall']['total']} scored prediction(s); {result['excluded']} excluded "
            "(non-scoreable label or unknown case).",
            "",
            "## Overall agreement",
            "",
            stats_table("Scope", [("all cases", result["overall"])]),
            "",
            "## Agreement by phase",
            "",
            stats_table("Phase", sorted(result["by_phase"].items())),
            "",
            "## Agreement by label",
            "",
            stats_table("Label", sorted(result["by_label"].items())),
            "",
            "## Confusion matrix (label × prediction)",
            "",
            confusion_table(result["confusion"]),
            "",
            "## Disagreements",
            "",
            disagreement_lines(result["disagreements"]),
            "",
        ],
    )


def score(args: argparse.Namespace) -> int:
    predictions_path = Path(args.predictions)
    if getattr(args, "field", "label") == "expected_phase":
        scoring = {
            "expected_fn": lambda case: case.get("expected_phase"),
            "label_fn": lambda case: case.get("state") or "unknown",
            "phase_fn": lambda case: case.get("expected_phase") or "unknown",
        }
        title = "# Routing Replay Report"
    else:
        scoring = {}
        title = "# Maestro Reviewer Replay Report"
    result = score_predictions(read_jsonl(Path(args.cases)), read_jsonl(predictions_path), **scoring)
    report_path = Path(args.report) if args.report else predictions_path.parent / "report.md"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(render_report(result, title=title))
    print(
        f"Scored {result['overall']['total']} prediction(s), "
        f"agreement {format_rate(result['overall']['agreement_rate'])} -> {report_path}",
    )
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Replay and score maestro-reviewer predictions.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    replay_parser = subparsers.add_parser("replay", help="Run one codex session per labeled case.")
    replay_parser.add_argument("--cases", required=True, help="cases.jsonl from mix symphony.eval.reviews")
    replay_parser.add_argument("--sample", type=int, help="Replay only the first N cases (stable sort by case id)")
    replay_parser.add_argument("--phase", help="Only replay cases of this phase")
    replay_parser.add_argument("--labels", default=DEFAULT_LABELS, help=f"Comma-separated labels (default: {DEFAULT_LABELS})")
    replay_parser.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY)
    replay_parser.add_argument("--output", default=DEFAULT_OUTPUT_DIR, help=f"Output directory (default: {DEFAULT_OUTPUT_DIR})")
    replay_parser.add_argument("--codex-cmd", default=DEFAULT_CODEX_CMD, help=f"Codex command; prompt is piped on stdin (default: {DEFAULT_CODEX_CMD!r})")
    replay_parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="Per-case timeout in seconds (default: 600)")
    replay_parser.add_argument("--reviewer-prompt", help="Override the maestro-reviewer prompt path (tests)")
    replay_parser.set_defaults(func=replay)

    routing_parser = subparsers.add_parser("routing-replay", help="Run one codex session per labeled routing case.")
    routing_parser.add_argument("--cases", required=True, help="cases.jsonl from mix symphony.eval.routing")
    routing_parser.add_argument("--sample", type=int, help="Replay only the first N cases (stable sort by case id)")
    routing_parser.add_argument("--phase", help="Only replay cases with this expected phase")
    routing_parser.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY)
    routing_parser.add_argument("--output", default=DEFAULT_ROUTING_OUTPUT_DIR, help=f"Output directory (default: {DEFAULT_ROUTING_OUTPUT_DIR})")
    routing_parser.add_argument("--codex-cmd", default=DEFAULT_CODEX_CMD, help=f"Codex command; prompt is piped on stdin (default: {DEFAULT_CODEX_CMD!r})")
    routing_parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="Per-case timeout in seconds (default: 600)")
    routing_parser.add_argument("--workflow", help="Override the WORKFLOW.md path (tests)")
    routing_parser.set_defaults(func=routing_replay)

    score_parser = subparsers.add_parser("score", help="Score predictions against labels.")
    score_parser.add_argument("--cases", required=True)
    score_parser.add_argument("--predictions", required=True)
    score_parser.add_argument("--report", help="Report path (default: <predictions dir>/report.md)")
    score_parser.add_argument("--field", choices=["label", "expected_phase"], default="label", help="Case field holding the expected value: label (reviews) or expected_phase (routing)")
    score_parser.set_defaults(func=score)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return args.func(args)
    except ReplayError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
