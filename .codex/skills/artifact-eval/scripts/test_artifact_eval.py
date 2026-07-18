import shutil
import subprocess
import sys
import unittest
from copy import deepcopy
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import artifact_eval


class ArtifactEvalTest(unittest.TestCase):
    def setUp(self) -> None:
        root = Path.cwd() / ".symphony" / "artifact-eval-tests"
        root.mkdir(parents=True, exist_ok=True)
        self.tmp = root / self.id().rsplit(".", 1)[-1]
        if self.tmp.exists():
            shutil.rmtree(self.tmp)
        self.tmp.mkdir()
        self.repo_root = Path.cwd()
        self.base_sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=self.repo_root,
            text=True,
        ).strip()

    def tearDown(self) -> None:
        if self.tmp.exists():
            shutil.rmtree(self.tmp)

    def write_case(
        self,
        name: str,
        *,
        required_context: list[dict[str, object]] | None = None,
        patch: str = "",
    ) -> Path:
        case_dir = self.tmp / name
        (case_dir / "linear").mkdir(parents=True)
        (case_dir / "repo" / "untracked" / "notes").mkdir(parents=True)
        (case_dir / "symphony").mkdir()
        (case_dir / "workflow").mkdir()

        (case_dir / "linear" / "issue.json").write_text(
            '{"identifier":"DEV-5387","title":"fixture"}\n',
        )
        (case_dir / "linear" / "artifact_thread.json").write_text(
            '{"id":"comment-1","body":"## Design"}\n',
        )
        (case_dir / "repo" / "base_sha.txt").write_text(f"{self.base_sha}\n")
        (case_dir / "repo" / "workspace.patch").write_text(patch)
        (case_dir / "repo" / "untracked_manifest.json").write_text(
            '{"files":[{"path":"notes/captured.txt","source":"repo/untracked/notes/captured.txt"}]}\n',
        )
        (case_dir / "repo" / "untracked" / "notes" / "captured.txt").write_text(
            "captured file\n",
        )
        (case_dir / "symphony" / "workpad.md").write_text("---\ncurrent_phase: Design\n---\n")
        (case_dir / "workflow" / "hashes.json").write_text(
            '{"files":[{"path":"workflows/agavemindlab/WORKFLOW.md","sha256":"captured"}]}\n',
        )
        (case_dir / "case.json").write_text(
            artifact_eval.json_dumps(
                {
                    "schema_version": 1,
                    "source_url": "https://linear.app/grandline/issue/DEV-5387#comment-comment-1",
                    "phase": "Design",
                    "repo": {
                        "base_sha": self.base_sha,
                        "patch": "repo/workspace.patch",
                        "untracked_manifest": "repo/untracked_manifest.json",
                    },
                    "linear": {
                        "issue": "linear/issue.json",
                        "artifact_thread": "linear/artifact_thread.json",
                    },
                    "symphony": {"allowlist": ["symphony/workpad.md"]},
                    "workflow": {"current_hashes": "workflow/hashes.json"},
                    "required_context": required_context or [],
                },
            ),
        )
        return case_dir

    def test_validate_case_reports_missing_required_files(self) -> None:
        case_dir = self.write_case("missing-required")
        (case_dir / "linear" / "issue.json").unlink()

        with self.assertRaisesRegex(artifact_eval.CaseError, "linear/issue.json"):
            artifact_eval.validate_case(case_dir)

    def test_replay_rebuilds_workspace_from_patch_and_untracked_files(self) -> None:
        patch = """diff --git a/artifact-eval-patched.txt b/artifact-eval-patched.txt
new file mode 100644
index 0000000..b6fc4c6
--- /dev/null
+++ b/artifact-eval-patched.txt
@@ -0,0 +1 @@
+from patch
"""
        case_dir = self.write_case("rebuild", patch=patch)

        result = artifact_eval.replay_case(
            case_dir,
            repo_root=self.repo_root,
            replay_root=self.tmp / "replays",
        )

        self.assertEqual(result.status, "PASS")
        self.assertTrue((result.workspace_path / "artifact-eval-patched.txt").is_file())
        self.assertEqual(
            (result.workspace_path / "notes" / "captured.txt").read_text(),
            "captured file\n",
        )
        self.assertTrue(result.draft_path.is_file())
        self.assertIn("PASS", result.report_path.read_text())

    def test_replay_reports_missing_context_before_creating_workspace(self) -> None:
        case_dir = self.write_case(
            "missing-context",
            required_context=[
                {
                    "kind": "external_file",
                    "path": "/outside/repo/context.md",
                    "captured": False,
                },
            ],
        )

        result = artifact_eval.replay_case(
            case_dir,
            repo_root=self.repo_root,
            replay_root=self.tmp / "replays",
        )

        self.assertEqual(result.status, "MISSING_CONTEXT")
        self.assertIsNone(result.workspace_path)
        self.assertIn("MISSING_CONTEXT", result.report_path.read_text())
        self.assertIn("/outside/repo/context.md", result.report_path.read_text())
        self.assertFalse((self.tmp / "replays").exists())

    def test_capture_audit_has_no_write_side_effect_commands(self) -> None:
        source = (Path(__file__).with_name("artifact_eval.py")).read_text()

        forbidden = [
            "commentCreate",
            "commentUpdate",
            "commentResolve",
            "issueUpdate",
            "git push",
            "git commit",
        ]
        for token in forbidden:
            self.assertNotIn(token, source)

    def test_discovery_fixture_requires_complete_read_only_history(self) -> None:
        fixture = artifact_eval.read_json(
            Path(__file__).resolve().parents[1] / "fixtures" / "design-discovery-cases.json",
        )

        cases = artifact_eval.validate_discovery_fixture(fixture)

        self.assertEqual(len(cases), 2)
        self.assertEqual(
            {candidate["status"] for case in cases for candidate in case["linear_history"]},
            {"Done", "Duplicate"},
        )

    def test_discovery_fixture_rejects_missing_evidence(self) -> None:
        fixture = artifact_eval.read_json(
            Path(__file__).resolve().parents[1] / "fixtures" / "design-discovery-cases.json",
        )
        broken = deepcopy(fixture)
        broken["cases"][0]["linear_history"][0]["comments"] = []
        broken["cases"][0]["linear_history"][1]["comments"] = []

        with self.assertRaisesRegex(artifact_eval.CaseError, "comment evidence"):
            artifact_eval.validate_discovery_fixture(broken)

        invalid = deepcopy(fixture)
        invalid["cases"][0]["linear_history"][0]["comments"] = [""]
        with self.assertRaisesRegex(artifact_eval.CaseError, "comments evidence"):
            artifact_eval.validate_discovery_fixture(invalid)

        invalid_pr = deepcopy(fixture)
        invalid_pr["cases"][0]["linear_history"][0]["prs"] = [True]
        with self.assertRaisesRegex(artifact_eval.CaseError, "prs evidence"):
            artifact_eval.validate_discovery_fixture(invalid_pr)

        missing_pr = deepcopy(fixture)
        for candidate in missing_pr["cases"][0]["linear_history"]:
            candidate["prs"] = []
        with self.assertRaisesRegex(artifact_eval.CaseError, "linked PR evidence"):
            artifact_eval.validate_discovery_fixture(missing_pr)

        missing_query = deepcopy(fixture)
        missing_query["cases"][0]["linear_query"] = ""
        with self.assertRaisesRegex(artifact_eval.CaseError, "linear_query"):
            artifact_eval.validate_discovery_fixture(missing_query)

    def test_discovery_fixture_rejects_missing_or_late_sentry_discovery(self) -> None:
        fixture = artifact_eval.read_json(
            Path(__file__).resolve().parents[1] / "fixtures" / "design-discovery-cases.json",
        )
        missing = deepcopy(fixture)
        del missing["cases"][0]["sentry"]
        with self.assertRaisesRegex(artifact_eval.CaseError, "target event detail"):
            artifact_eval.validate_discovery_fixture(missing)

        late = deepcopy(fixture)
        late["cases"][0]["discovery_order"] = [
            "linear_history",
            "root_cause",
            "approach",
            "target_sentry_event",
            "sentry_siblings",
        ]
        with self.assertRaisesRegex(artifact_eval.CaseError, "precede diagnosis"):
            artifact_eval.validate_discovery_fixture(late)

        invalid_identifier = deepcopy(fixture)
        invalid_identifier["cases"][0]["linear_history"][0]["identifier"] = True
        with self.assertRaisesRegex(artifact_eval.CaseError, "Done or Duplicate"):
            artifact_eval.validate_discovery_fixture(invalid_identifier)

        invalid_target = deepcopy(fixture)
        invalid_target["cases"][0]["sentry"]["target_event"] = True
        with self.assertRaisesRegex(artifact_eval.CaseError, "target event detail"):
            artifact_eval.validate_discovery_fixture(invalid_target)

        invalid_sibling = deepcopy(fixture)
        invalid_sibling["cases"][0]["sentry"]["siblings"] = [True]
        with self.assertRaisesRegex(artifact_eval.CaseError, "valid siblings"):
            artifact_eval.validate_discovery_fixture(invalid_sibling)

        for sibling_count in (1, artifact_eval.MAX_DISCOVERY_CANDIDATES):
            boundary = deepcopy(fixture)
            boundary["cases"][0]["sentry"]["siblings"] = [
                f"sibling-{index}" for index in range(sibling_count)
            ]
            artifact_eval.validate_discovery_fixture(boundary)

        for sibling_count in (0, artifact_eval.MAX_DISCOVERY_CANDIDATES + 1):
            boundary = deepcopy(fixture)
            boundary["cases"][0]["sentry"]["siblings"] = [
                f"sibling-{index}" for index in range(sibling_count)
            ]
            with self.assertRaisesRegex(artifact_eval.CaseError, "valid siblings"):
                artifact_eval.validate_discovery_fixture(boundary)

    def test_discovery_fixture_rejects_mutation_or_unbounded_candidates(self) -> None:
        fixture = artifact_eval.read_json(
            Path(__file__).resolve().parents[1] / "fixtures" / "design-discovery-cases.json",
        )
        mutation = deepcopy(fixture)
        mutation["cases"][0]["allowed_operations"] = ["read", "issueUpdate"]
        with self.assertRaisesRegex(artifact_eval.CaseError, "read-only"):
            artifact_eval.validate_discovery_fixture(mutation)

        history_source = fixture["cases"][0]["linear_history"][0]
        for history_count in (1, artifact_eval.MAX_DISCOVERY_CANDIDATES):
            boundary = deepcopy(fixture)
            boundary["cases"][0]["linear_history"] = [
                deepcopy(history_source) for _ in range(history_count)
            ]
            artifact_eval.validate_discovery_fixture(boundary)

        for history_count, error in (
            (0, "requires Linear history"),
            (artifact_eval.MAX_DISCOVERY_CANDIDATES + 1, "at most 5"),
        ):
            boundary = deepcopy(fixture)
            boundary["cases"][0]["linear_history"] = [
                deepcopy(history_source) for _ in range(history_count)
            ]
            with self.assertRaisesRegex(artifact_eval.CaseError, error):
                artifact_eval.validate_discovery_fixture(boundary)

    def test_capture_skips_untracked_symlinks(self) -> None:
        target = self.tmp / "outside-secret.txt"
        target.write_text("do not capture\n")
        link = self.tmp / "untracked-link"
        link.symlink_to(target)

        self.assertFalse(artifact_eval.should_capture_untracked(link, Path("untracked-link")))

    def test_capture_skips_symphony_allowlist_symlinks(self) -> None:
        repo = self.tmp / "repo"
        repo.mkdir()
        subprocess.check_call(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL)
        subprocess.check_call(["git", "config", "user.email", "agent@example.com"], cwd=repo)
        subprocess.check_call(["git", "config", "user.name", "Agent"], cwd=repo)
        (repo / "README.md").write_text("fixture\n")
        subprocess.check_call(["git", "add", "README.md"], cwd=repo)
        subprocess.check_call(["git", "commit", "-m", "init"], cwd=repo, stdout=subprocess.DEVNULL)

        symphony_dir = repo / ".symphony"
        symphony_dir.mkdir()
        outside = self.tmp / "outside-workpad.md"
        outside.write_text("repo-external state\n")
        (symphony_dir / "workpad.md").symlink_to(outside)

        linear_json = self.tmp / "linear.json"
        artifact_eval.write_json(
            linear_json,
            {
                "issue": {"identifier": "DEV-5387"},
                "artifact_thread": {"body": "## Implementation"},
                "required_context": [],
            },
        )

        case_dir = artifact_eval.capture_case(
            "https://linear.app/grandline/issue/DEV-5387/fixture#comment-symlink",
            linear_json,
            self.tmp / "case",
            repo,
            "Implementation",
        )

        self.assertFalse((case_dir / "symphony" / "workpad.md").exists())
        self.assertNotIn(
            "symphony/workpad.md",
            artifact_eval.read_json(case_dir / "case.json")["symphony"]["allowlist"],
        )

    def test_capture_skips_symphony_allowlist_symlinked_directory(self) -> None:
        repo = self.tmp / "repo-dir-link"
        repo.mkdir()
        subprocess.check_call(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL)
        subprocess.check_call(["git", "config", "user.email", "agent@example.com"], cwd=repo)
        subprocess.check_call(["git", "config", "user.name", "Agent"], cwd=repo)
        (repo / "README.md").write_text("fixture\n")
        subprocess.check_call(["git", "add", "README.md"], cwd=repo)
        subprocess.check_call(["git", "commit", "-m", "init"], cwd=repo, stdout=subprocess.DEVNULL)

        outside_symphony = self.tmp / "outside-symphony"
        outside_symphony.mkdir()
        (outside_symphony / "workpad.md").write_text("repo-external state\n")
        (repo / ".symphony").symlink_to(outside_symphony, target_is_directory=True)

        linear_json = self.tmp / "linear-dir-link.json"
        artifact_eval.write_json(
            linear_json,
            {
                "issue": {"identifier": "DEV-5387"},
                "artifact_thread": {"body": "## Implementation"},
                "required_context": [],
            },
        )

        case_dir = artifact_eval.capture_case(
            "https://linear.app/grandline/issue/DEV-5387/fixture#comment-dir-link",
            linear_json,
            self.tmp / "case-dir-link",
            repo,
            "Implementation",
        )

        self.assertFalse((case_dir / "symphony" / "workpad.md").exists())
        self.assertNotIn(
            "symphony/workpad.md",
            artifact_eval.read_json(case_dir / "case.json")["symphony"]["allowlist"],
        )

    def test_capture_skips_nested_issue_secrets_files(self) -> None:
        repo = self.tmp / "repo-issue-secrets"
        repo.mkdir()
        subprocess.check_call(["git", "init"], cwd=repo, stdout=subprocess.DEVNULL)
        subprocess.check_call(["git", "config", "user.email", "agent@example.com"], cwd=repo)
        subprocess.check_call(["git", "config", "user.name", "Agent"], cwd=repo)
        (repo / "README.md").write_text("fixture\n")
        subprocess.check_call(["git", "add", "README.md"], cwd=repo)
        subprocess.check_call(["git", "commit", "-m", "init"], cwd=repo, stdout=subprocess.DEVNULL)

        secrets_dir = repo / ".issue-secrets"
        secrets_dir.mkdir()
        (secrets_dir / "token.txt").write_text("secret\n")

        linear_json = self.tmp / "linear-issue-secrets.json"
        artifact_eval.write_json(
            linear_json,
            {
                "issue": {"identifier": "DEV-5387"},
                "artifact_thread": {"body": "## Implementation"},
                "required_context": [],
            },
        )

        case_dir = artifact_eval.capture_case(
            "https://linear.app/grandline/issue/DEV-5387/fixture#comment-issue-secrets",
            linear_json,
            self.tmp / "case-issue-secrets",
            repo,
            "Implementation",
        )
        manifest = artifact_eval.read_json(case_dir / "repo" / "untracked_manifest.json")

        self.assertNotIn(".issue-secrets/token.txt", [item["path"] for item in manifest["files"]])
        self.assertFalse((case_dir / "repo" / "untracked" / ".issue-secrets" / "token.txt").exists())


if __name__ == "__main__":
    unittest.main()
