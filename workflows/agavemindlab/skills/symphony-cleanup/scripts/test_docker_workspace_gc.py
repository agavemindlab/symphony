import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import docker_workspace_gc


class DockerWorkspaceGcTest(unittest.TestCase):
    def test_active_workspace_projects_normalizes_issue_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            workspace_root = Path(tmp_dir)
            (workspace_root / "DEV-4889").mkdir()
            (workspace_root / "dev-4890").mkdir()
            (workspace_root / "notes.txt").write_text("not a workspace")

            projects = docker_workspace_gc.active_workspace_projects(workspace_root)

        self.assertEqual(
            set(projects),
            {"dev-4889", "dev-4890"},
        )

    def test_plan_orphan_resources_keeps_existing_workspace_resources(self) -> None:
        active_projects = {"dev-4889": Path("/workspaces/DEV-4889")}
        resources = [
            docker_workspace_gc.DockerResource(
                kind="volume",
                identifier="dev-4889_postgres_data",
                name="dev-4889_postgres_data",
                project="dev-4889",
            ),
            docker_workspace_gc.DockerResource(
                kind="volume",
                identifier="dev-9999_postgres_data",
                name="dev-9999_postgres_data",
                project="dev-9999",
            ),
            docker_workspace_gc.DockerResource(
                kind="container",
                identifier="container-id",
                name="dev-9999-backend-1",
                project="dev-9999",
            ),
            docker_workspace_gc.DockerResource(
                kind="network",
                identifier="network-id",
                name="dev-9999_default",
                project="dev-9999",
            ),
            docker_workspace_gc.DockerResource(
                kind="volume",
                identifier="shared-volume",
                name="shared-volume",
                project="dev-9999",
            ),
            docker_workspace_gc.DockerResource(
                kind="volume",
                identifier="other_default",
                name="other_default",
                project="other",
            ),
        ]

        plan = docker_workspace_gc.plan_orphan_resources(resources, active_projects)

        self.assertEqual(
            [(resource.kind, resource.identifier) for resource in plan],
            [
                ("container", "container-id"),
                ("network", "network-id"),
                ("volume", "dev-9999_postgres_data"),
            ],
        )

    def test_removal_commands_use_safe_kind_specific_commands(self) -> None:
        resources = [
            docker_workspace_gc.DockerResource(
                kind="volume",
                identifier="dev-9999_postgres_data",
                name="dev-9999_postgres_data",
                project="dev-9999",
            ),
            docker_workspace_gc.DockerResource(
                kind="container",
                identifier="container-id",
                name="dev-9999-backend-1",
                project="dev-9999",
            ),
            docker_workspace_gc.DockerResource(
                kind="network",
                identifier="network-id",
                name="dev-9999_default",
                project="dev-9999",
            ),
        ]

        commands = docker_workspace_gc.removal_commands(resources)

        self.assertEqual(
            commands,
            [
                ["docker", "rm", "-f", "container-id"],
                ["docker", "network", "rm", "network-id"],
                ["docker", "volume", "rm", "dev-9999_postgres_data"],
            ],
        )


if __name__ == "__main__":
    unittest.main()
