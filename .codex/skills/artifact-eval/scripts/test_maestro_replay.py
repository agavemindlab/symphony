import json
import shlex
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


class ReplayFingerprintTest(unittest.TestCase):
    def test_fingerprint_is_canonical_and_covers_every_replay_input(self) -> None:
        original = {
            **case("DEV-1", "a1"),
            "case_context": {"artifact": {"id": "impl-1", "pr_head": "head-1"}},
        }
        reordered = {
            "case_context": {"artifact": {"pr_head": "head-1", "id": "impl-1"}},
            **case("DEV-1", "a1"),
        }
        inputs = {
            "case": original,
            "prompt": "reviewer\ncomposed prompt",
            "child_argv": ["codex", "exec", "--json"],
            "parser_schema_version": "reviewer-v1",
        }
        fingerprint = maestro_replay.replay_fingerprint(**inputs)

        self.assertEqual(
            fingerprint,
            maestro_replay.replay_fingerprint(**{**inputs, "case": reordered}),
        )
        for field, changed in (
            ("case", {**original, "label": "request_changes"}),
            ("prompt", "changed reviewer\ncomposed prompt"),
            ("child_argv", ["codex", "exec", "--strict-config", "--json"]),
            ("parser_schema_version", "reviewer-v2"),
        ):
            with self.subTest(field=field):
                self.assertNotEqual(
                    fingerprint,
                    maestro_replay.replay_fingerprint(**{**inputs, field: changed}),
                )

    def test_fingerprint_changes_when_an_argv_file_changes_in_place(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child = Path(directory) / "child.py"
            child.write_text("print('first')\n")
            inputs = {
                "case": case("DEV-1", "a1"),
                "prompt": "prompt",
                "child_argv": [sys.executable, str(child)],
                "parser_schema_version": "reviewer-v1",
            }
            first = maestro_replay.replay_fingerprint(**inputs)
            child.write_text("print('second')\n")
            self.assertNotEqual(first, maestro_replay.replay_fingerprint(**inputs))

    def test_matching_fingerprints_rejects_a_stale_case_directly_at_score_time(self) -> None:
        original = {
            **case("DEV-1", "a1"),
            "case_context": {"artifact": {"id": "impl-1"}},
        }
        child_argv = [sys.executable]
        prompt_fn = lambda item: json.dumps(item["case_context"], sort_keys=True)
        record = {
            **original,
            "returncode": 0,
            "replay_fingerprint": maestro_replay.replay_fingerprint(
                case=original,
                prompt=prompt_fn(original),
                child_argv=child_argv,
                parser_schema_version="reviewer-v1",
            ),
        }

        self.assertEqual(
            maestro_replay.matching_fingerprint_predictions(
                [original],
                [record],
                prompt_fn=prompt_fn,
                child_argv=child_argv,
                parser_schema_version="reviewer-v1",
            ),
            [record],
        )
        changed = {**original, "case_context": {"artifact": {"id": "impl-2"}}}
        self.assertEqual(
            maestro_replay.matching_fingerprint_predictions(
                [changed],
                [record],
                prompt_fn=prompt_fn,
                child_argv=child_argv,
                parser_schema_version="reviewer-v1",
            ),
            [],
        )

    def test_matching_fingerprints_hashes_the_runtime_once(self) -> None:
        cases = [case("DEV-1", "a1"), case("DEV-2", "a2")]
        with mock.patch.object(
            maestro_replay,
            "replay_runtime_snapshot",
            return_value={"files": {"codex": "hash"}, "version": "codex-cli test"},
        ) as snapshot:
            maestro_replay.matching_fingerprint_predictions(
                cases,
                [],
                prompt_fn=lambda item: item["issue_identifier"],
                child_argv=["codex"],
                parser_schema_version="reviewer-v1",
            )

        snapshot.assert_called_once_with(["codex"])

    def test_runtime_snapshot_streams_files_instead_of_buffering_them(self) -> None:
        with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("buffered read")):
            files = maestro_replay.replay_runtime_files([sys.executable])

        self.assertIn(str(Path(sys.executable).resolve()), files)


