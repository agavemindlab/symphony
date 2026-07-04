import json
import shlex
import shutil
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import maestro_replay


def case(identifier: str, artifact: str, *, phase: str = "Design", label: str = "approve") -> dict:
    return {
        "issue_identifier": identifier,
        "issue_url": f"https://linear.app/grandline/issue/{identifier}",
        "phase": phase,
        "artifact_comment_id": artifact,
        "published_at": "2026-06-15T10:00:00Z",
        "label": label,
        "disposition_event_id": None,
        "disposition_at": None,
        "needs_clarification": False,
    }


def prediction(identifier: str, artifact: str, predicted: str, **overrides) -> dict:
    return {**case(identifier, artifact), **overrides, "prediction": predicted, "raw_tail": "", "duration_s": 1.0}


class ParseRecommendationTest(unittest.TestCase):
    def test_tolerates_markdown_decoration_and_case(self) -> None:
        self.assertEqual(maestro_replay.parse_recommendation("**RECOMMENDATION: Approve**"), "approve")
        self.assertEqual(maestro_replay.parse_recommendation("> `recommendation: request_changes`"), "request changes")
        self.assertEqual(maestro_replay.parse_recommendation("- RECOMMENDATION: Merge Nudge（置信 8/10）"), "merge nudge")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION：no reply yet"), "no reply yet")
        self.assertEqual(maestro_replay.parse_recommendation("recommendation: completion-confirmation"), "completion confirmation")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: ask clarification"), "ask clarification")

    def test_last_recommendation_line_wins(self) -> None:
        output = "RECOMMENDATION: approve\nsome analysis\nRECOMMENDATION: request changes\ntrailing note"
        self.assertEqual(maestro_replay.parse_recommendation(output), "request changes")

    def test_unparsable_output_is_unparsed(self) -> None:
        self.assertEqual(maestro_replay.parse_recommendation("no verdict here"), "unparsed")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: 略"), "unparsed")
        self.assertEqual(maestro_replay.parse_recommendation(""), "unparsed")


class SelectCasesTest(unittest.TestCase):
    CASES = [
        case("DEV-3", "ccc"),
        case("DEV-1", "aaa"),
        case("DEV-4", "ddd", phase="Implementation", label="request_changes"),
        case("DEV-2", "bbb", label="auto_advanced"),
        case("DEV-5", "eee", label="pending"),
    ]

    def test_sampling_is_deterministic_by_stable_case_id_sort(self) -> None:
        labels = {"approve", "request_changes"}
        first = maestro_replay.select_cases(self.CASES, labels=labels, sample=2)
        second = maestro_replay.select_cases(list(reversed(self.CASES)), labels=labels, sample=2)

        self.assertEqual([c["artifact_comment_id"] for c in first], ["aaa", "ccc"])
        self.assertEqual(first, second)

    def test_filters_by_labels_and_phase(self) -> None:
        selected = maestro_replay.select_cases(self.CASES, labels={"approve", "request_changes"}, phase="Implementation")
        self.assertEqual([c["artifact_comment_id"] for c in selected], ["ddd"])

        auto_only = maestro_replay.select_cases(self.CASES, labels={"auto_advanced"})
        self.assertEqual([c["artifact_comment_id"] for c in auto_only], ["bbb"])


