#!/usr/bin/env python3
"""Replay labeled review cases against the maestro-reviewer prompt and score them.

`replay` runs one non-interactive codex session per case (`codex exec
--sandbox read-only`, prompt on stdin) with the full maestro-reviewer prompt
plus a time-travel preamble, and appends predictions incrementally so an
interrupted run keeps partial results and a rerun resumes. `score` compares
predictions against the human labels from `mix symphony.eval.reviews`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
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
    return str(case.get("artifact_comment_id") or "")


def select_cases(
    cases: list[dict],
    *,
    labels: set[str],
    phase: str | None = None,
    sample: int | None = None,
) -> list[dict]:
    """Deterministic selection: filter, then stable-sort by case id, then head."""
    selected = [case for case in cases if case.get("label") in labels]
    if phase:
        selected = [case for case in selected if case.get("phase") == phase]
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
        "忽略之后发生的一切。不得写入任何东西。最后两行输出且仅输出："
        "`CONFIDENCE: <0-10>`（你的置信分）与 "
        "`RECOMMENDATION: <approve|request changes|ask clarification|merge nudge|"
        "completion confirmation|no reply yet>`"
    )
    return reviewer_prompt.rstrip() + "\n\n" + preamble + "\n"


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


def run_case(case: dict, *, codex_argv: list[str], prompt: str, timeout_s: float) -> dict:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            codex_argv,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
        output = completed.stdout + ("\n" + completed.stderr if completed.stderr else "")
        prediction = parse_recommendation(output)
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


def replay(args: argparse.Namespace) -> int:
    reviewer_prompt_path = Path(args.reviewer_prompt) if args.reviewer_prompt else default_reviewer_prompt_path()
    if not reviewer_prompt_path.is_file():
        raise ReplayError(f"Missing reviewer prompt: {reviewer_prompt_path}")
    reviewer_prompt = reviewer_prompt_path.read_text()

    labels = {label.strip() for label in args.labels.split(",") if label.strip()}
    cases = select_cases(read_jsonl(Path(args.cases)), labels=labels, phase=args.phase, sample=args.sample)

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
            prompt=compose_prompt(reviewer_prompt, case),
            timeout_s=args.timeout,
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


def default_reviewer_prompt_path() -> Path:
    return Path(__file__).resolve().parents[4] / REVIEWER_PROMPT_RELPATH


def empty_stats() -> dict:
    return {"total": 0, "agreed": 0, "disagreed": 0}


def finish_stats(stats: dict) -> dict:
    decided = stats["agreed"] + stats["disagreed"]
    stats["agreement_rate"] = round(stats["agreed"] / decided, 4) if decided else None
    return stats


def score_predictions(cases: list[dict], predictions: list[dict]) -> dict:
    """Pure scoring: agreement overall/by-phase/by-label, confusion, disagreements.

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
        label = case.get("label")
        if label not in SCOREABLE_LABELS:
            excluded += 1
            continue
        phase = case.get("phase") or "unknown"
        predicted = prediction.get("prediction") or "unparsed"
        agreed = predicted == SCOREABLE_LABELS[label]

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


def render_report(result: dict) -> str:
    return "\n".join(
        [
            "# Maestro Reviewer Replay Report",
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
    result = score_predictions(read_jsonl(Path(args.cases)), read_jsonl(predictions_path))
    report_path = Path(args.report) if args.report else predictions_path.parent / "report.md"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(render_report(result))
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

    score_parser = subparsers.add_parser("score", help="Score predictions against labels.")
    score_parser.add_argument("--cases", required=True)
    score_parser.add_argument("--predictions", required=True)
    score_parser.add_argument("--report", help="Report path (default: <predictions dir>/report.md)")
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