class ParseRecommendationTest(unittest.TestCase):
    def test_tolerates_markdown_decoration_and_case(self) -> None:
        self.assertEqual(maestro_replay.parse_recommendation("**RECOMMENDATION: Approve**"), "approve")
        self.assertEqual(maestro_replay.parse_recommendation("> `recommendation: request_changes`"), "request changes")
        self.assertEqual(maestro_replay.parse_recommendation("- RECOMMENDATION: Merge Nudge（置信 8/10）"), "merge nudge")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION：no reply yet"), "no reply yet")
        self.assertEqual(maestro_replay.parse_recommendation("recommendation: completion-confirmation"), "completion confirmation")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: ask clarification"), "ask clarification")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: continue_implementation"), "continue implementation")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: rework-design"), "rework design")

    def test_last_recommendation_line_wins(self) -> None:
        output = "RECOMMENDATION: approve\nsome analysis\nRECOMMENDATION: request changes\ntrailing note"
        self.assertEqual(maestro_replay.parse_recommendation(output), "request changes")

    def test_unparsable_output_is_unparsed(self) -> None:
        self.assertEqual(maestro_replay.parse_recommendation("no verdict here"), "unparsed")
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: 略"), "unparsed")
        self.assertEqual(maestro_replay.parse_recommendation(""), "unparsed")

    def test_rejects_negated_ambiguous_or_non_contract_values(self) -> None:
        self.assertEqual(maestro_replay.parse_recommendation("RECOMMENDATION: not approve"), "unparsed")
        self.assertEqual(
            maestro_replay.parse_recommendation("RECOMMENDATION: approve or request changes"),
            "unparsed",
        )
        self.assertEqual(maestro_replay.parse_recommendation("I think RECOMMENDATION: approve"), "unparsed")

    def test_parses_frozen_reviewer_context(self) -> None:
        self.assertEqual(
            maestro_replay.parse_reviewer_prediction(
                "RECOMMENDATION: rework design\n"
                "CONSUMED_CONTEXT: trend_marker: family-session-persisted, assumption-invalid",
            ),
            {
                "prediction": "rework design",
                "consumed_context": ["family-session-persisted", "assumption-invalid"],
            },
        )

        self.assertEqual(
            maestro_replay.parse_consumed_context("CONSUMED_CONTEXT: marker-a，marker-b"),
            ["marker-a", "marker-b"],
        )

    def test_consumed_context_requires_one_standalone_contract_line(self) -> None:
        self.assertEqual(
            maestro_replay.parse_consumed_context("analysis CONSUMED_CONTEXT: marker-a"),
            [],
        )
        self.assertEqual(
            maestro_replay.parse_consumed_context("not CONSUMED_CONTEXT: marker-a"),
            [],
        )
        self.assertEqual(
            maestro_replay.parse_consumed_context(
                "CONSUMED_CONTEXT: marker-a\nCONSUMED_CONTEXT: marker-b",
            ),
            [],
        )
        self.assertEqual(
            maestro_replay.parse_consumed_context(
                "`CONSUMED_CONTEXT: <comma-separated markers>`\n"
                "CONSUMED_CONTEXT: marker-a",
            ),
            ["marker-a"],
        )

    def test_parses_card_artifact_and_head_binding(self) -> None:
        parsed = maestro_replay.parse_reviewer_prediction(
            "收敛判断: continue implementation\n"
            "建议 target phase: Implementation\n"
            "建议 issue status: In Progress\n"
            "执行状态: awaiting human action\n"
            "Reviewed Implementation artifact id: impl-current\n"
            "PR Head: head-current\n"
            "RECOMMENDATION: continue implementation\n"
            "CONSUMED_CONTEXT: none",
        )

        self.assertEqual(parsed["card_artifact_id"], "impl-current")
        self.assertEqual(parsed["card_pr_head"], "head-current")

    def test_output_markers_require_contract_fields_not_prose_mentions(self) -> None:
        output = "卡片缺少待人工回答的问题和回答判定标准。"
        self.assertFalse(maestro_replay.output_marker_present("待人工回答的问题", output))
        self.assertFalse(maestro_replay.output_marker_present("回答判定标准", output))
        self.assertFalse(maestro_replay.output_marker_present("待人工回答的问题", "缺少 待人工回答的问题: 未提供"))
        self.assertFalse(maestro_replay.output_marker_present("收敛判断", "收敛判断:"))
        self.assertFalse(maestro_replay.output_marker_present("待人工回答的问题", "### 待人工回答的问题: 请选择"))
        self.assertTrue(maestro_replay.output_marker_present("待人工回答的问题", "待人工回答的问题: 请选择"))
        self.assertTrue(
            maestro_replay.output_marker_present(
                "执行状态: awaiting human action",
                "- **执行状态**：awaiting human action",
            ),
        )

        empty_rework = """
        收敛判断: rework design
        失效的 Design assumption:
        建议修改的机制或边界:
        下一轮 proof / acceptance criteria:
        不受影响的既有约束:
        CONSUMED_CONTEXT: assumption-empty,boundary-empty,proof-empty,constraint-empty
        """
        for marker in ("assumption-empty", "boundary-empty", "proof-empty", "constraint-empty"):
            self.assertFalse(maestro_replay.output_marker_present(marker, empty_rework))

        self.assertFalse(
            maestro_replay.output_marker_present(
                "proof-present",
                "下一轮 proof / acceptance criteria:\n- add proof-present coverage\n不受影响的既有约束: constraint-present",
            ),
        )
        self.assertTrue(
            maestro_replay.output_marker_present(
                "proof-present",
                "下一轮 proof / acceptance criteria: add proof-present coverage",
            ),
        )
        self.assertFalse(
            maestro_replay.output_marker_present(
                "下一轮建议方向",
                "下一轮建议方向:\nImplementation artifact id: impl-current\nPR Head: head-current",
            ),
        )

    def test_card_fields_accept_only_exact_plain_single_or_double_emphasis(self) -> None:
        for output in (
            "收敛判断: continue implementation",
            "*收敛判断*: continue implementation",
            "**收敛判断**: continue implementation",
        ):
            with self.subTest(output=output):
                self.assertEqual(
                    maestro_replay.contract_field_content("收敛判断", output),
                    "continue implementation",
                )

        for output in (
            "***收敛判断***: continue implementation",
            r"\*收敛判断\*: continue implementation",
            "**收敛判断*: continue implementation",
            "* 收敛判断 *: continue implementation",
            "收敛判断:",
            "```\n收敛判断: continue implementation\n```",
            "收敛判断: continue implementation\n*收敛判断*: continue implementation",
            "*收敛判断*: continue implementation\n**收敛判断**: continue implementation",
        ):
            with self.subTest(output=output):
                self.assertEqual(maestro_replay.contract_field_content("收敛判断", output), "")

    def test_judgment_card_parser_matches_shared_conformance_corpus(self) -> None:
        path = Path(__file__).resolve().parent.parent / "fixtures" / "judgment-card-parser-cases.jsonl"
        cases = maestro_replay.read_jsonl(path)
        base_fields = {
            "收敛判断": "continue implementation",
            "建议 target phase": "Implementation",
            "建议 issue status": "In Progress",
            "执行状态": "awaiting human action",
            "Implementation artifact id": "impl-current",
            "PR Head": "head-current",
            "判断理由": "finding family 已收敛",
            "下一轮建议方向": "继续修复剩余 finding",
        }
        expected = {
            "card_decision": "continue_implementation",
            "card_target_phase": "Implementation",
            "card_target_status": "In Progress",
            "card_execution_state": "awaiting_human_action",
        }

        for case in cases:
            lines = [
                case["replacement"] if label == case["field"] else f"{label}: {value}"
                for label, value in base_fields.items()
            ]
            parsed = maestro_replay.parse_reviewer_prediction(
                "\n".join(lines)
                + "\nRECOMMENDATION: continue implementation\nCONSUMED_CONTEXT: none",
            )

            with self.subTest(case=case["id"]):
                if case["accepted"]:
                    self.assertEqual({key: parsed.get(key) for key in expected}, expected)
                else:
                    self.assertNotEqual({key: parsed.get(key) for key in expected}, expected)


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

    def test_frozen_cases_do_not_bypass_label_filter(self) -> None:
        frozen = {**case("DEV-6", "fff", label="pending"), "case_context": {}}
        self.assertEqual(maestro_replay.select_cases([frozen], labels={"escalated"}), [])