class ScoreTest(unittest.TestCase):
    def test_scoring_math_confusion_and_disagreements(self) -> None:
        cases = [
            case("DEV-1", "a1"),
            case("DEV-2", "a2", label="request_changes"),
            case("DEV-3", "a3", phase="Implementation"),
            case("DEV-4", "a4", label="auto_advanced"),
        ]
        predictions = [
            prediction("DEV-1", "a1", "approve"),
            prediction("DEV-2", "a2", "approve"),
            prediction("DEV-3", "a3", "timeout"),
            prediction("DEV-4", "a4", "approve"),
            prediction("DEV-9", "unknown-case", "approve"),
        ]

        result = maestro_replay.score_predictions(cases, predictions)

        self.assertEqual(result["overall"], {"total": 3, "agreed": 1, "disagreed": 2, "agreement_rate": 0.3333})
        self.assertEqual(result["by_phase"]["Design"], {"total": 2, "agreed": 1, "disagreed": 1, "agreement_rate": 0.5})
        self.assertEqual(result["by_phase"]["Implementation"]["agreement_rate"], 0.0)
        self.assertEqual(result["by_label"]["approve"], {"total": 2, "agreed": 1, "disagreed": 1, "agreement_rate": 0.5})
        self.assertEqual(result["by_label"]["request_changes"]["agreed"], 0)
        self.assertEqual(result["confusion"], {"approve": {"approve": 1, "timeout": 1}, "request_changes": {"approve": 1}})
        self.assertEqual(result["excluded"], 2)
        self.assertEqual(
            [(item["issue_identifier"], item["prediction"]) for item in result["disagreements"]],
            [("DEV-2", "approve"), ("DEV-3", "timeout")],
        )

    def test_render_report_lists_tables_and_disagreements(self) -> None:
        cases = [case("DEV-1", "a1"), case("DEV-2", "a2", label="request_changes")]
        predictions = [prediction("DEV-1", "a1", "approve"), prediction("DEV-2", "a2", "approve")]

        report = maestro_replay.render_report(maestro_replay.score_predictions(cases, predictions))

        self.assertIn("# Maestro Reviewer Replay Report", report)
        self.assertIn("2 scored prediction(s); 0 excluded", report)
        self.assertIn("| all cases | 2 | 1 | 1 | 50.0% |", report)
        self.assertIn("| Design | 2 | 1 | 1 | 50.0% |", report)
        self.assertIn("| approve | 1 | 1 | 0 | 100.0% |", report)
        self.assertIn("| Label \\ Prediction | approve |", report)
        self.assertIn("| request_changes | 1 |", report)
        self.assertIn("- DEV-2 — Design: label request_changes, predicted approve (artifact a2)", report)

    def test_empty_report_has_na_rate(self) -> None:
        report = maestro_replay.render_report(maestro_replay.score_predictions([], []))
        self.assertIn("| all cases | 0 | 0 | 0 | n/a |", report)
        self.assertIn("No scored predictions.", report)
        self.assertIn("None.", report)


class ReplayCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        root = Path.cwd() / ".symphony" / "maestro-replay-tests"
        root.mkdir(parents=True, exist_ok=True)
        self.tmp = root / self.id().rsplit(".", 1)[-1]
        if self.tmp.exists():
            shutil.rmtree(self.tmp)
        self.tmp.mkdir()

        self.cases_path = self.tmp / "cases.jsonl"
        self.cases_path.write_text(
            "".join(
                json.dumps(entry) + "\n"
                for entry in [
                    case("DEV-1", "a1"),
                    case("DEV-2", "a2", label="request_changes"),
                    case("DEV-3", "a3", label="pending"),
                ]
            ),
        )
        self.reviewer_prompt = self.tmp / "maestro-reviewer.md"
        self.reviewer_prompt.write_text("# Maestro Reviewer\n\nBe strict.\n")
        self.output_dir = self.tmp / "replay"
        self.calls_log = self.tmp / "calls.log"

    def tearDown(self) -> None:
        if self.tmp.exists():
            shutil.rmtree(self.tmp)

    def fake_codex(self, body: str) -> str:
        script = self.tmp / "fake_codex.py"
        script.write_text(body)
        return f"{shlex.quote(sys.executable)} {shlex.quote(str(script))}"

    def run_replay(self, codex_cmd: str, *extra: str) -> int:
        return maestro_replay.main(
            [
                "replay",
                "--cases",
                str(self.cases_path),
                "--output",
                str(self.output_dir),
                "--codex-cmd",
                codex_cmd,
                "--reviewer-prompt",
                str(self.reviewer_prompt),
                *extra,
            ],
        )

    def read_predictions(self) -> list[dict]:
        return maestro_replay.read_jsonl(self.output_dir / "predictions.jsonl")

    def test_replay_writes_predictions_and_composes_the_prompt(self) -> None:
        codex_cmd = self.fake_codex(
            "import sys, pathlib\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "prompt = sys.stdin.read()\n"
            "log.open('a').write(prompt + '\\n===\\n')\n"
            "print('analysis...')\n"
            "print('**RECOMMENDATION: Request Changes**')\n",
        )

        self.assertEqual(self.run_replay(codex_cmd, "--concurrency", "1"), 0)

        predictions = self.read_predictions()
        self.assertEqual(len(predictions), 2)
        by_id = {p["artifact_comment_id"]: p for p in predictions}
        self.assertEqual(set(by_id), {"a1", "a2"})
        self.assertEqual(by_id["a1"]["prediction"], "request changes")
        self.assertEqual(by_id["a1"]["issue_identifier"], "DEV-1")
        self.assertEqual(by_id["a1"]["label"], "approve")
        self.assertIn("RECOMMENDATION", by_id["a1"]["raw_tail"])
        self.assertIsInstance(by_id["a1"]["duration_s"], float)

        prompts = self.calls_log.read_text()
        self.assertIn("Be strict.", prompts)
        self.assertIn("回放评审 DEV-1 的 artifact a1（发布于 2026-06-15T10:00:00Z）", prompts)
        self.assertIn("时间旅行纪律：只考虑 createdAt <= 2026-06-15T10:00:00Z 的 Linear 评论", prompts)
        self.assertIn("不得写入任何东西", prompts)
        self.assertIn("`RECOMMENDATION: <approve|request changes|ask clarification|merge nudge|completion confirmation|no reply yet>`", prompts)

    def test_rerun_resumes_by_skipping_already_predicted_cases(self) -> None:
        codex_cmd = self.fake_codex(
            "import sys, pathlib\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "sys.stdin.read()\n"
            "log.open('a').write('call\\n')\n"
            "print('RECOMMENDATION: approve')\n",
        )

        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 1)
        self.assertEqual([p["artifact_comment_id"] for p in self.read_predictions()], ["a1"])

        # An interrupted append leaves a partial line; the rerun tolerates it.
        with (self.output_dir / "predictions.jsonl").open("a") as handle:
            handle.write('{"artifact_comment_id": "trunc')

        self.assertEqual(self.run_replay(codex_cmd), 0)
        predictions = self.read_predictions()
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 2)
        self.assertEqual({p["artifact_comment_id"] for p in predictions}, {"a1", "a2"})

        self.assertEqual(self.run_replay(codex_cmd), 0)
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 2)

    def test_timeout_is_classified_as_timeout(self) -> None:
        result = maestro_replay.run_case(
            case("DEV-1", "a1"),
            codex_argv=[sys.executable, "-c", "import time; time.sleep(30)"],
            prompt="prompt",
            timeout_s=0.5,
        )
        self.assertEqual(result["prediction"], "timeout")
        self.assertEqual(result["artifact_comment_id"], "a1")
        self.assertGreaterEqual(result["duration_s"], 0.5)

    def test_score_command_writes_report(self) -> None:
        predictions_path = self.tmp / "predictions.jsonl"
        predictions_path.write_text(
            json.dumps(prediction("DEV-1", "a1", "approve")) + "\n" + json.dumps(prediction("DEV-2", "a2", "approve")) + "\n",
        )

        exit_code = maestro_replay.main(
            ["score", "--cases", str(self.cases_path), "--predictions", str(predictions_path)],
        )

        self.assertEqual(exit_code, 0)
        report = (self.tmp / "report.md").read_text()
        self.assertIn("| all cases | 2 | 1 | 1 | 50.0% |", report)
        self.assertIn("- DEV-2 — Design: label request_changes, predicted approve (artifact a2)", report)

    def test_missing_cases_file_fails_cleanly(self) -> None:
        exit_code = maestro_replay.main(
            ["replay", "--cases", str(self.tmp / "missing.jsonl"), "--output", str(self.output_dir), "--reviewer-prompt", str(self.reviewer_prompt)],
        )
        self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()


class ScoreDedupTest(unittest.TestCase):
    def test_duplicate_predictions_for_one_case_count_once_last_wins(self):
        cases = [
            {
                "artifact_comment_id": "c1",
                "issue_identifier": "X-1",
                "phase": "Design",
                "label": "approve",
            }
        ]
        predictions = [
            {"artifact_comment_id": "c1", "prediction": "request changes"},
            {"artifact_comment_id": "c1", "prediction": "approve"},
        ]
        result = maestro_replay.score_predictions(cases, predictions)
        self.assertEqual(result["overall"]["total"], 1)
        self.assertEqual(result["overall"]["agreed"], 1)
