#!/usr/bin/env python3
"""Prune Docker resources for Symphony workspaces that no longer exist."""

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


DEFAULT_PROJECT_REGEX = r"^[a-z][a-z0-9]*-[0-9][a-z0-9_-]*$"
PROJECT_LABEL = "com.docker.compose.project"
RESOURCE_ORDER = {
    "container": 0,
    "network": 1,
    "volume": 2,
}


@dataclass(frozen=True)
class DockerResource:
    kind: str
    identifier: str
    name: str
    project: str


def normalize_workspace_name(name: str) -> str | None:
    normalized = re.sub(r"[^a-z0-9_-]+", "", name.lower()).strip("_-")
    if not normalized or not re.match(r"^[a-z0-9]", normalized):
        return None
    return normalized


def active_workspace_projects(workspace_root: Path) -> dict[str, Path]:
    projects: dict[str, Path] = {}
    for child in workspace_root.iterdir():
        if not child.is_dir():
            continue
        project = normalize_workspace_name(child.name)
        if project is None:
            continue
        projects[project] = child
    return projects


def resource_has_project_prefix(resource: DockerResource) -> bool:
    name = resource.name.lstrip("/")
    return (
        name == resource.project
        or name.startswith(f"{resource.project}_")
        or name.startswith(f"{resource.project}-")
    )


def sort_resources(resources: list[DockerResource]) -> list[DockerResource]:
    return sorted(
        resources,
        key=lambda resource: (
            RESOURCE_ORDER.get(resource.kind, 99),
            resource.project,
            resource.name,
        ),
    )


def plan_orphan_resources(
    resources: list[DockerResource],
    active_projects: dict[str, Path],
    project_regex: str = DEFAULT_PROJECT_REGEX,
) -> list[DockerResource]:
    pattern = re.compile(project_regex)
    planned: list[DockerResource] = []
    for resource in resources:
        if resource.project in active_projects:
            continue
        if not pattern.fullmatch(resource.project):
            continue
        if not resource_has_project_prefix(resource):
            continue
        planned.append(resource)
    return sort_resources(planned)


def removal_commands(resources: list[DockerResource]) -> list[list[str]]:
    commands: list[list[str]] = []
    for resource in sort_resources(resources):
        if resource.kind == "container":
            commands.append(["docker", "rm", "-f", resource.identifier])
        elif resource.kind == "network":
            commands.append(["docker", "network", "rm", resource.identifier])
        elif resource.kind == "volume":
            commands.append(["docker", "volume", "rm", resource.identifier])
        else:
            raise ValueError(f"Unsupported Docker resource kind: {resource.kind}")
    return commands


def run_docker(args: list[str]) -> str:
    completed = subprocess.run(
        args,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or "Docker command failed")
    return completed.stdout


def inspect_docker(kind: str, identifiers: list[str]) -> list[dict[str, object]]:
    if not identifiers:
        return []
    stdout = run_docker(["docker", kind, "inspect", *identifiers])
    return json.loads(stdout)


def docker_labels(item: dict[str, object]) -> dict[str, str]:
    labels = item.get("Labels") or {}
    if not labels and isinstance(item.get("Config"), dict):
        labels = item["Config"].get("Labels") or {}
    return dict(labels)


def collect_volumes() -> list[DockerResource]:
    stdout = run_docker(
        [
            "docker",
            "volume",
            "ls",
            "--filter",
            f"label={PROJECT_LABEL}",
            "--format",
            "{{.Name}}",
        ],
    )
    names = [line.strip() for line in stdout.splitlines() if line.strip()]
    resources: list[DockerResource] = []
    for item in inspect_docker("volume", names):
        labels = docker_labels(item)
        project = labels.get(PROJECT_LABEL)
        name = str(item.get("Name") or "")
        if project and name:
            resources.append(
                DockerResource(
                    kind="volume",
                    identifier=name,
                    name=name,
                    project=project,
                ),
            )
    return resources


def collect_containers() -> list[DockerResource]:
    stdout = run_docker(
        [
            "docker",
            "ps",
            "-a",
            "--filter",
            f"label={PROJECT_LABEL}",
            "--format",
            "{{.ID}}",
        ],
    )
    identifiers = [line.strip() for line in stdout.splitlines() if line.strip()]
    resources: list[DockerResource] = []
    for item in inspect_docker("container", identifiers):
        labels = docker_labels(item)
        project = labels.get(PROJECT_LABEL)
        identifier = str(item.get("Id") or "")
        name = str(item.get("Name") or "").lstrip("/")
        if project and identifier and name:
            resources.append(
                DockerResource(
                    kind="container",
                    identifier=identifier,
                    name=name,
                    project=project,
                ),
            )
    return resources


def collect_networks() -> list[DockerResource]:
    stdout = run_docker(
        [
            "docker",
            "network",
            "ls",
            "--filter",
            f"label={PROJECT_LABEL}",
            "--format",
            "{{.ID}}",
        ],
    )
    identifiers = [line.strip() for line in stdout.splitlines() if line.strip()]
    resources: list[DockerResource] = []
    for item in inspect_docker("network", identifiers):
        labels = docker_labels(item)
        project = labels.get(PROJECT_LABEL)
        identifier = str(item.get("Id") or "")
        name = str(item.get("Name") or "")
        if project and identifier and name:
            resources.append(
                DockerResource(
                    kind="network",
                    identifier=identifier,
                    name=name,
                    project=project,
                ),
            )
    return resources


def collect_docker_resources() -> list[DockerResource]:
    return [*collect_containers(), *collect_networks(), *collect_volumes()]


def print_plan(resources: list[DockerResource], apply: bool) -> None:
    mode = "Applying cleanup for" if apply else "Dry run: would remove"
    if not resources:
        print("No orphan Symphony Docker resources found.")
        return
    print(f"{mode} {len(resources)} orphan Docker resource(s):")
    for resource in resources:
        print(
            f"- {resource.kind} {resource.name} "
            f"(project={resource.project}, id={resource.identifier})",
        )


def apply_cleanup(resources: list[DockerResource]) -> int:
    failures = 0
    for command in removal_commands(resources):
        completed = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if completed.returncode != 0:
            failures += 1
            print(
                completed.stderr.strip() or completed.stdout.strip(),
                file=sys.stderr,
            )
    return 1 if failures else 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prune Docker resources for removed Symphony workspaces.",
    )
    parser.add_argument(
        "--workspace-root",
        default=os.environ.get("SYMPHONY_WORKSPACE_ROOT"),
        help="Symphony workspace root. Defaults to SYMPHONY_WORKSPACE_ROOT.",
    )
    parser.add_argument(
        "--project-regex",
        default=DEFAULT_PROJECT_REGEX,
        help="Regex for Symphony Compose project names eligible for cleanup.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Remove orphan resources. Without this flag, only print a dry-run plan.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if not args.workspace_root:
        raise SystemExit(
            "Set SYMPHONY_WORKSPACE_ROOT or pass --workspace-root before running cleanup.",
        )
    workspace_root = Path(args.workspace_root).expanduser().resolve()
    if not workspace_root.is_dir():
        raise SystemExit(f"Workspace root does not exist: {workspace_root}")

    active_projects = active_workspace_projects(workspace_root)
    resources = collect_docker_resources()
    plan = plan_orphan_resources(resources, active_projects, args.project_regex)
    print_plan(plan, args.apply)
    if args.apply:
        return apply_cleanup(plan)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