class FrozenDecisionFixtureTest(unittest.TestCase):
    BASE_MARKERS = {
        "收敛判断",
        "建议 target phase",
        "建议 issue status",
        "执行状态: awaiting human action",
        "判断理由",
        "下一轮建议方向",
        "Implementation artifact id",
        "PR Head",
    }

    def test_covers_three_decisions_and_rework_explanation(self) -> None:
        path = Path(__file__).resolve().parent.parent / "fixtures" / "escalated-decision-cases.jsonl"
        cases = maestro_replay.read_jsonl(path)

        self.assertEqual({case["expected_decision"] for case in cases}, {"continue_implementation", "rework_design", "ask_clarification"})
        self.assertTrue(all(self.BASE_MARKERS <= set(case["required_output_markers"]) for case in cases))
        self.assertTrue(all(case["label"] == "escalated" for case in cases))
        self.assertTrue(all(case["case_context"] and case["required_context_markers"] for case in cases))
        rework = next(case for case in cases if case["expected_decision"] == "rework_design")
        self.assertTrue(
            {
                "失效的 Design assumption",
                "建议修改的机制或边界",
                "下一轮 proof / acceptance criteria",
                "不受影响的既有约束",
                "assumption-session-identity-invalid",
                "boundary-session-ownership",
                "proof-multi-session",
                "constraint-human-gate",
            }
            <= set(rework["required_output_markers"]),
        )
        clarification = next(case for case in cases if case["expected_decision"] == "ask_clarification")
        self.assertTrue(
            {"待人工回答的问题", "回答判定标准"} <= set(clarification["required_output_markers"]),
        )


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

    def test_missing_prediction_counts_as_disagreement(self) -> None:
        cases = [case("DEV-1", "a1"), case("DEV-2", "a2")]

        result = maestro_replay.score_predictions(cases, [prediction("DEV-1", "a1", "approve")])

        self.assertEqual(result["overall"], {"total": 2, "agreed": 1, "disagreed": 1, "agreement_rate": 0.5})
        self.assertEqual(result["confusion"]["approve"], {"approve": 1, "unparsed": 1})

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

    def test_frozen_reviewer_scores_decision_output_and_context_markers(self) -> None:
        frozen = {
            **case("FIXTURE-REWORK", "decision-rework", phase="Implementation", label="escalated"),
            "expected_decision": "rework_design",
            "required_output_markers": ["收敛判断", "失效的 Design assumption", "不受影响的既有约束"],
            "required_context_markers": ["family-session-persisted", "assumption-invalid"],
            "case_context": {},
        }
        predictions = [
            {
                **frozen,
                "prediction": "rework design",
                "observed_output_markers": ["收敛判断", "失效的 Design assumption"],
                "consumed_context": ["family-session-persisted", "assumption-invalid"],
            },
        ]

        result = maestro_replay.score_predictions(
            [frozen],
            predictions,
            expected_fn=maestro_replay.review_expected,
        )

        self.assertEqual(result["overall"], {"total": 1, "agreed": 0, "disagreed": 1, "agreement_rate": 0.0})

    def test_frozen_reviewer_binds_card_to_case_artifact_and_head(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "expected_decision": "continue_implementation",
            "case_context": {"artifact": {"id": "impl-current", "pr_head": "head-current"}},
        }
        base_prediction = {
            **frozen,
            "prediction": "continue implementation",
            "card_decision": "continue_implementation",
            "card_target_phase": "Implementation",
            "card_target_status": "In Progress",
            "card_execution_state": "awaiting_human_action",
            "card_artifact_id": "impl-current",
            "card_pr_head": "head-current",
        }

        for field, wrong_value in (("card_artifact_id", "impl-old"), ("card_pr_head", "head-old")):
            with self.subTest(field=field):
                result = maestro_replay.score_predictions(
                    [frozen],
                    [{**base_prediction, field: wrong_value}],
                )
                self.assertEqual(result["overall"]["disagreed"], 1)

    def test_frozen_reviewer_rejects_duplicate_core_card_fields(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "expected_decision": "continue_implementation",
            "case_context": {"artifact": {"id": "impl-current", "pr_head": "head-current"}},
        }
        output = """
        收敛判断: continue implementation
        建议 target phase: Implementation
        建议 target phase: Design
        建议 issue status: In Progress
        执行状态: awaiting human action
        Reviewed Implementation artifact id: impl-current
        PR Head: head-current
        RECOMMENDATION: continue implementation
        CONSUMED_CONTEXT: none
        """
        parsed = maestro_replay.parse_reviewer_prediction(output)

        result = maestro_replay.score_predictions([frozen], [{**frozen, **parsed}])

        self.assertEqual(result["overall"]["disagreed"], 1)


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
        self.assertIn(
            "`RECOMMENDATION: <approve|request changes|continue implementation|rework design|ask clarification|merge nudge|completion confirmation|no reply yet>`",
            prompts,
        )

    def test_frozen_reviewer_context_is_offline_and_records_contract_markers(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "expected_decision": "continue_implementation",
            "required_output_markers": ["收敛判断", "执行状态: awaiting human action"],
            "required_context_markers": ["family-auth-decreasing"],
            "case_context": {"review_verdict": "ESCALATED", "trend_marker": "family-auth-decreasing"},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        output = (
            "RECOMMENDATION: continue implementation\n"
            "收敛判断: continue implementation\n"
            "执行状态: awaiting human action\n"
            "CONSUMED_CONTEXT: family-auth-decreasing\n"
        )
        completed = maestro_replay.subprocess.CompletedProcess(
            [],
            0,
            stdout=json.dumps(
                {"type": "item.completed", "item": {"type": "agent_message", "text": output}},
            ),
            stderr="",
        )

        with (
            mock.patch.object(maestro_replay, "preflight_strict_replay"),
            mock.patch.object(maestro_replay.subprocess, "run", return_value=completed) as run,
        ):
            self.assertEqual(self.run_replay(maestro_replay.DEFAULT_CODEX_CMD), 0)

        result = self.read_predictions()[0]
        self.assertEqual(result["prediction"], "continue implementation")
        self.assertEqual(result["observed_output_markers"], frozen["required_output_markers"])
        self.assertEqual(result["consumed_context"], frozen["required_context_markers"])
        prompt = run.call_args.kwargs["input"]
        self.assertIn(json.dumps(frozen["case_context"], ensure_ascii=False, indent=2, sort_keys=True), prompt)
        self.assertIn("不得读取当前 Linear 或 GitHub", prompt)
        self.assertIn("每个字段必须各自单独成行", prompt)
        self.assertIn(
            "判断理由: <finding families, trend, attempted-fix effects, remaining Design assumptions>\n"
            "下一轮建议方向: <next direction>",
            prompt,
        )
        self.assertIn(
            "approved_design.assumptions[].marker → 失效的 Design assumption，"
            "proposed_evidence.boundary_marker → 建议修改的机制或边界，"
            "proposed_evidence.proof_marker → 下一轮 proof / acceptance criteria，"
            "approved_design.preserved_constraints[].marker → 不受影响的既有约束。",
            prompt,
        )
        self.assertIn(
            "Reviewed Implementation artifact id: <artifact id>\nPR Head: <head>",
            prompt,
        )
        self.assertIn(
            "ask clarification 还须逐行输出待人工回答的问题、回答判定标准。",
            prompt,
        )
        self.assertIn(
            "逐一使用并原样列出 required_context_markers 的每个值",
            prompt,
        )
        self.assertIn(
            "本 case 的 required_context_markers: family-auth-decreasing",
            prompt,
        )
        self.assertNotIn("OUTPUT_MARKERS", prompt)
        self.assertNotIn("只允许 linear / gh", prompt)
        self.assertEqual(
            maestro_replay.codex_argv_for_case(maestro_replay.DEFAULT_CODEX_CMD, frozen),
            shlex.split(maestro_replay.HERMETIC_CODEX_CMD),
        )
        argv = maestro_replay.codex_argv_for_case(maestro_replay.DEFAULT_CODEX_CMD, frozen)
        self.assertNotIn("--sandbox", argv)
        self.assertNotIn("read-only", argv)
        self.assertIn("--strict-config", argv)
        self.assertIn("--json", argv)
        self.assertIn("--ignore-user-config", argv)
        self.assertIn("--ignore-rules", argv)
        self.assertIn("--ephemeral", argv)
        self.assertEqual(argv[argv.index("--model") + 1], "gpt-5.5")
        self.assertIn('default_permissions="replay"', argv)
        self.assertIn('permissions.replay.filesystem={":minimal"="read"}', argv)
        self.assertIn("permissions.replay.network.enabled=false", argv)
        self.assertNotIn(":root", " ".join(argv))
        self.assertNotIn(":workspace_roots", " ".join(argv))
        self.assertIn('web_search="disabled"', argv)
        self.assertIn("mcp_servers={}", argv)
        self.assertIn('model_reasoning_summary="none"', argv)
        self.assertIn('shell_environment_policy.inherit="none"', argv)

    def test_frozen_replay_rejects_custom_codex_command_before_output(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "case_context": {},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        custom = self.fake_codex("raise AssertionError('must not execute')\n")

        self.assertEqual(self.run_replay(custom), 1)

        self.assertFalse(self.output_dir.exists())

    def test_strict_preflight_precedes_output_creation_and_resume_loading(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "case_context": {},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        events = []

        def load_done(_path):
            events.append("resume")
            return set()

        def reject_preflight(*_args, **_kwargs):
            events.append("preflight")
            raise maestro_replay.ReplayError("strict preflight rejected")

        with (
            mock.patch.object(maestro_replay, "load_done_ids", side_effect=load_done),
            mock.patch.object(maestro_replay.subprocess, "run", side_effect=reject_preflight),
        ):
            self.assertEqual(self.run_replay(maestro_replay.DEFAULT_CODEX_CMD), 1)

        self.assertEqual(events, ["preflight"])
        self.assertFalse(self.output_dir.exists())

    def test_unsupported_strict_config_fails_before_creating_output(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "case_context": {},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        unsupported = maestro_replay.subprocess.CompletedProcess(
            [],
            1,
            stdout="",
            stderr="Error loading config.toml: unknown configuration field",
        )

        with mock.patch.object(maestro_replay.subprocess, "run", return_value=unsupported):
            self.assertEqual(self.run_replay(maestro_replay.DEFAULT_CODEX_CMD), 1)

        self.assertFalse(self.output_dir.exists())

    def test_missing_observed_sandbox_denial_fails_before_creating_output(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "case_context": {},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        refusal = maestro_replay.subprocess.CompletedProcess(
            [],
            0,
            stdout=json.dumps(
                {
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": "I will not read those files."},
                },
            ),
            stderr="",
        )

        with mock.patch.object(maestro_replay.subprocess, "run", return_value=refusal):
            self.assertEqual(self.run_replay(maestro_replay.DEFAULT_CODEX_CMD), 1)

        self.assertFalse(self.output_dir.exists())

    def test_preflight_rejects_sentinel_leak_without_persisting_it(self) -> None:
        frozen = {
            **case("FIXTURE-CONTINUE", "decision-continue", phase="Implementation", label="escalated"),
            "case_context": {},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")

        def leak_sentinel(_argv, **kwargs):
            prompt = kwargs["input"]
            direct_path = next(
                Path(line.removeprefix("DIRECT_PATH: "))
                for line in prompt.splitlines()
                if line.startswith("DIRECT_PATH: ")
            )
            leaked = direct_path.read_text()
            return maestro_replay.subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps(
                    {
                        "type": "item.completed",
                        "item": {
                            "type": "command_execution",
                            "command": f"/bin/cat {direct_path}",
                            "aggregated_output": leaked,
                            "exit_code": 0,
                            "status": "completed",
                        },
                    },
                ),
                stderr="",
            )

        with mock.patch.object(maestro_replay.subprocess, "run", side_effect=leak_sentinel):
            self.assertEqual(self.run_replay(maestro_replay.DEFAULT_CODEX_CMD), 1)

        self.assertFalse(self.output_dir.exists())

    def test_preflight_rejects_manufactured_command_strings(self) -> None:
        def manufactured(_argv, **kwargs):
            fields = dict(
                line.split(": ", 1)
                for line in kwargs["input"].splitlines()
                if ": " in line
            )
            events = []
            for name in ("DIRECT", "SYMLINK"):
                events.append(
                    {
                        "type": "item.completed",
                        "item": {
                            "type": "command_execution",
                            "command": f"echo {fields[name + '_COMMAND']}",
                            "aggregated_output": f"{fields[name + '_PATH']}: Operation not permitted",
                            "exit_code": 1,
                            "status": "failed",
                        },
                    },
                )
            return maestro_replay.subprocess.CompletedProcess(
                [],
                0,
                stdout="\n".join(json.dumps(event) for event in events),
                stderr="",
            )

        with (
            mock.patch.object(maestro_replay.subprocess, "run", side_effect=manufactured),
            self.assertRaises(maestro_replay.ReplayError),
        ):
            maestro_replay.preflight_strict_replay(
                shlex.split(maestro_replay.HERMETIC_CODEX_CMD),
                5,
            )

    def test_preflight_requires_runtime_environment_and_descriptor_proof(self) -> None:
        def filesystem_only(_argv, **kwargs):
            fields = dict(
                line.split(": ", 1)
                for line in kwargs["input"].splitlines()
                if ": " in line
            )
            events = [
                {
                    "type": "item.completed",
                    "item": {
                        "type": "command_execution",
                        "command": fields[name + "_COMMAND"],
                        "aggregated_output": f"{fields[name + '_PATH']}: Operation not permitted",
                        "exit_code": 1,
                        "status": "failed",
                    },
                }
                for name in ("DIRECT", "SYMLINK")
            ]
            return maestro_replay.subprocess.CompletedProcess(
                [],
                0,
                stdout="\n".join(json.dumps(event) for event in events),
                stderr="",
            )

        with (
            mock.patch.object(maestro_replay.subprocess, "run", side_effect=filesystem_only),
            self.assertRaises(maestro_replay.ReplayError),
        ):
            maestro_replay.preflight_strict_replay(
                shlex.split(maestro_replay.HERMETIC_CODEX_CMD),
                5,
            )

    def test_preflight_accepts_exact_commands_and_runtime_proofs(self) -> None:
        def proven(_argv, **kwargs):
            fields = dict(
                line.split(": ", 1)
                for line in kwargs["input"].splitlines()
                if ": " in line
            )
            events = [
                {
                    "type": "item.completed",
                    "item": {
                        "type": "command_execution",
                        "command": fields[name + "_COMMAND"],
                        "aggregated_output": output,
                        "exit_code": exit_code,
                        "status": "completed" if exit_code == 0 else "failed",
                    },
                }
                for name, output, exit_code in (
                    ("DIRECT", f"{fields['DIRECT_PATH']}: Operation not permitted", 1),
                    ("SYMLINK", f"{fields['SYMLINK_PATH']}: Operation not permitted", 1),
                    ("ENVIRONMENT", "PARENT_ENV_ABSENT", 0),
                    ("DESCRIPTOR", "INHERITED_FD_CLOSED:9", 0),
                )
            ]
            return maestro_replay.subprocess.CompletedProcess(
                [],
                0,
                stdout="\n".join(json.dumps(event) for event in events),
                stderr="",
            )

        with mock.patch.object(maestro_replay.subprocess, "run", side_effect=proven):
            maestro_replay.preflight_strict_replay(
                shlex.split(maestro_replay.HERMETIC_CODEX_CMD),
                5,
            )

    def test_child_subprocess_closes_inherited_descriptors(self) -> None:
        completed = maestro_replay.subprocess.CompletedProcess(
            [],
            0,
            stdout="RECOMMENDATION: approve\n",
            stderr="",
        )
        with mock.patch.object(maestro_replay.subprocess, "run", return_value=completed) as run:
            maestro_replay.run_case(
                case("DEV-1", "a1"),
                codex_argv=[sys.executable, "-c", "pass"],
                prompt="prompt",
                timeout_s=5,
            )

        self.assertIs(run.call_args.kwargs["close_fds"], True)

    def test_json_event_stream_parses_the_final_agent_message(self) -> None:
        completed = maestro_replay.subprocess.CompletedProcess(
            [],
            0,
            stdout="\n".join(
                json.dumps(event)
                for event in (
                    {"type": "item.completed", "item": {"type": "agent_message", "text": "Working on it."}},
                    {
                        "type": "item.completed",
                        "item": {"type": "agent_message", "text": "RECOMMENDATION: approve"},
                    },
                    {"type": "turn.completed"},
                )
            ),
            stderr="",
        )
        with mock.patch.object(maestro_replay.subprocess, "run", return_value=completed):
            result = maestro_replay.run_case(
                case("DEV-1", "a1"),
                codex_argv=["codex", "exec", "--json"],
                prompt="prompt",
                timeout_s=5,
            )

        self.assertEqual(result["prediction"], "approve")

    def test_frozen_reviewer_rejects_a_card_that_contradicts_its_audit_recommendation(self) -> None:
        frozen = {
            **case("FIXTURE-REWORK", "decision-rework", phase="Implementation", label="escalated"),
            "expected_decision": "rework_design",
            "required_output_markers": ["收敛判断", "执行状态: awaiting human action"],
        }
        output = """
        收敛判断: ask clarification
        建议 target phase: Implementation
        建议 issue status: unchanged
        执行状态: awaiting human action
        RECOMMENDATION: rework design
        """
        parsed = maestro_replay.parse_reviewer_prediction(output)
        parsed["observed_output_markers"] = [
            marker for marker in frozen["required_output_markers"] if maestro_replay.output_marker_present(marker, output)
        ]

        result = maestro_replay.score_predictions([frozen], [{**frozen, **parsed}])

        self.assertEqual(result["overall"]["disagreed"], 1)

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

    def test_rerun_replays_same_id_when_fingerprint_inputs_change(self) -> None:
        codex_cmd = self.fake_codex(
            "import sys, pathlib\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "sys.stdin.read()\n"
            "log.open('a').write('call\\n')\n"
            "print('RECOMMENDATION: approve')\n",
        )

        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)
        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 1)

        cases = maestro_replay.read_jsonl(self.cases_path)
        cases[0]["needs_clarification"] = True
        self.cases_path.write_text("".join(json.dumps(entry) + "\n" for entry in cases))
        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)

        self.reviewer_prompt.write_text("# Maestro Reviewer\n\nChanged contract.\n")
        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)

        alternate = self.tmp / "alternate_codex.py"
        alternate.write_text((self.tmp / "fake_codex.py").read_text())
        alternate_cmd = f"{shlex.quote(sys.executable)} {shlex.quote(str(alternate))}"
        self.assertEqual(self.run_replay(alternate_cmd, "--sample", "1"), 0)

        with mock.patch.object(maestro_replay, "REVIEW_PARSER_SCHEMA_VERSION", "reviewer-v-next"):
            self.assertEqual(self.run_replay(alternate_cmd, "--sample", "1"), 0)

        predictions = self.read_predictions()
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 5)
        self.assertEqual(len(predictions), 5)
        self.assertEqual(len({record["replay_fingerprint"] for record in predictions}), 5)

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

    def test_nonzero_exit_is_classified_as_error(self) -> None:
        result = maestro_replay.run_case(
            case("DEV-1", "a1"),
            codex_argv=[sys.executable, "-c", "print('RECOMMENDATION: approve'); raise SystemExit(1)"],
            prompt="prompt",
            timeout_s=5,
        )
        self.assertEqual(result["prediction"], "error")
        self.assertEqual(result["returncode"], 1)

    def test_nonzero_child_is_not_completed_or_resumed(self) -> None:
        codex_cmd = self.fake_codex(
            "import pathlib, sys\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "sys.stdin.read()\n"
            "log.open('a').write('call\\n')\n"
            "print('RECOMMENDATION: approve')\n"
            "raise SystemExit(1)\n",
        )

        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)
        self.assertEqual(self.run_replay(codex_cmd, "--sample", "1"), 0)

        self.assertEqual(self.calls_log.read_text().splitlines(), ["call", "call"])
        self.assertFalse((self.output_dir / "predictions.jsonl").exists())

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

    def test_score_command_requires_frozen_reviewer_markers(self) -> None:
        frozen = {
            **case("FIXTURE-REWORK", "decision-rework", phase="Implementation", label="escalated"),
            "expected_decision": "rework_design",
            "required_output_markers": ["收敛判断", "不受影响的既有约束"],
            "required_context_markers": ["family-session-persisted"],
            "case_context": {"artifact": {"id": "decision-rework", "pr_head": "head-current"}},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        reviewer_prompt = maestro_replay.require_text(
            maestro_replay.default_reviewer_prompt_path(),
            "reviewer prompt",
        )
        child_argv = maestro_replay.replay_child_argv(maestro_replay.DEFAULT_CODEX_CMD, [frozen])
        predictions_path = self.tmp / "predictions.jsonl"
        predictions_path.write_text(
            json.dumps(
                {
                    **frozen,
                    "prediction": "rework design",
                    "observed_output_markers": ["收敛判断"],
                    "consumed_context": ["family-session-persisted"],
                    "replay_fingerprint": maestro_replay.replay_fingerprint(
                        case=frozen,
                        prompt=maestro_replay.compose_prompt(reviewer_prompt, frozen),
                        child_argv=child_argv,
                        parser_schema_version=maestro_replay.REVIEW_PARSER_SCHEMA_VERSION,
                    ),
                },
            )
            + "\n",
        )

        self.assertEqual(maestro_replay.main(["score", "--cases", str(self.cases_path), "--predictions", str(predictions_path)]), 0)
        report = (self.tmp / "report.md").read_text()
        self.assertIn("1 scored prediction(s); 0 excluded", report)
        self.assertIn("| all cases | 1 | 0 | 1 | 0.0% |", report)

        record = json.loads(predictions_path.read_text())
        predictions_path.write_text(
            json.dumps(
                {
                    **record,
                    "observed_output_markers": frozen["required_output_markers"],
                    "consumed_context": frozen["required_context_markers"],
                    "card_decision": "rework_design",
                    "card_target_phase": "Design",
                    "card_target_status": "Rework",
                    "card_execution_state": "awaiting_human_action",
                    "card_artifact_id": "decision-rework",
                    "card_pr_head": "head-current",
                    "replay_fingerprint": "stale",
                },
            )
            + "\n",
        )
        self.assertEqual(maestro_replay.main(["score", "--cases", str(self.cases_path), "--predictions", str(predictions_path)]), 0)
        stale_report = (self.tmp / "report.md").read_text()
        self.assertIn("| all cases | 1 | 0 | 1 | 0.0% |", stale_report)
        self.assertIn("predicted unparsed", stale_report)

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


class ParseConfidenceTest(unittest.TestCase):
    def test_parses_last_confidence_line_and_tolerates_absence(self):
        self.assertEqual(
            maestro_replay.parse_confidence("CONFIDENCE: 8\nRECOMMENDATION: approve"), 8.0
        )
        self.assertEqual(
            maestro_replay.parse_confidence("**Confidence：7.5**\nRECOMMENDATION: approve"), 7.5
        )
        self.assertIsNone(maestro_replay.parse_confidence("RECOMMENDATION: approve"))


def routing_case(identifier: str, event_id: str, *, state: str = "In Progress", expected: str = "Design") -> dict:
    return {
        "issue_identifier": identifier,
        "issue_url": f"https://linear.app/grandline/issue/{identifier}",
        "dispatch_at": "2026-06-15T10:00:00Z",
        "state": state,
        "expected_phase": expected,
        "published_event_id": event_id,
    }


def routing_prediction(identifier: str, event_id: str, predicted: str, **overrides) -> dict:
    return {**routing_case(identifier, event_id), **overrides, "prediction": predicted, "raw_tail": "", "duration_s": 1.0}


WORKFLOW_TEXT = (
    "# Workflow\n\npreamble to drop\n\n"
    "## Phase Map\n\nphases table here\n\n"
    "## Main Flow\n\nsteps 1-6 here\n\n"
    "## Skill Interaction Protocol\n\nprotocol to drop\n"
)


class ParseTargetPhaseTest(unittest.TestCase):
    def test_tolerates_markdown_decoration_and_case(self) -> None:
        self.assertEqual(maestro_replay.parse_target_phase("**TARGET_PHASE: Design**"), "Design")
        self.assertEqual(maestro_replay.parse_target_phase("> `target_phase: implementation`"), "Implementation")
        self.assertEqual(maestro_replay.parse_target_phase("TARGET PHASE：Requirements（步骤 5）"), "Requirements")
        self.assertEqual(maestro_replay.parse_target_phase("- TARGET_PHASE: `Deployment`"), "Deployment")
        self.assertEqual(maestro_replay.parse_target_phase("TARGET_PHASE: Human Review"), "Human Review")

    def test_last_target_phase_line_wins(self) -> None:
        output = "TARGET_PHASE: Design\nsome analysis\nTARGET_PHASE: Deployment\ntrailing note"
        self.assertEqual(maestro_replay.parse_target_phase(output), "Deployment")

    def test_unparsable_output_is_unparsed(self) -> None:
        self.assertEqual(maestro_replay.parse_target_phase("no verdict here"), "unparsed")
        self.assertEqual(maestro_replay.parse_target_phase("TARGET_PHASE: 略"), "unparsed")
        self.assertEqual(maestro_replay.parse_target_phase(""), "unparsed")

    def test_rejects_negated_ambiguous_or_non_contract_values(self) -> None:
        self.assertEqual(maestro_replay.parse_target_phase("TARGET_PHASE: not Design"), "unparsed")
        self.assertEqual(maestro_replay.parse_target_phase("TARGET_PHASE: Design or Implementation"), "unparsed")
        self.assertEqual(maestro_replay.parse_target_phase("result TARGET_PHASE: Design"), "unparsed")
        self.assertEqual(
            maestro_replay.parse_consumed_decision("CONSUMED_DECISION: not continue implementation"),
            "unparsed",
        )
        self.assertEqual(
            maestro_replay.parse_consumed_decision("CONSUMED_DECISION: rework design or ask clarification"),
            "unparsed",
        )

    def test_parses_the_frozen_routing_contract(self) -> None:
        self.assertEqual(
            maestro_replay.parse_routing_prediction(
                "TARGET_PHASE: Human Review\nCONSUMED_DECISION: none\nCONSUMED_CONTEXT: none",
            ),
            {"prediction": "Human Review", "consumed_decision": "none", "consumed_context": []},
        )


class RoutingExcerptTest(unittest.TestCase):
    def test_slices_phase_map_through_main_flow(self) -> None:
        excerpt = maestro_replay.routing_excerpt(WORKFLOW_TEXT)
        self.assertTrue(excerpt.startswith("## Phase Map"))
        self.assertIn("## Main Flow", excerpt)
        self.assertIn("steps 1-6 here", excerpt)
        self.assertNotIn("## Skill Interaction Protocol", excerpt)
        self.assertNotIn("preamble to drop", excerpt)

    def test_missing_markers_raise(self) -> None:
        with self.assertRaises(maestro_replay.ReplayError):
            maestro_replay.routing_excerpt("## Phase Map\nno end marker")
        with self.assertRaises(maestro_replay.ReplayError):
            maestro_replay.routing_excerpt("## Skill Interaction Protocol\nno start marker")


class RoutingSelectCasesTest(unittest.TestCase):
    CASES = [
        routing_case("DEV-3", "phase_published:c3"),
        routing_case("DEV-1", "phase_published:c1"),
        routing_case("DEV-2", "phase_published:c2", expected="Implementation"),
    ]

    def test_selects_all_and_filters_by_expected_phase(self) -> None:
        selected = maestro_replay.select_cases(self.CASES, phase_field="expected_phase")
        self.assertEqual([c["published_event_id"] for c in selected], ["phase_published:c1", "phase_published:c2", "phase_published:c3"])

        implementation = maestro_replay.select_cases(self.CASES, phase="Implementation", phase_field="expected_phase")
        self.assertEqual([c["published_event_id"] for c in implementation], ["phase_published:c2"])

    def test_fallback_case_id_includes_dispatch_time(self) -> None:
        first = {"issue_identifier": "DEV-1", "dispatch_at": "2026-01-01T00:00:00Z"}
        second = {"issue_identifier": "DEV-1", "dispatch_at": "2026-01-02T00:00:00Z"}
        self.assertNotEqual(maestro_replay.case_id(first), maestro_replay.case_id(second))


class FrozenRoutingFixtureTest(unittest.TestCase):
    def test_covers_escalated_route_families(self) -> None:
        path = Path(__file__).resolve().parent.parent / "fixtures" / "escalated-routing-cases.jsonl"
        cases = maestro_replay.read_jsonl(path)

        self.assertEqual(len(cases), 23)
        self.assertEqual(len({maestro_replay.case_id(case) for case in cases}), len(cases))
        families = {case["family"] for case in cases}
        self.assertEqual(
            families,
            {
                "continue_status",
                "continue_status_second_user",
                "rework_status",
                "rework_status_second_user",
                "clarification_unanswered",
                "clarification_answered",
                "stale_binding",
                "nonhuman_comment_provenance",
                "unknown_actor",
                "unreadable_history",
                "card_status_mismatch",
                "slash_command_precedence",
                "stale_nonlatest_action",
                "card_wrong_name",
                "card_wrong_id",
                "card_missing_id",
                "card_blank_id",
                "card_wrong_app",
                "card_bot_actor",
                "missing_maestro_actor_config",
                "malformed_card",
                "oauth_app",
                "bot_actor",
            },
        )
        self.assertTrue(all(set(case["case_context"]) == {"artifact", "maestro_card", "state_history", "human_feedback"} for case in cases))

        authenticated = {"id": "maestro-app", "name": "Maestro", "app": True}
        card_provenance_negatives = {
            "card_wrong_name",
            "card_wrong_id",
            "card_missing_id",
            "card_blank_id",
            "card_wrong_app",
            "card_bot_actor",
        }
        for case in cases:
            if case["family"] not in card_provenance_negatives:
                self.assertEqual(case["case_context"]["maestro_card"]["user"], authenticated)
                self.assertIsNone(case["case_context"]["maestro_card"]["botActor"])

        provenance_cases = {
            case["family"]: case
            for case in cases
            if case["family"] in card_provenance_negatives
        }
        self.assertEqual(provenance_cases["card_wrong_name"]["case_context"]["maestro_card"]["user"]["name"], "Other Reviewer")
        self.assertEqual(provenance_cases["card_wrong_id"]["case_context"]["maestro_card"]["user"]["id"], "other-app")
        self.assertNotIn("id", provenance_cases["card_missing_id"]["case_context"]["maestro_card"]["user"])
        self.assertEqual(provenance_cases["card_blank_id"]["case_context"]["maestro_card"]["user"]["id"], " ")
        self.assertFalse(provenance_cases["card_wrong_app"]["case_context"]["maestro_card"]["user"]["app"])
        self.assertIsNotNone(provenance_cases["card_bot_actor"]["case_context"]["maestro_card"]["botActor"])
        self.assertTrue(all(case["expected_phase"] == "Human Review" for case in provenance_cases.values()))

        missing_config = next(case for case in cases if case["family"] == "missing_maestro_actor_config")
        self.assertEqual(missing_config["maestro_actor_id"], "")
        self.assertIn(
            "SYMPHONY_MAESTRO_ACTOR_ID=\n",
            maestro_replay.compose_routing_prompt("## Phase Map\n\n## Main Flow", missing_config),
        )

        accepted_status_cases = [
            case
            for case in cases
            if case["family"]
            in {"continue_status", "continue_status_second_user", "rework_status", "rework_status_second_user"}
        ]
        self.assertEqual(
            {case["case_context"]["state_history"][0]["actor"]["id"] for case in accepted_status_cases},
            {"human-1", "human-2"},
        )
        self.assertEqual(
            {
                (case["expected_decision"], case["expected_phase"])
                for case in accepted_status_cases
            },
            {("continue_implementation", "Implementation"), ("rework_design", "Design")},
        )

        for family in ("clarification_answered", "slash_command_precedence"):
            feedback = next(case for case in cases if case["family"] == family)["case_context"]["human_feedback"]
            self.assertTrue(
                all(
                    item["user"]["id"]
                    and item["user"]["app"] is False
                    and item["botActor"] is None
                    for item in feedback
                ),
            )

        nonhuman_comments = next(case for case in cases if case["family"] == "nonhuman_comment_provenance")
        feedback = nonhuman_comments["case_context"]["human_feedback"]
        self.assertEqual(nonhuman_comments["expected_phase"], "Human Review")
        self.assertEqual(nonhuman_comments["case_context"]["state_history"], [])
        self.assertTrue(feedback[0]["user"]["app"])
        self.assertIsNotNone(feedback[1]["botActor"])
        self.assertNotIn("id", feedback[2]["user"])

        stale_binding = next(case for case in cases if case["family"] == "stale_binding")["case_context"]
        self.assertNotEqual(stale_binding["artifact"]["id"], stale_binding["maestro_card"]["artifact_id"])
        self.assertNotEqual(stale_binding["artifact"]["pr_head"], stale_binding["maestro_card"]["pr_head"])

        stale_action = next(case for case in cases if case["family"] == "stale_nonlatest_action")["case_context"]
        newer, older = stale_action["state_history"]
        self.assertGreater(newer["createdAt"], stale_action["maestro_card"]["created_at"])
        self.assertNotEqual(newer["fromState"], "Human Review")
        self.assertLess(older["createdAt"], stale_action["maestro_card"]["created_at"])
        self.assertEqual(older["fromState"], "Human Review")

        malformed = next(case for case in cases if case["family"] == "malformed_card")
        self.assertNotIn("rationale", malformed["case_context"]["maestro_card"])


class RoutingScoreTest(unittest.TestCase):
    def test_scoring_against_expected_phase_groups_by_state(self) -> None:
        cases = [
            routing_case("DEV-1", "phase_published:c1"),
            routing_case("DEV-2", "phase_published:c2", state="Merging", expected="Deployment"),
            routing_case("DEV-3", "phase_published:c3", state="Rework", expected="Requirements"),
        ]
        predictions = [
            routing_prediction("DEV-1", "phase_published:c1", "Design"),
            routing_prediction("DEV-2", "phase_published:c2", "Deployment"),
            routing_prediction("DEV-3", "phase_published:c3", "Design"),
        ]

        result = maestro_replay.score_predictions(
            cases,
            predictions,
            expected_fn=lambda case: case.get("expected_phase"),
            label_fn=lambda case: case.get("state") or "unknown",
            phase_fn=lambda case: case.get("expected_phase") or "unknown",
        )

        self.assertEqual(result["overall"], {"total": 3, "agreed": 2, "disagreed": 1, "agreement_rate": 0.6667})
        self.assertEqual(result["by_label"]["Merging"]["agreed"], 1)
        self.assertEqual(result["by_label"]["Rework"]["disagreed"], 1)
        self.assertEqual(result["by_phase"]["Requirements"]["agreement_rate"], 0.0)
        # Confusion rows are the grouping label — the dispatch state for routing.
        self.assertEqual(result["confusion"]["Rework"], {"Design": 1})
        self.assertEqual(result["confusion"]["Merging"], {"Deployment": 1})
        self.assertEqual(result["excluded"], 0)
        self.assertEqual(
            [(item["issue_identifier"], item["label"], item["prediction"]) for item in result["disagreements"]],
            [("DEV-3", "Rework", "Design")],
        )

    def test_frozen_routing_scores_phase_decision_and_required_context(self) -> None:
        cases = [
            {
                **routing_case("FIXTURE-CONTINUE", "continue", expected="Implementation"),
                "expected_decision": "continue_implementation",
                "required_context_markers": ["finding-family-auth", "retry actor query"],
            },
            {
                **routing_case("FIXTURE-BOT", "bot", expected="Human Review"),
                "expected_decision": "continue_implementation",
                "required_context_markers": [],
            },
        ]
        predictions = [
            {
                **routing_prediction("FIXTURE-CONTINUE", "continue", "Implementation", expected_phase="Implementation"),
                "consumed_decision": "continue_implementation",
                "consumed_context": ["finding-family-auth"],
            },
            {
                **routing_prediction("FIXTURE-BOT", "bot", "Human Review", expected_phase="Human Review"),
                "consumed_decision": "continue_implementation",
                "consumed_context": [],
            },
        ]

        result = maestro_replay.score_predictions(
            cases,
            predictions,
            expected_fn=lambda case: case.get("expected_phase"),
            label_fn=lambda case: case.get("state") or "unknown",
            phase_fn=lambda case: case.get("expected_phase") or "unknown",
            agreement_fn=maestro_replay.routing_agreed,
        )

        self.assertEqual(result["overall"], {"total": 2, "agreed": 1, "disagreed": 1, "agreement_rate": 0.5})
        self.assertEqual(result["by_phase"]["Human Review"]["agreed"], 1)


class RoutingReplayCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        root = Path.cwd() / ".symphony" / "routing-replay-tests"
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
                    routing_case("DEV-1", "phase_published:c1"),
                    routing_case("DEV-2", "phase_published:c2", state="Merging", expected="Deployment"),
                ]
            ),
        )
        self.workflow = self.tmp / "WORKFLOW.md"
        self.workflow.write_text(WORKFLOW_TEXT)
        self.output_dir = self.tmp / "replay"
        self.calls_log = self.tmp / "calls.log"

    def tearDown(self) -> None:
        if self.tmp.exists():
            shutil.rmtree(self.tmp)

    def fake_codex(self, body: str) -> str:
        script = self.tmp / "fake_codex.py"
        script.write_text(body)
        return f"{shlex.quote(sys.executable)} {shlex.quote(str(script))}"

    def run_routing_replay(self, codex_cmd: str, *extra: str) -> int:
        return maestro_replay.main(
            [
                "routing-replay",
                "--cases",
                str(self.cases_path),
                "--output",
                str(self.output_dir),
                "--codex-cmd",
                codex_cmd,
                "--workflow",
                str(self.workflow),
                *extra,
            ],
        )

    def run_frozen_routing_replay(self, codex_cmd: str) -> int:
        with (
            mock.patch.object(
                maestro_replay,
                "replay_child_argv",
                return_value=shlex.split(codex_cmd),
            ),
            mock.patch.object(maestro_replay, "preflight_strict_replay"),
        ):
            return self.run_routing_replay(maestro_replay.DEFAULT_CODEX_CMD)

    def read_predictions(self) -> list[dict]:
        return maestro_replay.read_jsonl(self.output_dir / "predictions.jsonl")

    def test_routing_replay_writes_predictions_and_composes_the_prompt(self) -> None:
        codex_cmd = self.fake_codex(
            "import sys, pathlib\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "prompt = sys.stdin.read()\n"
            "log.open('a').write(prompt + '\\n===\\n')\n"
            "print('analysis...')\n"
            "print('**TARGET_PHASE: Implementation**')\n",
        )

        self.assertEqual(self.run_routing_replay(codex_cmd, "--concurrency", "1"), 0)

        predictions = self.read_predictions()
        self.assertEqual(len(predictions), 2)
        by_id = {p["published_event_id"]: p for p in predictions}
        self.assertEqual(set(by_id), {"phase_published:c1", "phase_published:c2"})
        self.assertEqual(by_id["phase_published:c1"]["prediction"], "Implementation")
        self.assertEqual(by_id["phase_published:c1"]["expected_phase"], "Design")
        self.assertIsNone(by_id["phase_published:c1"]["confidence"])
        self.assertIn("TARGET_PHASE", by_id["phase_published:c1"]["raw_tail"])

        prompts = self.calls_log.read_text()
        self.assertIn("## Phase Map", prompts)
        self.assertIn("## Main Flow", prompts)
        self.assertNotIn("## Skill Interaction Protocol", prompts)
        self.assertIn("回放路由决策：issue DEV-1 在 2026-06-15T10:00:00Z 以状态 In Progress 被派发。", prompts)
        self.assertIn("时间旅行纪律：只考虑 createdAt <= 2026-06-15T10:00:00Z 的 Linear 评论", prompts)
        self.assertIn("只做步骤 3-5 的路由判断，不执行任何阶段工作、不写入任何东西", prompts)
        self.assertIn("最后一行输出且仅输出 `TARGET_PHASE: <Requirements|Design|Implementation|Deployment>`", prompts)

    def test_frozen_context_is_injected_and_parsed_without_network(self) -> None:
        frozen = {
            **routing_case("FIXTURE-ESC-1", "frozen", expected="Implementation"),
            "expected_decision": "continue_implementation",
            "required_context_markers": ["finding-family-auth", "retry actor query"],
            "case_context": {
                "artifact": {"review_verdict": "ESCALATED"},
                "maestro_card": {"decision": "continue implementation"},
                "state_history": [{"toState": "In Progress", "actor": {"app": False}}],
                "human_feedback": [],
            },
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        codex_cmd = self.fake_codex(
            "import sys, pathlib\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "log.write_text(sys.stdin.read())\n"
            "print('TARGET_PHASE: Implementation')\n"
            "print('CONSUMED_DECISION: continue implementation')\n"
            "print('CONSUMED_CONTEXT: finding-family-auth, retry actor query')\n",
        )

        self.assertEqual(self.run_frozen_routing_replay(codex_cmd), 0)

        result = self.read_predictions()[0]
        self.assertEqual(result["prediction"], "Implementation")
        self.assertEqual(result["consumed_decision"], "continue_implementation")
        self.assertEqual(result["consumed_context"], ["finding-family-auth", "retry actor query"])
        prompt = self.calls_log.read_text()
        self.assertIn(json.dumps(frozen["case_context"], ensure_ascii=False, indent=2, sort_keys=True), prompt)
        self.assertIn("冻结环境：SYMPHONY_MAESTRO_ACTOR_ID=maestro-app", prompt)
        self.assertIn("不得读取当前 Linear 或 GitHub", prompt)
        self.assertIn("CONSUMED_DECISION", prompt)
        self.assertIn("CONSUMED_CONTEXT", prompt)
        self.assertNotIn("只允许 linear / gh", prompt)

        self.assertEqual(
            maestro_replay.codex_argv_for_case(maestro_replay.DEFAULT_CODEX_CMD, frozen),
            shlex.split(maestro_replay.HERMETIC_CODEX_CMD),
        )

    def test_routing_contract_uses_stdout_not_stderr_transport_echo(self) -> None:
        frozen = {
            **routing_case("FIXTURE-ESC-STDERR", "stderr-echo", expected="Implementation"),
            "expected_decision": "continue_implementation",
            "required_context_markers": ["retry actor query"],
            "case_context": {
                "artifact": {"review_verdict": "ESCALATED"},
                "maestro_card": {"decision": "continue implementation"},
                "state_history": [{"toState": "In Progress", "actor": {"app": False}}],
                "human_feedback": [],
            },
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        codex_cmd = self.fake_codex(
            "import sys\n"
            "sys.stdin.read()\n"
            "answer = 'TARGET_PHASE: Implementation\\nCONSUMED_DECISION: continue_implementation\\nCONSUMED_CONTEXT: retry actor query'\n"
            "print(answer)\n"
            "print(answer, file=sys.stderr)\n",
        )

        self.assertEqual(self.run_frozen_routing_replay(codex_cmd), 0)
        result = self.read_predictions()[0]
        self.assertEqual(result["prediction"], "Implementation")
        self.assertEqual(result["consumed_decision"], "continue_implementation")
        self.assertEqual(result["consumed_context"], ["retry actor query"])

    def test_rerun_resumes_by_published_event_id(self) -> None:
        codex_cmd = self.fake_codex(
            "import sys, pathlib\n"
            f"log = pathlib.Path({str(self.calls_log)!r})\n"
            "sys.stdin.read()\n"
            "log.open('a').write('call\\n')\n"
            "print('TARGET_PHASE: Design')\n",
        )

        self.assertEqual(self.run_routing_replay(codex_cmd, "--sample", "1"), 0)
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 1)
        self.assertEqual([p["published_event_id"] for p in self.read_predictions()], ["phase_published:c1"])

        self.assertEqual(self.run_routing_replay(codex_cmd), 0)
        self.assertEqual(len(self.calls_log.read_text().splitlines()), 2)
        self.assertEqual({p["published_event_id"] for p in self.read_predictions()}, {"phase_published:c1", "phase_published:c2"})

    def test_score_field_expected_phase_writes_routing_report(self) -> None:
        predictions_path = self.tmp / "predictions.jsonl"
        predictions_path.write_text(
            json.dumps(routing_prediction("DEV-1", "phase_published:c1", "Design"))
            + "\n"
            + json.dumps(routing_prediction("DEV-2", "phase_published:c2", "Implementation"))
            + "\n",
        )

        exit_code = maestro_replay.main(
            ["score", "--field", "expected_phase", "--cases", str(self.cases_path), "--predictions", str(predictions_path)],
        )

        self.assertEqual(exit_code, 0)
        report = (self.tmp / "report.md").read_text()
        self.assertIn("# Routing Replay Report", report)
        self.assertIn("| all cases | 2 | 1 | 1 | 50.0% |", report)
        self.assertIn("| Merging | 1 | 0 | 1 | 0.0% |", report)
        self.assertIn("- DEV-2 — Deployment: label Merging, predicted Implementation (artifact phase_published:c2)", report)

    def test_score_field_expected_phase_requires_frozen_context_markers(self) -> None:
        frozen = {
            **routing_case("FIXTURE-ESC-1", "frozen", expected="Implementation"),
            "expected_decision": "continue_implementation",
            "required_context_markers": ["finding-family-auth", "retry actor query"],
            "case_context": {},
        }
        self.cases_path.write_text(json.dumps(frozen) + "\n")
        excerpt = maestro_replay.routing_excerpt(
            maestro_replay.require_text(maestro_replay.default_workflow_path(), "workflow prompt"),
        )
        child_argv = maestro_replay.replay_child_argv(maestro_replay.DEFAULT_CODEX_CMD, [frozen])
        predictions_path = self.tmp / "predictions.jsonl"
        predictions_path.write_text(
            json.dumps(
                {
                    **frozen,
                    "prediction": "Implementation",
                    "consumed_decision": "continue_implementation",
                    "consumed_context": ["finding-family-auth"],
                    "replay_fingerprint": maestro_replay.replay_fingerprint(
                        case=frozen,
                        prompt=maestro_replay.compose_routing_prompt(excerpt, frozen),
                        child_argv=child_argv,
                        parser_schema_version=maestro_replay.ROUTING_PARSER_SCHEMA_VERSION,
                    ),
                },
            )
            + "\n",
        )

        self.assertEqual(
            maestro_replay.main(
                ["score", "--field", "expected_phase", "--cases", str(self.cases_path), "--predictions", str(predictions_path)],
            ),
            0,
        )
        report = (self.tmp / "report.md").read_text()
        self.assertIn("1 scored prediction(s); 0 excluded", report)
        self.assertIn("| all cases | 1 | 0 | 1 | 0.0% |", report)

        record = json.loads(predictions_path.read_text())
        predictions_path.write_text(
            json.dumps(
                {
                    **record,
                    "consumed_context": frozen["required_context_markers"],
                    "replay_fingerprint": "stale",
                },
            )
            + "\n",
        )
        self.assertEqual(
            maestro_replay.main(
                ["score", "--field", "expected_phase", "--cases", str(self.cases_path), "--predictions", str(predictions_path)],
            ),
            0,
        )
        stale_report = (self.tmp / "report.md").read_text()
        self.assertIn("| all cases | 1 | 0 | 1 | 0.0% |", stale_report)
        self.assertIn("predicted unparsed", stale_report)

    def test_missing_workflow_file_fails_cleanly(self) -> None:
        exit_code = maestro_replay.main(
            ["routing-replay", "--cases", str(self.cases_path), "--output", str(self.output_dir), "--workflow", str(self.tmp / "missing.md")],
        )
        self.assertEqual(exit_code, 1)
