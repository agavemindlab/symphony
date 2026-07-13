import importlib.util
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from copy import deepcopy
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("review_gate.py")
PRODUCER = Path(__file__).with_name("review_producer.py")


def load_gate():
    spec = importlib.util.spec_from_file_location("review_gate", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_producer():
    spec = importlib.util.spec_from_file_location("review_producer", PRODUCER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReviewGateTest(unittest.TestCase):
    def setUp(self):
        self.gate = load_gate()
        self.head = "b" * 40
        self.base = "a" * 40
        self.record = {
            "issue_identifier": "DEV-5474",
            "review_base": self.base,
            "review_head": self.head,
            "current_head": self.head,
            "pr_head": self.head,
            "pr_url": "https://github.com/example/repo/pull/1",
            "pr_base_branch": "main",
            "pr_feedback_digest": "f" * 64,
            "worktree_clean": True,
            "diff_kind": "code",
            "diff_size": "small",
            "config": {
                "telemetry": "off",
                "update_check": False,
                "artifacts_sync_mode": "off",
                "artifacts_sync_mode_prompted": True,
                "cross_project_learnings": False,
                "checkpoint_mode": "explicit",
                "checkpoint_push": False,
                "codex_reviews": "enabled",
            },
            "writes": [
                "$HOME/.gstack/symphony/DEV-5474/run.json",
                "$HOME/.codex/sessions/2026/07/review.jsonl",
                "/tmp/codex-adv-1234",
                "/tmp/codex-review-5678",
            ],
            "preamble": {
                "name": "gstack-review-preamble",
                "status": "completed",
                "review_head": self.head,
                "evidence": "mandatory gstack preamble completed",
                "skill_sha256": "a" * 64,
                "helper_sha256": {
                    "gstack-update-check": "a" * 64,
                    "gstack-config": "b" * 64,
                    "gstack-repo-mode": "c" * 64,
                    "gstack-slug": "d" * 64,
                    "gstack-timeline-log": "e" * 64,
                },
                "provenance": {
                    "session_id": "gstack-preamble:test",
                    "argv": ["fixed-review-producer", "preamble"],
                    "started_ns": 1,
                    "completed_ns": 2,
                    "exit_code": 0,
                    "output_sha256": "b" * 64,
                },
            },
            "applicability": {
                "api-contract": {"required": False, "reason": "no API change"},
                "migration": {"required": False, "reason": "no state migration"},
                "design": {"required": True},
            },
            "passes": [],
            "raw_findings": [],
            "findings": [],
        }
        self.record["passes"] = [
            self.pass_record(name) for name in self.gate.ALWAYS_PASSES
        ]
        self.record["passes"].append(self.pass_record("design"))

    def pass_record(self, name, status="completed"):
        return {
            "name": name,
            "status": status,
            "review_base": self.base,
            "review_head": self.head,
            "evidence": f"{name} completed on frozen range",
            "provenance": {
                "session_id": f"session:{name}",
                "argv": ["fixed-review-producer", name],
                "started_ns": 1,
                "completed_ns": 2,
                "exit_code": 0,
                "output_sha256": "e" * 64,
                "checklist_sha256": "c" * 64,
            },
        }

    def errors(self, record=None):
        return self.gate.evaluate(record or self.record)

    def test_exact_head_receipt_is_required_and_tamper_evident(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record = deepcopy(self.record)
            record["runtime_errors"] = []
            record_path = root / "review-gate.json"
            receipt_path = root / "review-evidence" / self.head / "run.json"
            receipt_path.parent.mkdir(parents=True)
            output_path = receipt_path.with_name("producer.json")

            def write_receipt(payload):
                payload = deepcopy(payload)
                output_path.write_text('{"producer":"fixed"}\n')
                payload["producer"]["output_sha256"] = hashlib.sha256(
                    output_path.read_bytes()
                ).hexdigest()
                receipt_path.write_text(json.dumps(payload, sort_keys=True))
                record["evidence_receipt"] = {
                    "path": f"review-evidence/{self.head}/run.json",
                    "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                }

            receipt = {
                "schema": 1,
                "review_base": self.base,
                "review_head": self.head,
                "inputs": {name: record.get(name) for name in self.gate.RECEIPT_INPUTS},
                "producer": {
                    "kind": "fixed-review-producer",
                    "sha256": hashlib.sha256(
                        self.gate.PRODUCER.read_bytes()
                    ).hexdigest(),
                    "config_sha256": "a" * 64,
                    "sandbox_profile_sha256": "b" * 64,
                    "codex_sha256": "c" * 64,
                    "claude_sha256": "d" * 64,
                    "git_sha256": "e" * 64,
                    "zsh_sha256": "e" * 64,
                    "auth_sha256": "f" * 64,
                    "output_sha256": "e" * 64,
                },
                "write_policy": list(self.gate.WRITE_POLICY),
                "config": record["config"],
                "writes": record["writes"],
                "preamble": record["preamble"],
                "passes": record["passes"],
                "raw_findings": record["raw_findings"],
                "findings": record["findings"],
                "runtime_errors": [],
            }
            write_receipt(receipt)
            self.assertEqual([], self.gate._receipt_errors(record, record_path))

            record["pr_url"] = "https://github.com/example/repo/pull/2"
            self.assertIn(
                "evidence receipt inputs do not match the review record",
                self.gate._receipt_errors(record, record_path),
            )
            record["pr_url"] = "https://github.com/example/repo/pull/1"

            stale = {**receipt, "review_head": "c" * 40}
            write_receipt(stale)
            self.assertIn(
                "evidence receipt reviewed a different range",
                self.gate._receipt_errors(record, record_path),
            )

            write_receipt(receipt)
            receipt_path.write_text("tampered")
            self.assertIn(
                "evidence receipt sha256 mismatch",
                self.gate._receipt_errors(record, record_path),
            )

            receipt_path.write_text("[]")
            record["evidence_receipt"]["sha256"] = hashlib.sha256(
                receipt_path.read_bytes()
            ).hexdigest()
            self.assertIn(
                "evidence receipt must be a JSON object",
                self.gate._receipt_errors(record, record_path),
            )

            write_receipt(receipt)
            record["passes"][0]["evidence"] = "handwritten success"
            self.assertIn(
                "evidence receipt does not match record passes",
                self.gate._receipt_errors(record, record_path),
            )

            arbitrary = subprocess.run(
                [
                    sys.executable,
                    SCRIPT,
                    "--capture",
                    record_path,
                    "--",
                    sys.executable,
                    "-c",
                    "print('{}')",
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(2, arbitrary.returncode)

    def test_fixed_producer_forces_matrix_and_independent_finding_stages(self):
        producer = load_producer()
        record = {
            "review_base": self.base,
            "review_head": self.head,
            "applicability": {
                "api-contract": {"required": True},
                "migration": {"required": False, "reason": "no migration"},
                "design": {"required": True},
            },
        }
        self.assertEqual(
            [*producer.ALWAYS_PASSES, "api-contract", "design"],
            producer._required_passes(record),
        )
        raw = [
            {
                "id": "security:1",
                "reporter": "security",
                "path": "a.py",
                "line": 1,
                "reported_severity": "P2",
            },
            {
                "id": "testing:1",
                "reporter": "testing",
                "path": "b.py",
                "line": 2,
                "reported_severity": "P1",
            },
        ]
        validation = {
            "results": [
                {
                    "raw_finding_id": "security:1",
                    "disposition": "dismissed",
                    "path": "a.py",
                    "line": 1,
                    "validation_evidence": "static trace disproves it",
                },
                {
                    "raw_finding_id": "testing:1",
                    "disposition": "validated",
                    "path": "b.py",
                    "line": 2,
                    "validation_evidence": "focused test reproduces it",
                },
            ]
        }
        audit = {
            "results": [
                {
                    "raw_finding_id": "testing:1",
                    "final_severity": "P2",
                    "severity_evidence": "reachable but bounded impact",
                }
            ]
        }
        paths = {
            "diff": "diff --git a/a.py b/a.py\n+dangerous()",
            "git_command": ["/usr/bin/git", "-C", "/repo"],
            "git_env": {},
        }
        with (
            mock.patch.object(
                producer, "_codex_json", side_effect=[(validation, {}), (audit, {})]
            ) as run,
            mock.patch.object(producer, "_output", return_value="dangerous()"),
        ):
            findings, errors = producer._validate_and_audit(raw, record, paths)
        self.assertEqual([], errors)
        self.assertEqual(
            ["dismissed", "downgraded"], [item["disposition"] for item in findings]
        )
        self.assertNotIn("security:1", run.call_args_list[1].args[1])
        self.assertIn("dangerous()", run.call_args_list[0].args[1])
        self.assertIn(
            "approved trust boundary",
            run.call_args_list[0].kwargs["developer_instructions"],
        )
        self.assertIn(
            "not formal proof",
            run.call_args_list[0].kwargs["developer_instructions"],
        )
        self.assertNotEqual(findings[1]["reporter"], findings[1]["validator"])
        self.assertNotEqual(findings[1]["validator"], findings[1]["auditor"])

    def test_reviewer_environment_drops_caller_credentials(self):
        producer = load_producer()
        with mock.patch.dict(
            os.environ,
            {"GH_TOKEN": "secret", "AWS_SECRET_ACCESS_KEY": "secret"},
            clear=False,
        ):
            env = producer._review_env(
                Path("/trusted/home"), {"CODEX_HOME": "/managed"}
            )
        self.assertEqual("/managed", env["CODEX_HOME"])
        self.assertNotIn("GH_TOKEN", env)
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", env)

    def test_codex_reviewer_disables_model_tools_under_outer_sandbox(self):
        producer = load_producer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            outputs = root / "outputs"
            outputs.mkdir()
            paths = {
                "outputs": outputs,
                "home": root,
                "session_root": root / "sessions",
                "gstack_home": root / "gstack",
                "temp_root": root / "temp",
                "sandbox": "/usr/bin/sandbox-exec",
                "profile": root / "review.sb",
                "codex": "/opt/homebrew/bin/codex",
                "workspace": root,
            }
            record = {
                "issue_identifier": "DEV-5474",
                "review_head": self.head,
            }

            def completed(command, **_kwargs):
                output = Path(command[command.index("--output-last-message") + 1])
                output.write_text(
                    '{"status":"completed","evidence":"ok","findings":[]}'
                )
                return subprocess.CompletedProcess(command, 0, "", "")

            with (
                mock.patch.object(
                    producer, "_codex_home", return_value=root / "managed"
                ),
                mock.patch.object(
                    producer.subprocess, "run", side_effect=completed
                ) as run,
            ):
                result, provenance = producer._codex_json(
                    "security",
                    "literal diff",
                    producer.RESULT_SCHEMA,
                    record,
                    paths,
                    developer_instructions="trusted review instructions",
                )
            command = run.call_args.args[0]
            self.assertEqual("completed", result["status"])
            self.assertEqual(
                "danger-full-access", command[command.index("--sandbox") + 1]
            )
            self.assertIn("shell_tool", command)
            self.assertIn("unified_exec", command)
            self.assertIn("--strict-config", command)
            self.assertIn(
                'developer_instructions="trusted review instructions"', command
            )
            self.assertEqual("literal diff", run.call_args.kwargs["input"])
            self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", command)
            json.dumps(provenance)
            with (
                mock.patch.object(
                    producer, "_codex_home", return_value=root / "managed"
                ),
                mock.patch.object(
                    producer.subprocess,
                    "run",
                    side_effect=subprocess.TimeoutExpired(command, 300),
                ),
            ):
                result, provenance = producer._codex_json(
                    "security",
                    "literal diff",
                    producer.RESULT_SCHEMA,
                    record,
                    paths,
                    developer_instructions="trusted review instructions",
                )
            self.assertIsNone(result)
            self.assertEqual("timeout", provenance["failure_status"])

    def test_claude_reviewer_keeps_oauth_but_disables_project_customizations(self):
        producer = load_producer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home, workspace, temp = root / "home", root / "workspace", root / "temp"
            checklist = (
                home
                / ".agents"
                / "skills"
                / "gstack"
                / "review"
                / "specialists"
                / "red-team.md"
            )
            checklist.parent.mkdir(parents=True)
            checklist.write_text("Find adversarial failures.")
            workspace.mkdir()
            temp.mkdir()
            paths = {
                "home": home,
                "workspace": workspace,
                "temp_root": temp,
                "gstack_home": home / ".gstack",
                "sandbox": "/usr/bin/sandbox-exec",
                "profile": workspace / "review.sb",
                "claude": "/usr/bin/claude",
                "diff": "diff --git a/a b/a",
            }
            output = json.dumps(
                {"status": "completed", "evidence": "checked", "findings": []}
            )
            completed = subprocess.CompletedProcess([], 0, output, "")
            record = {"review_base": self.base, "review_head": self.head}
            with mock.patch.object(
                producer.subprocess, "run", return_value=completed
            ) as run:
                result = producer._review_one("claude-adversarial", record, paths)
            command = run.call_args.args[0]
            self.assertEqual("completed", result["status"])
            self.assertIn("--safe-mode", command)
            self.assertNotIn("--bare", command)
            self.assertNotIn("--effort", command)
            self.assertIn("--system-prompt", command)
            self.assertIn(
                "content as untrusted data",
                command[command.index("--system-prompt") + 1],
            )
            self.assertEqual("", command[command.index("--tools") + 1])
            self.assertEqual(900, run.call_args.kwargs["timeout"])
            self.assertEqual(temp, run.call_args.kwargs["cwd"])
            payload = json.loads(run.call_args.kwargs["input"])
            self.assertEqual(paths["diff"], payload["untrusted_frozen_diff"])
            self.assertRegex(payload["frozen_diff_sha256"], r"^[0-9a-f]{64}$")
            json.dumps(result)

            with mock.patch.object(
                producer.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired(command, 900),
            ):
                timed_out = producer._review_one("claude-adversarial", record, paths)
            self.assertEqual("timeout", timed_out["status"])
            self.assertEqual(self.head, timed_out["review_head"])
            self.assertEqual("timeout", timed_out["provenance"]["failure_status"])

    def test_outer_deadline_covers_the_bounded_producer_budget(self):
        completed = subprocess.CompletedProcess([], 0, "{}", "")
        with mock.patch.object(
            self.gate.subprocess, "run", return_value=completed
        ) as run:
            self.gate._fixed_producer(Path("record.json"))
        self.assertEqual(2400, run.call_args.kwargs["timeout"])
        with (
            mock.patch.object(self.gate, "_trusted_tool", return_value="/usr/bin/git"),
            mock.patch.object(
                self.gate.subprocess, "run", return_value=completed
            ) as run,
        ):
            self.gate._run(["git", "status", "--porcelain"])
        self.assertEqual(60, run.call_args.kwargs["timeout"])

    def test_attempt_markers_and_atomic_writes_prevent_same_turn_rerolls(self):
        producer = load_producer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record_path = root / "review-gate.json"
            record_path.write_text("{}")
            with mock.patch.dict(os.environ, {"CODEX_THREAD_ID": "turn-a"}):
                marker, lock = self.gate._reserve_attempt(record_path, self.head)
                with self.assertRaisesRegex(ValueError, "active capture"):
                    self.gate._reserve_attempt(record_path, self.head)
            self.assertEqual("started", json.loads(marker.read_text())["status"])
            with mock.patch.dict(os.environ, {"CODEX_THREAD_ID": "turn-a"}):
                self.gate._finish_attempt(
                    marker, self.head, "failed", "review timeout", lock
                )
                with self.assertRaisesRegex(ValueError, "already attempted"):
                    self.gate._reserve_attempt(record_path, self.head)
            self.assertEqual("failed", json.loads(marker.read_text())["status"])
            self.assertIn("review timeout", json.loads(marker.read_text())["error"])
            other_head = "c" * 40
            record_path.write_text(json.dumps({"review_head": other_head}))
            with (
                mock.patch.dict(os.environ, {"CODEX_THREAD_ID": "turn-c"}),
                mock.patch.object(
                    self.gate, "_workspace_record", return_value=record_path
                ),
            ):
                other, other_lock = self.gate._reserve_attempt(record_path, other_head)
                other_lock.close()
                self.gate._fail_current_attempt(record_path, "post-review failure")
            self.assertEqual("failed", json.loads(other.read_text())["status"])
            marker.write_text(
                json.dumps(
                    {"review_head": self.head, "status": "completed", "turn": "turn-a"}
                )
            )
            with (
                mock.patch.dict(os.environ, {"CODEX_THREAD_ID": "turn-b"}),
                self.assertRaisesRegex(ValueError, "completed capture"),
            ):
                self.gate._reserve_attempt(record_path, self.head)

            symlink_record = root / "symlink" / "review-gate.json"
            symlink_record.parent.mkdir()
            symlink_record.write_text("{}")
            lock_path = (
                symlink_record.parent
                / "review-evidence"
                / self.head
                / "capture.lock"
            )
            lock_path.parent.mkdir(parents=True)
            outside_lock = root / "outside-lock"
            lock_path.symlink_to(outside_lock)
            with (
                mock.patch.dict(os.environ, {"CODEX_THREAD_ID": "turn-symlink"}),
                self.assertRaises(OSError),
            ):
                self.gate._reserve_attempt(symlink_record, self.head)
            self.assertFalse(outside_lock.exists())

            for module in (self.gate, producer):
                outside = root / f"outside-{module.__name__}"
                target = root / f"target-{module.__name__}"
                outside.write_text("preserve")
                os.link(outside, target)
                module._safe_write(target, "evidence")
                self.assertEqual("preserve", outside.read_text())
                self.assertEqual("evidence", target.read_text())
            self.assertEqual(
                {"/allowed/deleted"},
                producer._changed_paths({"/allowed/deleted": (1,)}, {}),
            )

    def test_each_pass_binds_a_trusted_gstack_checklist(self):
        producer = load_producer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            home, workspace = root / "home", root / "workspace"
            checklist = (
                home
                / ".agents"
                / "skills"
                / "gstack"
                / "review"
                / "specialists"
                / "testing.md"
            )
            checklist.parent.mkdir(parents=True)
            checklist.write_text("Check false-positive tests.")
            workspace.mkdir()
            content, digest = producer._checklist("testing", home, workspace)
            self.assertEqual("Check false-positive tests.", content)
            self.assertEqual(hashlib.sha256(checklist.read_bytes()).hexdigest(), digest)
            self.assertIn(
                content, producer._prompt("testing", self.base, self.head, content)
            )

    def test_fixed_git_ignores_path_and_git_dir_injection(self):
        expected = subprocess.run(
            ["/usr/bin/git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        with mock.patch.dict(
            os.environ,
            {
                "PATH": "/attacker",
                "GIT_DIR": "/attacker/repo",
                "GIT_WORK_TREE": "/attacker",
            },
        ):
            self.assertEqual(expected, self.gate._run(["git", "rev-parse", "HEAD"]))

    def test_trusted_gh_candidates_include_linux_and_homebrew_paths(self):
        self.assertEqual(
            (
                Path("/usr/bin/gh"),
                Path("/opt/homebrew/bin/gh"),
                Path("/usr/local/bin/gh"),
            ),
            self.gate.TRUSTED_TOOL_CANDIDATES["gh"],
        )

    def test_managed_auth_symlink_is_allowed_by_link_location_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            auth = home / ".codex" / "auth.json"
            link = home / ".codex" / "sessions" / "managed" / "auth.json"
            link.parent.mkdir(parents=True)
            auth.write_text("{}")
            link.symlink_to(auth)
            with mock.patch.object(self.gate, "_trusted_home", return_value=str(home)):
                self.assertTrue(self.gate._allowed_write(str(link)))
                link.unlink()
                link.symlink_to(home / "outside")
                self.assertFalse(self.gate._allowed_write(str(link)))

    @unittest.skipUnless(
        Path("/usr/bin/sandbox-exec").is_file(), "macOS sandbox required"
    )
    def test_fixed_producer_profile_denies_non_review_writes(self):
        producer = load_producer()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            evidence = root / "evidence"
            evidence.mkdir()
            profile = evidence / "review.sb"
            producer._sandbox_profile(
                profile,
                evidence,
                root / "gstack",
                root / "sessions",
                root / "session_index.jsonl",
                root / "codex-review-test",
            )
            injected = evidence / "injection.sb"
            producer._sandbox_profile(
                injected,
                root / 'quote"\n(allow file-write*)\n',
                root / "gstack",
                root / "sessions",
                root / "session_index.jsonl",
                root / "codex-review-test",
            )
            self.assertEqual(
                1,
                sum(
                    line.strip() == "(allow file-write*"
                    for line in injected.read_text().splitlines()
                ),
            )
            allowed = subprocess.run(
                [
                    "/usr/bin/sandbox-exec",
                    "-f",
                    profile,
                    "/usr/bin/touch",
                    evidence / "ok",
                ],
                capture_output=True,
            )
            denied_path = Path("/tmp") / f"review-gate-denied-{os.getpid()}"
            denied = subprocess.run(
                ["/usr/bin/sandbox-exec", "-f", profile, "/usr/bin/touch", denied_path],
                capture_output=True,
            )
            self.assertEqual(0, allowed.returncode, allowed.stderr)
            self.assertNotEqual(0, denied.returncode)
            self.assertFalse(denied_path.exists())

    def test_small_and_large_code_diffs_require_the_same_core_matrix(self):
        self.assertEqual([], self.errors())

        large = deepcopy(self.record)
        large["diff_size"] = "large"
        self.assertEqual([], self.errors(large))

        for size in ("small", "large"):
            missing = deepcopy(self.record)
            missing["diff_size"] = size
            missing["passes"] = [
                item for item in missing["passes"] if item["name"] != "performance"
            ]
            self.assertIn("missing required pass: performance", self.errors(missing))

    def test_plan_command_forces_the_same_dispatch_matrix_for_small_large_and_low_hit_rate(
        self,
    ):
        for size in ("small", "large"):
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "record.json"
                record = deepcopy(self.record)
                record.update(diff_size=size, adaptive_hit_rate=0)
                path.write_text(json.dumps(record))
                result = subprocess.run(
                    [sys.executable, SCRIPT, "--plan", path],
                    capture_output=True,
                    text=True,
                )
            self.assertEqual(0, result.returncode, result.stdout)
            self.assertEqual(
                [*self.gate.ALWAYS_PASSES, "design"],
                json.loads(result.stdout)["passes"],
            )

    def test_failed_timeout_unavailable_and_unparsable_passes_fail_closed(self):
        for status in ("failed", "timeout", "unavailable", "unparsable"):
            record = deepcopy(self.record)
            record["passes"] = [
                self.pass_record(
                    item["name"], status if item["name"] == "red-team" else "completed"
                )
                for item in record["passes"]
            ]
            self.assertIn(f"required pass red-team is {status}", self.errors(record))

        extra = deepcopy(self.record)
        extra["passes"].append(self.pass_record("migration"))
        self.assertIn(
            "actual review passes do not exactly match the required plan",
            self.errors(extra),
        )

    def test_real_home_write_allowlist_and_fixed_config_are_fail_closed(self):
        self.assertEqual([], self.errors())

        for path in (
            "$HOME/.claude/session-env/leak",
            "$HOME/.codex/config.toml",
            "/tmp/unrelated",
        ):
            outside = deepcopy(self.record)
            outside["writes"].append(path)
            self.assertIn(
                f"write outside review allowlist: {path}", self.errors(outside)
            )

        managed_temp = deepcopy(self.record)
        managed_temp["writes"].append("/tmp/codex-adv-1234/child")
        if os.path.realpath("/tmp") == "/private/tmp":
            managed_temp["writes"].append("/private/tmp/codex-review-5678/child")
        self.assertEqual([], self.errors(managed_temp))

        if os.path.realpath("/tmp") != "/private/tmp":
            outside = deepcopy(self.record)
            outside["writes"].append("/private/tmp/codex-review-5678")
            self.assertIn(
                "write outside review allowlist: /private/tmp/codex-review-5678",
                self.errors(outside),
            )

        bad_config = deepcopy(self.record)
        bad_config["config"]["telemetry"] = "community"
        self.assertIn("config telemetry must be 'off'", self.errors(bad_config))

        boolean_evidence = deepcopy(self.record)
        boolean_evidence["passes"][0]["evidence"] = True
        boolean_evidence["applicability"]["api-contract"]["reason"] = True
        errors = self.errors(boolean_evidence)
        self.assertIn("required pass core-correctness lacks evidence", errors)
        self.assertIn("N/A pass api-contract lacks a reason", errors)

    def test_findings_are_validated_dismissed_or_downgraded_before_action(self):
        true_finding = {
            "raw_finding_id": "raw-true",
            "disposition": "validated",
            "reporter": "performance-reviewer",
            "validator": "validator-1",
            "auditor": "severity-auditor-1",
            "path": "lib/upload.ex",
            "line": 47,
            "validation_evidence": "focused race test reproduces truncation",
            "severity_evidence": "reachable concurrent PATCH loses bytes",
            "final_severity": "P1",
            "blocking": True,
        }
        false_finding = {
            "raw_finding_id": "raw-false",
            "disposition": "dismissed",
            "reporter": "security-reviewer",
            "validator": "validator-2",
            "path": "lib/upload.ex",
            "line": 82,
            "validation_evidence": "static trace proves the lock covers both writes",
        }
        overstated = {
            "raw_finding_id": "raw-overstated",
            "disposition": "downgraded",
            "reporter": "maintainability-reviewer",
            "validator": "validator-3",
            "auditor": "severity-auditor-3",
            "path": "lib/state.ex",
            "line": 19,
            "validation_evidence": "allocation exists",
            "severity_evidence": "bounded to 20 elements by caller",
            "final_severity": "P3",
            "blocking": False,
        }

        record = deepcopy(self.record)
        record["raw_findings"] = [{"id": "raw-false"}, {"id": "raw-overstated"}]
        record["findings"] = [false_finding, overstated]
        self.assertEqual([], self.errors(record))

        record["findings"].append(true_finding)
        record["raw_findings"].append({"id": "raw-true"})
        self.assertIn(
            "audited blocking finding remains: lib/upload.ex:47", self.errors(record)
        )

        true_finding["blocking"] = False
        self.assertIn(
            "audited blocking finding remains: lib/upload.ex:47", self.errors(record)
        )

        invalid_severity = deepcopy(self.record)
        invalid_finding = deepcopy(overstated)
        invalid_finding["final_severity"] = "urgent"
        invalid_severity["raw_findings"] = [{"id": "raw-overstated"}]
        invalid_severity["findings"] = [invalid_finding]
        self.assertIn(
            "finding 1 has invalid final severity", self.errors(invalid_severity)
        )

        raw = deepcopy(self.record)
        raw["raw_findings"] = [{"id": "raw-unclassified"}]
        raw["findings"] = [
            {"raw_finding_id": "raw-unclassified", "path": "lib/raw.ex", "line": 1}
        ]
        self.assertIn("finding 1 has invalid disposition", self.errors(raw))

        biased = deepcopy(self.record)
        biased_finding = deepcopy(overstated)
        biased_finding["auditor"] = biased_finding["reporter"]
        biased["raw_findings"] = [{"id": "raw-overstated"}]
        biased["findings"] = [biased_finding]
        self.assertIn(
            "finding 1 lacks an independent severity auditor", self.errors(biased)
        )

        padded = deepcopy(self.record)
        padded_finding = deepcopy(overstated)
        padded_finding["validator"] = f" {padded_finding['reporter']} "
        padded["raw_findings"] = [{"id": "raw-overstated"}]
        padded["findings"] = [padded_finding]
        self.assertIn("finding 1 lacks an independent validator", self.errors(padded))

        padded_finding["validator"] = overstated["validator"]
        padded_finding["auditor"] = f" {overstated['validator']} "
        self.assertIn(
            "finding 1 lacks an independent severity auditor", self.errors(padded)
        )

        omitted = deepcopy(self.record)
        omitted["raw_findings"] = [{"id": "raw-p1"}]
        self.assertIn(
            "every raw finding requires exactly one final disposition",
            self.errors(omitted),
        )

        empty_validator = deepcopy(self.record)
        finding = deepcopy(false_finding)
        finding["validator"] = ""
        empty_validator["raw_findings"] = [{"id": "raw-false"}]
        empty_validator["findings"] = [finding]
        self.assertIn(
            "finding 1 lacks an independent validator", self.errors(empty_validator)
        )

        boolean_line = deepcopy(empty_validator)
        boolean_line["findings"][0]["validator"] = "validator-2"
        boolean_line["findings"][0]["line"] = True
        self.assertIn("finding 1 lacks file:line evidence", self.errors(boolean_line))

        still_p1 = deepcopy(self.record)
        finding = deepcopy(overstated)
        finding["final_severity"] = "P1"
        still_p1["raw_findings"] = [{"id": "raw-overstated"}]
        still_p1["findings"] = [finding]
        self.assertIn(
            "audited blocking finding remains: lib/state.ex:19", self.errors(still_p1)
        )

    def test_config_booleans_home_root_and_temp_cleanup_are_strict(self):
        numeric = deepcopy(self.record)
        numeric["config"]["checkpoint_push"] = 0
        self.assertIn("config checkpoint_push must be False", self.errors(numeric))

        old_home = os.environ.get("HOME")
        try:
            os.environ["HOME"] = "/etc"
            self.assertFalse(self.gate._allowed_write("/etc/.gstack/run.json"))
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home

        with tempfile.NamedTemporaryFile(prefix="codex-review-", dir="/tmp") as temp:
            dirty = deepcopy(self.record)
            dirty["writes"].append(temp.name)
            self.assertIn(
                f"temporary review path was not cleaned: {temp.name}",
                self.errors(dirty),
            )

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / ".codex").mkdir()
            outside = home / "outside-index"
            outside.write_text("preserve")
            index = home / ".codex" / "session_index.jsonl"
            index.symlink_to(outside)
            with mock.patch.object(self.gate, "_trusted_home", return_value=str(home)):
                self.assertFalse(self.gate._allowed_write(str(index)))

    def test_pr_identity_ci_and_feedback_snapshot_fail_closed(self):
        self.assertEqual(
            ("github.com", "example/repo", "1"),
            self.gate._pr_identity(self.record["pr_url"]),
        )
        with self.assertRaisesRegex(ValueError, "canonical PR URL"):
            self.gate._pr_identity("ssh://github.com/example/repo/pull/1")

        pr = {
            "url": self.record["pr_url"],
            "headRefOid": self.head,
            "baseRefName": "main",
            "baseRefOid": self.base,
            "state": "OPEN",
            "isDraft": False,
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "BLOCKED",
            "reviewDecision": "CHANGES_REQUESTED",
            "_requiredChecks": [
                {"name": "test", "state": "FAILURE", "bucket": "fail"}
            ],
            "statusCheckRollup": [
                {"name": "test", "status": "COMPLETED", "conclusion": "FAILURE"}
            ],
            "reviews": [
                {
                    "author": {"login": "reviewer"},
                    "submittedAt": "2026-07-13T09:00:00Z",
                    "state": "CHANGES_REQUESTED",
                }
            ],
            "comments": [],
        }
        record = {**self.record, "pr_base_branch": "main"}
        errors = []
        self.gate._check_pr(pr, record, errors)
        self.assertIn("PR check is not successful: test", errors)
        self.assertIn("required PR check is not successful: test", errors)
        self.assertIn("PR has unresolved change requests: reviewer", errors)

        unrelated = {
            **pr,
            "reviewDecision": "",
            "reviews": [],
            "mergeStateStatus": "BLOCKED",
            "_requiredChecks": [],
            "statusCheckRollup": [
                {
                    "name": "unrelated",
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                }
            ],
        }
        errors = []
        self.gate._check_pr(unrelated, record, errors)
        self.assertEqual([], errors)

        awaiting_approval = {
            **unrelated,
            "reviewDecision": "REVIEW_REQUIRED",
        }
        errors = []
        self.gate._check_pr(awaiting_approval, record, errors)
        self.assertEqual([], errors)

        conflicting = {**awaiting_approval, "mergeable": "CONFLICTING"}
        errors = []
        self.gate._check_pr(conflicting, record, errors)
        self.assertIn("GitHub does not report the PR as mergeable", errors)

        legacy = {
            **unrelated,
            "mergeStateStatus": "CLEAN",
            "statusCheckRollup": [{"context": "test", "state": "SUCCESS"}],
        }
        errors = []
        self.gate._check_pr(legacy, record, errors)
        self.assertEqual([], errors)

        no_required = subprocess.CompletedProcess(
            [],
            1,
            "",
            "no required checks reported on the 'review' branch\n",
        )
        with mock.patch.object(self.gate, "_run_result", return_value=no_required):
            self.assertEqual([], self.gate._required_checks(record["pr_url"]))
        required = subprocess.CompletedProcess(
            [], 0, '[{"name":"test","state":"SUCCESS","bucket":"pass"}]', ""
        )
        with mock.patch.object(self.gate, "_run_result", return_value=required):
            self.assertEqual("test", self.gate._required_checks(record["pr_url"])[0]["name"])

        actionable = deepcopy(pr)
        actionable["reviewDecision"] = ""
        actionable["reviews"] = [
            {
                "id": "review-1",
                "author": {"login": "reviewer"},
                "submittedAt": "2026-07-13T09:03:00Z",
                "state": "COMMENTED",
                "body": "Please fix this fallback",
            },
            {
                "id": "review-older",
                "author": {"login": "reviewer"},
                "submittedAt": "2026-07-13T09:02:00Z",
                "state": "COMMENTED",
                "body": "Also add a regression",
            },
        ]
        actionable["_inline"] = [
            {"id": 7, "body": "This can fail", "in_reply_to_id": None},
            {"id": 8, "body": "The race still exists", "in_reply_to_id": 7},
        ]
        errors = []
        self.gate._check_pr(actionable, record, errors)
        self.assertIn(
            "PR feedback dispositions do not match current feedback ids", errors
        )

        dispositioned = {
            **record,
            "pr_feedback_dispositions": [
                {
                    "id": "review:review-1",
                    "disposition": "addressed",
                    "evidence": "fixed",
                },
                {
                    "id": "review:review-older",
                    "disposition": "superseded",
                    "evidence": "covered by review-1",
                },
                {
                    "id": "inline:7",
                    "disposition": "dismissed",
                    "evidence": "static trace",
                },
                {"id": "inline:8", "disposition": "addressed", "evidence": "race test"},
            ],
        }
        errors = []
        self.gate._check_pr(actionable, dispositioned, errors)
        self.assertNotIn(
            "PR feedback dispositions do not match current feedback ids", errors
        )

        superseded = deepcopy(pr)
        superseded["reviewDecision"] = ""
        superseded["reviews"].append(
            {
                "author": {"login": "reviewer"},
                "submittedAt": "2026-07-13T09:01:00Z",
                "state": "APPROVED",
            }
        )
        errors = []
        self.gate._check_pr(superseded, {**record, "pr_url": superseded["url"]}, errors)
        self.assertNotIn("PR has unresolved change requests: reviewer", errors)

        commented = deepcopy(pr)
        commented["reviewDecision"] = ""
        commented["reviews"].append(
            {
                "author": {"login": "reviewer"},
                "submittedAt": "2026-07-13T09:02:00Z",
                "state": "COMMENTED",
            }
        )
        errors = []
        self.gate._check_pr(commented, {**record, "pr_url": commented["url"]}, errors)
        self.assertIn("PR has unresolved change requests: reviewer", errors)

        changed = deepcopy(pr)
        changed["comments"] = [{"id": "new-feedback", "body": "please fix"}]
        self.assertNotEqual(
            self.gate._feedback_digest(pr, []), self.gate._feedback_digest(changed, [])
        )
        wrong_url = deepcopy(pr)
        wrong_url["url"] = "https://github.com/example/repo/pull/2"
        errors = []
        self.gate._check_pr(wrong_url, record, errors)
        self.assertIn("canonical PR URL does not match review record", errors)

        final_errors = []
        self.gate._check_final_snapshot(
            pr,
            {**pr, "statusCheckRollup": [{"name": "test", "status": "IN_PROGRESS"}]},
            "same-digest",
            "same-digest",
            record,
            final_errors,
        )
        self.assertIn("PR check is not complete: test", final_errors)

        self.assertEqual(
            [{"id": 1}, {"id": 2}],
            self.gate._flatten_pages([[{"id": 1}], [{"id": 2}]]),
        )

    def test_head_change_invalidates_the_old_verdict_until_every_pass_reruns(self):
        changed = deepcopy(self.record)
        changed["current_head"] = "c" * 40
        changed["pr_head"] = "c" * 40
        self.assertIn("current HEAD does not match review HEAD", self.errors(changed))
        self.assertIn("PR HEAD does not match review HEAD", self.errors(changed))

        rerun = deepcopy(self.record)
        rerun["review_head"] = "c" * 40
        rerun["current_head"] = "c" * 40
        rerun["pr_head"] = "c" * 40
        rerun["passes"] = []
        self.assertIn("missing required pass: core-correctness", self.errors(rerun))

    def test_dev_5195_handoff_replay_and_head_change_require_a_fresh_clean_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            subprocess.run(
                ["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True
            )
            subprocess.run(
                ["git", "config", "user.name", "Test User"], cwd=repo, check=True
            )
            subprocess.run(
                ["git", "config", "user.email", "test@example.com"],
                cwd=repo,
                check=True,
            )
            (repo / "file.txt").write_text("base\n")
            subprocess.run(["git", "add", "file.txt"], cwd=repo, check=True)
            subprocess.run(
                ["git", "commit", "-m", "base"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            base = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            upstream = root / "upstream.git"
            subprocess.run(
                ["git", "init", "--bare", upstream], check=True, capture_output=True
            )
            subprocess.run(
                ["git", "remote", "add", "upstream", upstream], cwd=repo, check=True
            )
            subprocess.run(
                ["git", "push", "upstream", "main"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [
                    "git",
                    "remote",
                    "set-url",
                    "upstream",
                    "https://github.com/openai/symphony.git",
                ],
                cwd=repo,
                check=True,
            )
            subprocess.run(
                ["git", "remote", "add", "origin", upstream], cwd=repo, check=True
            )
            subprocess.run(
                [
                    "git",
                    "remote",
                    "set-url",
                    "origin",
                    "https://github.com/example/repo.git",
                ],
                cwd=repo,
                check=True,
            )
            fork = root / "fork.git"
            subprocess.run(
                ["git", "init", "--bare", fork], check=True, capture_output=True
            )
            subprocess.run(["git", "remote", "add", "fork", fork], cwd=repo, check=True)
            subprocess.run(
                ["git", "switch", "-c", "review"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            (repo / "file.txt").write_text("head a\n")
            subprocess.run(
                ["git", "commit", "-am", "head a"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            head_a = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            subprocess.run(
                ["git", "push", "-u", "fork", "review"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            pr_url = self.record["pr_url"]

            def github_snapshot(head):
                pr = {
                    "url": pr_url,
                    "headRefOid": head,
                    "baseRefName": "main",
                    "baseRefOid": base,
                    "state": "OPEN",
                    "isDraft": False,
                    "mergeable": "MERGEABLE",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": "APPROVED",
                    "_requiredChecks": [],
                    "statusCheckRollup": [
                        {"name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"}
                    ],
                    "reviews": [],
                    "comments": [],
                    "_inline": [],
                }
                return pr, self.gate._feedback_digest(pr, [])

            def run_gate(arguments, pr):
                output = io.StringIO()
                previous_cwd = Path.cwd()
                try:
                    os.chdir(repo)
                    with (
                        mock.patch.object(
                            self.gate,
                            "_github_snapshot",
                            return_value=(pr, self.gate._feedback_digest(pr, [])),
                        ),
                        redirect_stdout(output),
                    ):
                        code = self.gate.main(
                            [str(SCRIPT), *arguments, str(record_path)]
                        )
                finally:
                    os.chdir(previous_cwd)
                return code, output.getvalue()

            capture_turn = 0

            def capture(record, failed_pass=None):
                nonlocal capture_turn
                capture_turn += 1
                record_path.write_text(json.dumps(record))
                producer = load_producer()
                home = root / "home"
                config = (
                    home
                    / ".gstack"
                    / "symphony"
                    / record["issue_identifier"]
                    / record["review_head"]
                    / "config.yaml"
                )
                config.parent.mkdir(parents=True, exist_ok=True)
                config.write_text(
                    "\n".join(
                        f"{name}: {str(value).lower() if isinstance(value, bool) else value}"
                        for name, value in producer.REQUIRED_CONFIG.items()
                    )
                    + "\n"
                )
                auth = home / ".codex" / "auth.json"
                auth.parent.mkdir(parents=True, exist_ok=True)
                auth.write_text("{}")

                def review_one(name, review_record, _paths):
                    failed = name == failed_pass
                    return {
                        "name": name,
                        "status": "failed" if failed else "completed",
                        "review_base": review_record["review_base"],
                        "review_head": review_record["review_head"],
                        "evidence": f"fixed producer dispatched {name}",
                        "provenance": {
                            "session_id": f"test:{name}:{review_record['review_head']}",
                            "argv": ["fixed-review-producer", name],
                            "started_ns": 1,
                            "completed_ns": 2,
                            "exit_code": 1 if failed else 0,
                            "output_sha256": "e" * 64,
                            "checklist_sha256": "c" * 64,
                        },
                        "findings": [],
                    }

                def preamble(review_record, _paths):
                    return {
                        **self.record["preamble"],
                        "review_head": review_record["review_head"],
                    }

                previous_cwd = Path.cwd()
                try:
                    os.chdir(repo)
                    account = mock.Mock(pw_dir=str(home), pw_name="test")
                    tools = {
                        "git": "/usr/bin/git",
                        "sandbox-exec": "/usr/bin/sandbox-exec",
                        "zsh": "/bin/sh",
                        "codex": "/usr/bin/true",
                        "claude": "/usr/bin/true",
                    }
                    with (
                        mock.patch.object(
                            producer.pwd, "getpwuid", return_value=account
                        ),
                        mock.patch.object(
                            producer,
                            "_trusted_tool",
                            side_effect=lambda name, _home, _workspace: tools[name],
                        ),
                        mock.patch.object(
                            producer, "_run_preamble", side_effect=preamble
                        ),
                        mock.patch.object(
                            producer, "_review_one", side_effect=review_one
                        ),
                    ):
                        producer_result = producer.produce(record_path)
                    raw_output = json.dumps(producer_result, sort_keys=True) + "\n"
                    with (
                        mock.patch.object(
                            self.gate,
                            "_fixed_producer",
                            return_value=(producer_result, raw_output),
                        ),
                        mock.patch.dict(
                            os.environ,
                            {"CODEX_THREAD_ID": f"test-turn-{capture_turn}"},
                        ),
                    ):
                        self.gate._capture(record_path)
                finally:
                    os.chdir(previous_cwd)

            pr_a, feedback_a = github_snapshot(head_a)

            record_a = deepcopy(self.record)
            record_a.update(
                review_base=base,
                review_head=head_a,
                current_head=head_a,
                pr_head=head_a,
            )
            record_a["pr_url"] = pr_url
            record_a["pr_feedback_digest"] = feedback_a
            record_a["passes"] = [
                {**item, "review_base": base, "review_head": head_a}
                for item in record_a["passes"]
            ]
            (repo / ".git" / "info" / "exclude").write_text(".symphony/\n")
            record_path = repo / ".symphony" / "review-gate.json"
            record_path.parent.mkdir()
            subprocess.run(
                ["git", "switch", "--detach"], cwd=repo, check=True, capture_output=True
            )
            capture(record_a)
            clean_a_code, clean_a_output = run_gate([], pr_a)
            self.assertEqual(0, clean_a_code, clean_a_output)
            self.assertEqual(
                ["publish_implementation_artifact", "move_human_review"],
                json.loads(clean_a_output)["handoff_actions"],
            )
            snapshot_a_code, snapshot_a_output = run_gate(["--snapshot"], pr_a)
            self.assertEqual(0, snapshot_a_code, snapshot_a_output)
            self.assertEqual(
                feedback_a, json.loads(snapshot_a_output)["pr_feedback_digest"]
            )
            self.assertEqual([], json.loads(snapshot_a_output)["pr_feedback_ids"])

            subprocess.run(
                ["git", "switch", "review"], cwd=repo, check=True, capture_output=True
            )
            (repo / "file.txt").write_text("head b\n")
            subprocess.run(
                ["git", "commit", "-am", "head b"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            head_b = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repo,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            pr_b, feedback_b = github_snapshot(head_b)
            stale_a_code, stale_a_output = run_gate([], pr_b)
            self.assertEqual(1, stale_a_code)
            self.assertIn(
                "current HEAD does not match review HEAD",
                json.loads(stale_a_output)["errors"],
            )

            record_b = deepcopy(record_a)
            record_b.update(review_head=head_b, current_head=head_b, pr_head=head_b)
            record_b["passes"] = []
            record_b["pr_feedback_digest"] = feedback_b
            capture(record_b, failed_pass="core-correctness")
            incomplete_b_code, incomplete_b_output = run_gate([], pr_b)
            self.assertEqual(1, incomplete_b_code)
            self.assertIn(
                "required pass core-correctness is failed",
                json.loads(incomplete_b_output)["errors"],
            )
            self.assertEqual(
                [],
                json.loads(incomplete_b_output)["handoff_actions"],
            )

            record_b["passes"] = []
            for item in record_a["passes"]:
                record_b["passes"].append(
                    {
                        **item,
                        "review_base": base,
                        "review_head": head_b,
                        "evidence": f"{item['name']} freshly completed on {head_b}",
                    }
                )
            record_b["pr_feedback_digest"] = feedback_b
            subprocess.run(
                ["git", "push", "fork", "review"],
                cwd=repo,
                check=True,
                capture_output=True,
            )
            capture(record_b)
            clean_b_code, clean_b_output = run_gate([], pr_b)
            self.assertEqual(0, clean_b_code, clean_b_output)
            self.assertEqual(
                ["publish_implementation_artifact", "move_human_review"],
                json.loads(clean_b_output)["handoff_actions"],
            )

    def test_grotto_resolves_the_same_gate_script(self):
        repo = Path(__file__).resolve().parents[5]
        shared = (
            repo
            / "workflows/agavemindlab/skills/phase-implementation/scripts/review_gate.py"
        )
        inherited = (
            repo / "workflows/grotto/skills/phase-implementation/scripts/review_gate.py"
        )
        shared_producer = shared.with_name("review_producer.py")
        inherited_producer = inherited.with_name("review_producer.py")

        self.assertEqual(shared.resolve(), inherited.resolve())
        self.assertEqual(shared_producer.resolve(), inherited_producer.resolve())


if __name__ == "__main__":
    unittest.main()
