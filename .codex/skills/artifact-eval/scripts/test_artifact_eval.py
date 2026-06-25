import os
import shutil
import subprocess
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
