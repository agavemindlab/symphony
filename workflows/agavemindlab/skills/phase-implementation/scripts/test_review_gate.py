import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path


SCRIPT = Path(__file__).with_name("review_gate.py")


def load_gate():
    spec = importlib.util.spec_from_file_location("review_gate", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReviewGateTest(unittest.TestCase):
    def setUp(self):
        self.gate = load_gate()
        self.head = "b" * 40
        self.base = "a" * 40
        self.record = {
            "review_base": self.base,
            "review_head": self.head,
            "current_head": self.head,
            "pr_head": self.head,
            "pr_url": "https://github.com/example/repo/pull/1",
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
            "applicability": {
                "api-contract": {"required": False, "reason": "no API change"},
                "migration": {"required": False, "reason": "no state migration"},
                "design": {"required": True},
            },
            "passes": [],
            "findings": [],
        }
        self.record["passes"] = [self.pass_record(name) for name in self.gate.ALWAYS_PASSES]
        self.record["passes"].append(self.pass_record("design"))

    def pass_record(self, name, status="completed"):
        return {
            "name": name,
            "status": status,
            "review_base": self.base,
            "review_head": self.head,
            "evidence": f"{name} completed on frozen range",
        }

    def errors(self, record=None):
        return self.gate.evaluate(record or self.record)

    def test_small_and_large_code_diffs_require_the_same_core_matrix(self):
        self.assertEqual([], self.errors())

        large = deepcopy(self.record)
        large["diff_size"] = "large"
        self.assertEqual([], self.errors(large))

        for size in ("small", "large"):
            missing = deepcopy(self.record)
            missing["diff_size"] = size
            missing["passes"] = [item for item in missing["passes"] if item["name"] != "performance"]
            self.assertIn("missing required pass: performance", self.errors(missing))

    def test_failed_timeout_unavailable_and_unparsable_passes_fail_closed(self):
        for status in ("failed", "timeout", "unavailable", "unparsable"):
            record = deepcopy(self.record)
            record["passes"] = [
                self.pass_record(item["name"], status if item["name"] == "red-team" else "completed")
                for item in record["passes"]
            ]
            self.assertIn(f"required pass red-team is {status}", self.errors(record))

    def test_real_home_write_allowlist_and_fixed_config_are_fail_closed(self):
        self.assertEqual([], self.errors())

        for path in (
            "$HOME/.claude/session-env/leak",
            "$HOME/.codex/config.toml",
            "/tmp/unrelated",
            "/tmp/codex-adv-1234/child",
            "/private/tmp/codex-review-5678/child",
        ):
            outside = deepcopy(self.record)
            outside["writes"].append(path)
            self.assertIn(f"write outside review allowlist: {path}", self.errors(outside))

        bad_config = deepcopy(self.record)
        bad_config["config"]["telemetry"] = "community"
        self.assertIn("config telemetry must be 'off'", self.errors(bad_config))

    def test_findings_are_validated_dismissed_or_downgraded_before_action(self):
        true_finding = {
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
            "disposition": "dismissed",
            "reporter": "security-reviewer",
            "validator": "validator-2",
            "path": "lib/upload.ex",
            "line": 82,
            "validation_evidence": "static trace proves the lock covers both writes",
        }
        overstated = {
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
        record["findings"] = [false_finding, overstated]
        self.assertEqual([], self.errors(record))

        record["findings"].append(true_finding)
        self.assertIn("validated blocking finding remains: lib/upload.ex:47", self.errors(record))

        true_finding["blocking"] = False
        self.assertIn("validated blocking finding remains: lib/upload.ex:47", self.errors(record))

        invalid_severity = deepcopy(self.record)
        invalid_finding = deepcopy(overstated)
        invalid_finding["final_severity"] = "urgent"
        invalid_severity["findings"] = [invalid_finding]
        self.assertIn("finding 1 has invalid final severity", self.errors(invalid_severity))

        raw = deepcopy(self.record)
        raw["findings"] = [{"path": "lib/raw.ex", "line": 1}]
        self.assertIn("finding 1 has invalid disposition", self.errors(raw))

        biased = deepcopy(self.record)
        biased_finding = deepcopy(overstated)
        biased_finding["auditor"] = biased_finding["reporter"]
        biased["findings"] = [biased_finding]
        self.assertIn("finding 1 lacks an independent severity auditor", self.errors(biased))

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

    def test_cli_reads_the_real_git_head_and_invalidates_commit_a_after_commit_b(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            (repo / "file.txt").write_text("base\n")
            subprocess.run(["git", "add", "file.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "base"], cwd=repo, check=True, capture_output=True)
            base = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
            ).stdout.strip()
            upstream = root / "upstream.git"
            subprocess.run(["git", "init", "--bare", upstream], check=True, capture_output=True)
            subprocess.run(["git", "remote", "add", "upstream", upstream], cwd=repo, check=True)
            subprocess.run(["git", "push", "upstream", "main"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "remote", "add", "origin", upstream], cwd=repo, check=True)
            fork = root / "fork.git"
            subprocess.run(["git", "init", "--bare", fork], check=True, capture_output=True)
            subprocess.run(["git", "remote", "add", "fork", fork], cwd=repo, check=True)
            subprocess.run(["git", "switch", "-c", "review"], cwd=repo, check=True, capture_output=True)
            (repo / "file.txt").write_text("head a\n")
            subprocess.run(["git", "commit", "-am", "head a"], cwd=repo, check=True, capture_output=True)
            head_a = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
            ).stdout.strip()
            subprocess.run(["git", "push", "-u", "fork", "review"], cwd=repo, check=True, capture_output=True)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_gh = fake_bin / "gh"
            fake_gh.write_text("#!/bin/sh\nprintf '%s\\n' \"$GH_PR_HEAD\"\n")
            fake_gh.chmod(0o755)
            env_a = {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}", "GH_PR_HEAD": head_a}

            record_a = deepcopy(self.record)
            record_a.update(review_base=base, review_head=head_a, current_head=head_a, pr_head=head_a)
            record_a["passes"] = [
                {**item, "review_base": base, "review_head": head_a} for item in record_a["passes"]
            ]
            record_path = root / "record.json"
            record_path.write_text(json.dumps(record_a))
            clean_a = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env=env_a,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, clean_a.returncode, clean_a.stdout)

            (repo / "file.txt").write_text("head b\n")
            subprocess.run(["git", "commit", "-am", "head b"], cwd=repo, check=True, capture_output=True)
            stale_a = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env=env_a,
                capture_output=True,
                text=True,
            )
            self.assertEqual(1, stale_a.returncode)
            self.assertIn("current HEAD does not match review HEAD", json.loads(stale_a.stdout)["errors"])

            head_b = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
            ).stdout.strip()
            record_b = deepcopy(record_a)
            record_b.update(review_head=head_b, current_head=head_b, pr_head=head_b)
            record_b["passes"] = []
            record_path.write_text(json.dumps(record_b))
            incomplete_b = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env={**env_a, "GH_PR_HEAD": head_b},
                capture_output=True,
                text=True,
            )
            self.assertEqual(1, incomplete_b.returncode)
            self.assertIn("missing required pass: core-correctness", json.loads(incomplete_b.stdout)["errors"])

            record_b["passes"] = [
                {**item, "review_base": base, "review_head": head_b} for item in record_a["passes"]
            ]
            record_path.write_text(json.dumps(record_b))
            subprocess.run(["git", "push", "fork", "review"], cwd=repo, check=True, capture_output=True)
            clean_b = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env={**env_a, "GH_PR_HEAD": head_b},
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, clean_b.returncode, clean_b.stdout)

    def test_cli_exit_code_blocks_handoff_for_incomplete_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "record.json"
            incomplete = deepcopy(self.record)
            incomplete["passes"] = []
            path.write_text(json.dumps(incomplete))
            result = subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True)

        self.assertEqual(1, result.returncode)
        self.assertEqual("non-clean", json.loads(result.stdout)["verdict"])

    def test_grotto_resolves_the_same_gate_script(self):
        repo = Path(__file__).resolve().parents[5]
        shared = repo / "workflows/agavemindlab/skills/phase-implementation/scripts/review_gate.py"
        inherited = repo / "workflows/grotto/skills/phase-implementation/scripts/review_gate.py"

        self.assertEqual(shared.resolve(), inherited.resolve())


if __name__ == "__main__":
    unittest.main()
