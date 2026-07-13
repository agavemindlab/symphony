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
            "applicability": {
                "api-contract": {"required": False, "reason": "no API change"},
                "migration": {"required": False, "reason": "no state migration"},
                "design": {"required": True},
            },
            "passes": [],
            "raw_findings": [],
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

    def test_plan_command_forces_the_same_dispatch_matrix_for_small_large_and_low_hit_rate(self):
        for size in ("small", "large"):
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "record.json"
                record = deepcopy(self.record)
                record.update(diff_size=size, adaptive_hit_rate=0)
                path.write_text(json.dumps(record))
                result = subprocess.run(
                    [sys.executable, SCRIPT, "--plan", path], capture_output=True, text=True
                )
            self.assertEqual(0, result.returncode, result.stdout)
            self.assertEqual(
                [*self.gate.ALWAYS_PASSES, "design"], json.loads(result.stdout)["passes"]
            )

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
        self.assertIn("audited blocking finding remains: lib/upload.ex:47", self.errors(record))

        true_finding["blocking"] = False
        self.assertIn("audited blocking finding remains: lib/upload.ex:47", self.errors(record))

        invalid_severity = deepcopy(self.record)
        invalid_finding = deepcopy(overstated)
        invalid_finding["final_severity"] = "urgent"
        invalid_severity["raw_findings"] = [{"id": "raw-overstated"}]
        invalid_severity["findings"] = [invalid_finding]
        self.assertIn("finding 1 has invalid final severity", self.errors(invalid_severity))

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
        self.assertIn("finding 1 lacks an independent severity auditor", self.errors(biased))

        padded = deepcopy(self.record)
        padded_finding = deepcopy(overstated)
        padded_finding["validator"] = f" {padded_finding['reporter']} "
        padded["raw_findings"] = [{"id": "raw-overstated"}]
        padded["findings"] = [padded_finding]
        self.assertIn("finding 1 lacks an independent validator", self.errors(padded))

        padded_finding["validator"] = overstated["validator"]
        padded_finding["auditor"] = f" {overstated['validator']} "
        self.assertIn("finding 1 lacks an independent severity auditor", self.errors(padded))

        omitted = deepcopy(self.record)
        omitted["raw_findings"] = [{"id": "raw-p1"}]
        self.assertIn("every raw finding requires exactly one final disposition", self.errors(omitted))

        empty_validator = deepcopy(self.record)
        finding = deepcopy(false_finding)
        finding["validator"] = ""
        empty_validator["raw_findings"] = [{"id": "raw-false"}]
        empty_validator["findings"] = [finding]
        self.assertIn("finding 1 lacks an independent validator", self.errors(empty_validator))

        boolean_line = deepcopy(empty_validator)
        boolean_line["findings"][0]["validator"] = "validator-2"
        boolean_line["findings"][0]["line"] = True
        self.assertIn("finding 1 lacks file:line evidence", self.errors(boolean_line))

        still_p1 = deepcopy(self.record)
        finding = deepcopy(overstated)
        finding["final_severity"] = "P1"
        still_p1["raw_findings"] = [{"id": "raw-overstated"}]
        still_p1["findings"] = [finding]
        self.assertIn("audited blocking finding remains: lib/state.ex:19", self.errors(still_p1))

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
            self.assertIn(f"temporary review path was not cleaned: {temp.name}", self.errors(dirty))

    def test_pr_identity_ci_and_feedback_snapshot_fail_closed(self):
        self.assertEqual(
            ("github.com", "example/repo"),
            self.gate._repo_identity("git@github.com:example/repo.git"),
        )
        self.assertEqual("1", self.gate._pr_number(self.record["pr_url"], "github.com", "example/repo"))
        with self.assertRaisesRegex(ValueError, "does not belong"):
            self.gate._pr_number(
                "https://ghe.example/example/repo/pull/1", "github.com", "example/repo"
            )

        pr = {
            "url": self.record["pr_url"],
            "headRefOid": self.head,
            "baseRefName": "main",
            "state": "OPEN",
            "reviewDecision": "CHANGES_REQUESTED",
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
        self.assertIn("PR has unresolved change requests: reviewer", errors)

        actionable = deepcopy(pr)
        actionable["reviewDecision"] = ""
        actionable["reviews"] = [
            {
                "id": "review-1",
                "author": {"login": "reviewer"},
                "submittedAt": "2026-07-13T09:03:00Z",
                "state": "COMMENTED",
                "body": "Please fix this fallback",
            }
        ]
        actionable["_inline"] = [{"id": 7, "body": "This can fail", "in_reply_to_id": None}]
        errors = []
        self.gate._check_pr(actionable, record, errors)
        self.assertIn("PR feedback dispositions do not match current feedback ids", errors)

        dispositioned = {
            **record,
            "pr_feedback_dispositions": [
                {"id": "review:review-1", "disposition": "addressed", "evidence": "fixed"},
                {"id": "inline:7", "disposition": "dismissed", "evidence": "static trace"},
            ],
        }
        errors = []
        self.gate._check_pr(actionable, dispositioned, errors)
        self.assertNotIn("PR feedback dispositions do not match current feedback ids", errors)

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
            subprocess.run(
                ["git", "remote", "set-url", "upstream", "https://github.com/example/repo.git"],
                cwd=repo,
                check=True,
            )
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
            fake_gh.write_text(
                "#!/bin/sh\n"
                "if [ \"$1 $2\" = \"pr list\" ]; then printf '%s\\n' \"$GH_PR_LIST\"; "
                "elif [ \"$1 $2\" = \"pr view\" ]; then printf '%s\\n' \"$GH_PR_JSON\"; "
                "elif [ \"$1\" = \"api\" ]; then printf '%s\\n' \"$GH_INLINE_JSON\"; fi\n"
            )
            fake_gh.chmod(0o755)
            pr_url = self.record["pr_url"]

            def github_env(head):
                pr = {
                    "url": pr_url,
                    "headRefOid": head,
                    "baseRefName": "main",
                    "state": "OPEN",
                    "reviewDecision": "APPROVED",
                    "statusCheckRollup": [
                        {"name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"}
                    ],
                    "reviews": [],
                    "comments": [],
                }
                return {
                    **os.environ,
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "GH_PR_LIST": json.dumps(
                        [{key: pr[key] for key in ("url", "headRefOid", "baseRefName", "state")}]
                    ),
                    "GH_PR_JSON": json.dumps(pr),
                    "GH_INLINE_JSON": "[]",
                }, self.gate._feedback_digest(pr, [])

            env_a, feedback_a = github_env(head_a)

            record_a = deepcopy(self.record)
            record_a.update(review_base=base, review_head=head_a, current_head=head_a, pr_head=head_a)
            record_a["pr_url"] = pr_url
            record_a["pr_feedback_digest"] = feedback_a
            record_a["passes"] = [
                {**item, "review_base": base, "review_head": head_a} for item in record_a["passes"]
            ]
            record_path = root / "record.json"
            record_path.write_text(json.dumps(record_a))
            subprocess.run(["git", "switch", "--detach"], cwd=repo, check=True, capture_output=True)
            clean_a = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env=env_a,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, clean_a.returncode, clean_a.stdout)
            self.assertEqual(
                ["publish_implementation_artifact", "move_human_review"],
                json.loads(clean_a.stdout)["handoff_actions"],
            )
            snapshot_a = subprocess.run(
                [sys.executable, SCRIPT, "--snapshot", record_path],
                cwd=repo,
                env=env_a,
                capture_output=True,
                text=True,
            )
            self.assertEqual(feedback_a, json.loads(snapshot_a.stdout)["pr_feedback_digest"])

            subprocess.run(["git", "switch", "review"], cwd=repo, check=True, capture_output=True)
            (repo / "file.txt").write_text("head b\n")
            subprocess.run(["git", "commit", "-am", "head b"], cwd=repo, check=True, capture_output=True)
            head_b = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
            ).stdout.strip()
            stale_a = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env=github_env(head_b)[0],
                capture_output=True,
                text=True,
            )
            self.assertEqual(1, stale_a.returncode)
            self.assertIn("current HEAD does not match review HEAD", json.loads(stale_a.stdout)["errors"])

            record_b = deepcopy(record_a)
            record_b.update(review_head=head_b, current_head=head_b, pr_head=head_b)
            record_b["passes"] = []
            record_b["pr_feedback_digest"] = github_env(head_b)[1]
            record_path.write_text(json.dumps(record_b))
            incomplete_b = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env=github_env(head_b)[0],
                capture_output=True,
                text=True,
            )
            self.assertEqual(1, incomplete_b.returncode)
            self.assertIn("missing required pass: core-correctness", json.loads(incomplete_b.stdout)["errors"])
            self.assertEqual(
                [],
                json.loads(incomplete_b.stdout)["handoff_actions"],
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
            record_b["pr_feedback_digest"] = github_env(head_b)[1]
            record_path.write_text(json.dumps(record_b))
            subprocess.run(["git", "push", "fork", "review"], cwd=repo, check=True, capture_output=True)
            clean_b = subprocess.run(
                [sys.executable, SCRIPT, record_path],
                cwd=repo,
                env=github_env(head_b)[0],
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, clean_b.returncode, clean_b.stdout)
            self.assertEqual(
                ["publish_implementation_artifact", "move_human_review"],
                json.loads(clean_b.stdout)["handoff_actions"],
            )

    def test_grotto_resolves_the_same_gate_script(self):
        repo = Path(__file__).resolve().parents[5]
        shared = repo / "workflows/agavemindlab/skills/phase-implementation/scripts/review_gate.py"
        inherited = repo / "workflows/grotto/skills/phase-implementation/scripts/review_gate.py"

        self.assertEqual(shared.resolve(), inherited.resolve())


if __name__ == "__main__":
    unittest.main()
