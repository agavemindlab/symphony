defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap, StringOrStringList}
  alias SymphonyElixir.Linear.Client

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace identity marker match reuses directory without rerunning after_create" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-identity-match-#{System.unique_integer([:positive])}"
      )

    with_project_env("project-slug", "symphony", fn ->
      try do
        after_create_counter = Path.join(workspace_root, "after-create.count")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo call >> #{after_create_counter}\necho current > repo.txt"
        )

        issue = %Issue{
          id: "issue-identity-match",
          identifier: "MT-IDENTITY-MATCH",
          title: "Identity match",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "project-slug", name: "Project Name"}
        }

        assert {:ok, first_workspace} = Workspace.create_for_issue(issue)
        assert {:ok, second_workspace} = Workspace.create_for_issue(issue)

        assert second_workspace == first_workspace
        assert File.read!(after_create_counter) == "call\n"
        assert {:ok, project_env} = Workflow.resolve_project_env(issue)
        assert :ok = Workspace.validate_identity(first_workspace, issue, project_env)

        changed_project_env = put_in(project_env, [:env, "SYMPHONY_REPO"], "grotto")

        assert {:error, {:workspace_identity_changed, {:quarantine, :marker_mismatch}}} =
                 Workspace.validate_identity(first_workspace, issue, changed_project_env)

        assert workspace_identity_marker(first_workspace) == %{
                 "version" => 1,
                 "linear_project_id" => "project-id",
                 "linear_project_slug_id" => "project-slug",
                 "linear_project_name" => "Project Name",
                 "workflow_dir" => Path.dirname(Workflow.workflow_file_path()),
                 "workflow_file" => Workflow.workflow_file_path(),
                 "symphony_project_slug" => "project-slug",
                 "symphony_repo" => "symphony"
               }
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "workspace identity marker mismatch quarantines stale directory before after_create" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-identity-mismatch-#{System.unique_integer([:positive])}"
      )

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        workspace = Path.join(workspace_root, "MT-IDENTITY-MISMATCH")
        after_create_counter = Path.join(workspace_root, "after-create.count")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo call >> #{after_create_counter}\necho new > repo.txt"
        )

        File.mkdir_p!(workspace)
        File.write!(Path.join(workspace, "repo.txt"), "old\n")
        assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        write_workspace_identity_marker!(workspace, %{
          "version" => 1,
          "linear_project_id" => "old-project-id",
          "linear_project_slug_id" => "grotto-slug",
          "linear_project_name" => "Grotto",
          "workflow_dir" => Path.dirname(Workflow.workflow_file_path()),
          "workflow_file" => Workflow.workflow_file_path(),
          "symphony_project_slug" => "grotto-slug",
          "symphony_repo" => "grotto"
        })

        issue = %Issue{
          id: "issue-identity-mismatch",
          identifier: "MT-IDENTITY-MISMATCH",
          title: "Identity mismatch",
          state: "In Progress",
          project: %{id: "new-project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:ok, ^canonical_workspace} = Workspace.create_for_issue(issue)

        [quarantine] = Path.wildcard(Path.join(workspace_root, "MT-IDENTITY-MISMATCH.quarantine.*"))
        assert File.read!(Path.join(quarantine, "repo.txt")) == "old\n"
        assert File.read!(Path.join(workspace, "repo.txt")) == "new\n"
        assert File.read!(after_create_counter) == "call\n"
        assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "malformed workspace identity marker quarantines stale directory" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-workspace-identity-malformed-#{System.unique_integer([:positive])}")

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        workspace = Path.join(workspace_root, "MT-IDENTITY-MALFORMED")
        marker = Path.join(workspace, ".symphony/workspace-identity.json")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo new > repo.txt"
        )

        File.mkdir_p!(Path.dirname(marker))
        File.write!(Path.join(workspace, "repo.txt"), "old\n")
        File.write!(marker, "{partial")

        issue = %Issue{
          id: "issue-identity-malformed",
          identifier: "MT-IDENTITY-MALFORMED",
          title: "Malformed identity",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:ok, _workspace} = Workspace.create_for_issue(issue)
        [quarantine] = Path.wildcard(Path.join(workspace_root, "MT-IDENTITY-MALFORMED.quarantine.*"))
        assert File.read!(Path.join(quarantine, "repo.txt")) == "old\n"
        assert File.read!(Path.join(workspace, "repo.txt")) == "new\n"
        assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"

        oversized = Path.join(workspace_root, "MT-IDENTITY-OVERSIZED")
        oversized_marker = Path.join(oversized, ".symphony/workspace-identity.json")
        File.mkdir_p!(Path.dirname(oversized_marker))
        File.write!(oversized_marker, String.duplicate("x", 65_537))

        oversized_issue = %{
          issue
          | id: "issue-identity-oversized",
            identifier: "MT-IDENTITY-OVERSIZED",
            title: "Oversized identity"
        }

        assert {:ok, _workspace} = Workspace.create_for_issue(oversized_issue)
        assert [_quarantine] = Path.wildcard(Path.join(workspace_root, "MT-IDENTITY-OVERSIZED.quarantine.*"))
        assert workspace_identity_marker(oversized)["symphony_repo"] == "symphony"

        fifo = Path.join(workspace_root, "MT-IDENTITY-FIFO")
        fifo_marker = Path.join(fifo, ".symphony/workspace-identity.json")
        File.mkdir_p!(Path.dirname(fifo_marker))
        assert {_output, 0} = System.cmd("mkfifo", [fifo_marker])
        fifo_issue = %{issue | id: "issue-identity-fifo", identifier: "MT-IDENTITY-FIFO", title: "FIFO identity"}
        task = Task.async(fn -> Workspace.create_for_issue(fifo_issue) end)
        assert {:ok, {:ok, _workspace}} = Task.yield(task, 5_000)
        assert [_quarantine] = Path.wildcard(Path.join(workspace_root, "MT-IDENTITY-FIFO.quarantine.*"))
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "symlinked workspace identity directory is quarantined without writing outside the workspace" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-workspace-identity-symlink-#{System.unique_integer([:positive])}")

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-IDENTITY-SYMLINK")
        outside = Path.join(test_root, "outside")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo new > repo.txt"
        )

        File.mkdir_p!(workspace)
        File.mkdir_p!(outside)
        File.write!(Path.join(outside, "sentinel"), "keep\n")
        File.ln_s!(outside, Path.join(workspace, ".symphony"))
        assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
        assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", "git@github.com:agavemindlab/symphony.git"], cd: workspace)

        issue = %Issue{
          id: "issue-identity-symlink",
          identifier: "MT-IDENTITY-SYMLINK",
          title: "Symlinked identity",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:ok, _workspace} = Workspace.create_for_issue(issue)
        assert [_quarantine] = Path.wildcard(Path.join(workspace_root, "MT-IDENTITY-SYMLINK.quarantine.*"))
        assert File.read!(Path.join(outside, "sentinel")) == "keep\n"
        refute File.exists?(Path.join(outside, "workspace-identity.json"))
        assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"
      after
        File.rm_rf(test_root)
      end
    end)
  end

  test "after_create cannot replace the workspace with an in-root symlink before marker write" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-workspace-post-hook-symlink-#{System.unique_integer([:positive])}")

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        sibling = Path.join(workspace_root, "sibling")
        File.mkdir_p!(sibling)
        File.write!(Path.join(sibling, "sentinel"), "keep\n")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "cd .. && rmdir MT-POST-HOOK-SYMLINK && ln -s sibling MT-POST-HOOK-SYMLINK"
        )

        issue = %Issue{
          id: "issue-post-hook-symlink",
          identifier: "MT-POST-HOOK-SYMLINK",
          title: "Post-hook workspace symlink",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:error, :unsafe_marker_path} = Workspace.create_for_issue(issue)
        assert File.read!(Path.join(sibling, "sentinel")) == "keep\n"
        refute File.exists?(Path.join(sibling, ".symphony/workspace-identity.json"))
        refute File.exists?(Path.join(workspace_root, "MT-POST-HOOK-SYMLINK"))

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo new > repo.txt"
        )

        assert {:ok, workspace} = Workspace.create_for_issue(issue)
        assert {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)
        assert workspace == Path.join(canonical_root, "MT-POST-HOOK-SYMLINK")
        assert File.read!(Path.join(workspace, "repo.txt")) == "new\n"
        assert File.read!(Path.join(sibling, "sentinel")) == "keep\n"
        assert Path.wildcard(Path.join(workspace_root, "sibling.quarantine.*")) == []
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "legacy no-marker workspace with matching git remote backfills marker and reuses" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-legacy-match-#{System.unique_integer([:positive])}"
      )

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        workspace = Path.join(workspace_root, "MT-LEGACY-MATCH")
        after_create_counter = Path.join(workspace_root, "after-create.count")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo call >> #{after_create_counter}"
        )

        File.mkdir_p!(workspace)
        assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
        assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", "git@github.com:agavemindlab/symphony.git"], cd: workspace)
        File.write!(Path.join(workspace, "local-progress.txt"), "keep\n")
        assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        issue = %Issue{
          id: "issue-legacy-match",
          identifier: "MT-LEGACY-MATCH",
          title: "Legacy match",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:ok, ^canonical_workspace} = Workspace.create_for_issue(issue)
        assert File.read!(Path.join(workspace, "local-progress.txt")) == "keep\n"
        refute File.exists?(after_create_counter)
        assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "legacy no-marker workspace with mismatching git remote is quarantined" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-legacy-mismatch-#{System.unique_integer([:positive])}"
      )

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        workspace = Path.join(workspace_root, "MT-LEGACY-MISMATCH")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo new > repo.txt"
        )

        File.mkdir_p!(workspace)
        assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
        assert {_output, 0} = System.cmd("git", ["remote", "add", "origin", "https://github.com/agavemindlab/grotto.git"], cd: workspace)
        File.write!(Path.join(workspace, "repo.txt"), "old\n")
        assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        issue = %Issue{
          id: "issue-legacy-mismatch",
          identifier: "MT-LEGACY-MISMATCH",
          title: "Legacy mismatch",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:ok, ^canonical_workspace} = Workspace.create_for_issue(issue)

        [quarantine] = Path.wildcard(Path.join(workspace_root, "MT-LEGACY-MISMATCH.quarantine.*"))
        assert File.read!(Path.join(quarantine, "repo.txt")) == "old\n"
        assert File.read!(Path.join(workspace, "repo.txt")) == "new\n"
        assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "legacy no-marker workspace with unknown git remote is quarantined" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-legacy-unknown-#{System.unique_integer([:positive])}"
      )

    with_project_env("symphony-slug", "symphony", fn ->
      try do
        workspace = Path.join(workspace_root, "MT-LEGACY-UNKNOWN")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          hook_after_create: "echo new > repo.txt"
        )

        File.mkdir_p!(workspace)
        assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace)
        File.write!(Path.join(workspace, "repo.txt"), "old\n")
        assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        issue = %Issue{
          id: "issue-legacy-unknown",
          identifier: "MT-LEGACY-UNKNOWN",
          title: "Legacy unknown",
          state: "In Progress",
          project: %{id: "project-id", slug_id: "symphony-slug", name: "Symphony"}
        }

        assert {:ok, ^canonical_workspace} = Workspace.create_for_issue(issue)

        [quarantine] = Path.wildcard(Path.join(workspace_root, "MT-LEGACY-UNKNOWN.quarantine.*"))
        assert File.read!(Path.join(quarantine, "repo.txt")) == "old\n"
        assert File.read!(Path.join(workspace, "repo.txt")) == "new\n"
        assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"
      after
        File.rm_rf(workspace_root)
      end
    end)
  end

  test "aggregate project resolver chooses effective repo before workspace reuse" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-aggregate-identity-#{System.unique_integer([:positive])}"
      )

    previous_repo = System.get_env("SYMPHONY_REPO")
    previous_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")
    original_workflow_path = Workflow.workflow_file_path()

    try do
      workflow_dir = Path.join(test_root, "workflows/grandline")
      project_dir = Path.join(test_root, "workflows/symphony")
      workflow_file = Path.join(workflow_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-AGGREGATE-IDENTITY")

      File.mkdir_p!(workflow_dir)
      File.mkdir_p!(project_dir)
      Workflow.set_workflow_file_path(workflow_file)

      File.write!(Path.join(project_dir, "project.env"), """
      SYMPHONY_PROJECT_SLUG="symphony-slug"
      SYMPHONY_REPO="symphony"
      """)

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), """
      case "${SYMPHONY_LINEAR_PROJECT_SLUG:-}" in
        symphony-slug) SYMPHONY_PROJECT_DIR="$SYMPHONY_WORKFLOW_DIR/../symphony" ;;
        *) echo "unknown project: ${SYMPHONY_LINEAR_PROJECT_SLUG:-}" >&2; exit 66 ;;
      esac
      SYMPHONY_PROJECT_DIR="$(cd "$SYMPHONY_PROJECT_DIR" && pwd)"
      set -a
      . "$SYMPHONY_PROJECT_DIR/project.env"
      set +a
      export SYMPHONY_PROJECT_DIR
      """)

      write_workflow_file!(workflow_file,
        workspace_root: workspace_root,
        hook_after_create: "echo symphony > repo.txt"
      )

      System.put_env("SYMPHONY_REPO", "wrong-process-repo")
      System.put_env("SYMPHONY_PROJECT_SLUG", "wrong-process-slug")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "repo.txt"), "old\n")

      write_workspace_identity_marker!(workspace, %{
        "version" => 1,
        "linear_project_id" => "old-project-id",
        "linear_project_slug_id" => "grotto-slug",
        "linear_project_name" => "Grotto",
        "workflow_dir" => workflow_dir,
        "workflow_file" => workflow_file,
        "symphony_project_slug" => "grotto-slug",
        "symphony_repo" => "grotto"
      })

      issue = %Issue{
        id: "issue-aggregate-identity",
        identifier: "MT-AGGREGATE-IDENTITY",
        title: "Aggregate identity",
        state: "In Progress",
        project: %{id: "new-project-id", slug_id: "symphony-slug", name: "Symphony"}
      }

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue(issue)
      [quarantine] = Path.wildcard(Path.join(workspace_root, "MT-AGGREGATE-IDENTITY.quarantine.*"))
      assert File.read!(Path.join(quarantine, "repo.txt")) == "old\n"
      assert File.read!(Path.join(workspace, "repo.txt")) == "symphony\n"
      assert workspace_identity_marker(workspace)["symphony_repo"] == "symphony"
      assert workspace_identity_marker(workspace)["symphony_project_slug"] == "symphony-slug"
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      restore_env("SYMPHONY_REPO", previous_repo)
      restore_env("SYMPHONY_PROJECT_SLUG", previous_project_slug)
      File.rm_rf(test_root)
    end
  end

  test "workflow project env resolver merges only compatible process project env" do
    previous_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")
    previous_repo = System.get_env("SYMPHONY_REPO")

    try do
      issue = %Issue{
        id: 123,
        identifier: "MT-PROJECT-ENV-COMPAT",
        title: "Project env compatibility",
        project: %{id: 123, slug_id: "project-slug", name: "Project"}
      }

      System.delete_env("SYMPHONY_PROJECT_SLUG")
      System.put_env("SYMPHONY_REPO", "repo-from-process")
      assert {:ok, %{env: env}} = Workflow.resolve_project_env(issue)
      assert env["SYMPHONY_REPO"] == "repo-from-process"
      assert env["SYMPHONY_LINEAR_PROJECT_ID"] == "123"

      System.put_env("SYMPHONY_PROJECT_SLUG", "")
      assert {:ok, %{env: env}} = Workflow.resolve_project_env(issue)
      assert env["SYMPHONY_REPO"] == "repo-from-process"

      System.put_env("SYMPHONY_PROJECT_SLUG", "other-project")
      assert {:ok, %{env: env}} = Workflow.resolve_project_env(issue)
      refute Map.has_key?(env, "SYMPHONY_REPO")

      empty_slug_issue = %Issue{
        id: "empty-project-id",
        identifier: "MT-PROJECT-ENV-EMPTY",
        title: "Project env empty slug",
        project: %{id: "empty-project-id", slug_id: "", name: "Project"}
      }

      assert {:ok, %{env: env}} = Workflow.resolve_project_env(empty_slug_issue)
      assert env["SYMPHONY_REPO"] == "repo-from-process"
    after
      restore_env("SYMPHONY_PROJECT_SLUG", previous_project_slug)
      restore_env("SYMPHONY_REPO", previous_repo)
    end
  end

  test "project issue without effective repo or project slug fails before reusing existing workspace" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-project-env-missing-#{System.unique_integer([:positive])}"
      )

    previous_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")
    previous_repo = System.get_env("SYMPHONY_REPO")

    try do
      workspace = Path.join(workspace_root, "MT-MISSING-PROJECT-ENV")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo new > repo.txt"
      )

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "repo.txt"), "old\n")
      System.put_env("SYMPHONY_PROJECT_SLUG", "other-project")
      System.put_env("SYMPHONY_REPO", "stale-repo")

      issue = %Issue{
        id: "issue-missing-project-env",
        identifier: "MT-MISSING-PROJECT-ENV",
        title: "Missing project env",
        state: "In Progress",
        project: %{id: "project-id", slug_id: "project-slug", name: "Project"}
      }

      assert {:error, {:workspace_identity_missing_project_env, missing_keys}} =
               Workspace.create_for_issue(issue)

      assert Enum.sort(missing_keys) == ["SYMPHONY_PROJECT_SLUG", "SYMPHONY_REPO"]
      assert File.read!(Path.join(workspace, "repo.txt")) == "old\n"
      assert Path.wildcard(Path.join(workspace_root, "MT-MISSING-PROJECT-ENV.quarantine.*")) == []
      refute File.exists?(Path.join(workspace, ".symphony/workspace-identity.json"))
    after
      restore_env("SYMPHONY_PROJECT_SLUG", previous_project_slug)
      restore_env("SYMPHONY_REPO", previous_repo)
      File.rm_rf(workspace_root)
    end
  end

  test "workflow project env resolver uses selector output and surfaces selector failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workflow-project-env-resolver-#{System.unique_integer([:positive])}"
      )

    original_workflow_path = Workflow.workflow_file_path()

    try do
      workflow_dir = Path.join(test_root, "workflows/grandline")
      workflow_file = Path.join(workflow_dir, "WORKFLOW.md")
      File.mkdir_p!(workflow_dir)
      Workflow.set_workflow_file_path(workflow_file)
      write_workflow_file!(workflow_file)

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), """
      printf 'selector noise\\n' >&2
      SYMPHONY_PROJECT_SLUG="project-slug"
      SYMPHONY_REPO="symphony"
      """)

      raw_issue = %{
        "project" => %{
          "id" => "project-id",
          "slugId" => "project-slug",
          "name" => "Symphony"
        }
      }

      assert {:ok, %{env: env}} = Workflow.resolve_project_env(raw_issue)
      assert env["SYMPHONY_LINEAR_PROJECT_ID"] == "project-id"
      assert env["SYMPHONY_PROJECT_SLUG"] == "project-slug"
      assert env["SYMPHONY_REPO"] == "symphony"

      injection_marker = Path.join(test_root, "injected")

      injected_issue =
        put_in(
          raw_issue,
          ["project", "name"],
          "Symphony\n__SYMPHONY_PROJECT_ENV__\tX; touch #{injection_marker}; #\tdg=="
        )

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), """
      SYMPHONY_PROJECT_SLUG="project-slug"
      SYMPHONY_REPO="symphony"
      """)

      assert {:error, {:invalid_project_env_value, "SYMPHONY_LINEAR_PROJECT_NAME"}} =
               Workflow.resolve_project_env(injected_issue)

      refute File.exists?(injection_marker)

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), """
      printf '%s\n' '__SYMPHONY_PROJECT_ENV__\tX; touch #{injection_marker}; #\tdg==' >&2
      SYMPHONY_PROJECT_SLUG="project-slug"
      SYMPHONY_REPO="symphony"
      """)

      assert {:error, {:invalid_project_env_key, _key}} = Workflow.resolve_project_env(raw_issue)
      refute File.exists?(injection_marker)

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), """
      printf '%s\n' '__SYMPHONY_PROJECT_ENV__\tSYMPHONY_REPO\t%%%' >&2
      """)

      assert {:error, {:invalid_project_env_value, "SYMPHONY_REPO"}} =
               Workflow.resolve_project_env(raw_issue)

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), "exit 0\n")
      assert {:error, :incomplete_project_env_output} = Workflow.resolve_project_env(raw_issue)

      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), """
      printf 'selector failed\\n' >&2
      exit 66
      """)

      assert {:error, {:project_env_resolve_failed, 66, output}} =
               Workflow.resolve_project_env(raw_issue)

      assert output =~ "selector failed"

      write_workflow_file!(workflow_file, hook_timeout_ms: 10)
      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), "sleep 1\n")
      assert {:error, {:project_env_resolve_timeout, 10}} = Workflow.resolve_project_env(raw_issue)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end

  test "projectless issue does not source aggregate selector before workspace reuse" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-projectless-aggregate-workspace-#{System.unique_integer([:positive])}"
      )

    original_workflow_path = Workflow.workflow_file_path()

    try do
      workflow_dir = Path.join(test_root, "workflows/grandline")
      workflow_file = Path.join(workflow_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workflow_dir)
      Workflow.set_workflow_file_path(workflow_file)
      File.write!(Path.join(workflow_dir, "project-for-linear-project.sh"), "exit 66\n")

      write_workflow_file!(workflow_file, workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PROJECTLESS-AGGREGATE")
      assert Path.basename(workspace) == "MT-PROJECTLESS-AGGREGATE"
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end

  test "workspace creation cleans failed new workspace before retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-retry-after-hook-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      attempts_file = Path.join(test_root, "attempts")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        attempts_file="#{attempts_file}"
        attempts=$(cat "$attempts_file" 2>/dev/null || printf 0)
        attempts=$((attempts + 1))
        printf '%s' "$attempts" > "$attempts_file"
        printf 'partial attempt %s\\n' "$attempts" > partial.txt
        if [ "$attempts" -eq 1 ]; then
          exit 42
        fi
        printf 'initialized\\n' > initialized.txt
        """
      )

      assert {:error, {:workspace_hook_failed, "after_create", 42, _output}} =
               Workspace.create_for_issue("MT-RETRY")

      assert File.read!(attempts_file) == "1"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-RETRY")
      assert File.read!(attempts_file) == "2"
      assert File.read!(Path.join(workspace, "initialized.txt")) == "initialized\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear issue routing requires every configured label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], assigned_to_worker: true}

    assert Issue.routable?(issue, [])
    assert Issue.routable?(issue, ["symphony"])
    assert Issue.routable?(issue, ["SYMPHONY", "javascript"])
    refute Issue.routable?(issue, ["symph"])
    refute Issue.routable?(issue, [" "])
    refute Issue.routable?(issue, ["symphony", "security"])
    refute Issue.routable?(%{issue | assigned_to_worker: false}, ["symphony"])
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "project" => %{
        "id" => "project-1",
        "slugId" => "project-one",
        "name" => "Project One"
      },
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
    assert issue.project == %{id: "project-1", slug_id: "project-one", name: "Project One"}
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client can use an explicit api key without mutating tracker auth" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "symphony-token")

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "usr_maestro"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               api_key: "maestro-token",
               request_fun: fn _payload, headers ->
                 assert {"Authorization", "maestro-token"} in headers
                 refute {"Authorization", "symphony-token"} in headers

                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr_maestro"}}}}}
               end
             )

    assert Config.settings!().tracker.api_key == "symphony-token"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "orchestrator global concurrency is shared across project issues" do
    running_issue = %Issue{
      id: "issue-project-a",
      identifier: "MT-A",
      title: "Project A issue",
      state: "Todo",
      project: %{id: "project-a-id", slug_id: "project-a", name: "Project A"}
    }

    next_issue = %Issue{
      id: "issue-project-b",
      identifier: "MT-B",
      title: "Project B issue",
      state: "Todo",
      project: %{id: "project-b-id", slug_id: "project-b", name: "Project B"}
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{
        running_issue.id => %{issue: running_issue, worker_host: nil}
      },
      claimed: MapSet.new([running_issue.id]),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(next_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(next_issue, %{state | max_concurrent_agents: 2})
  end

  test "multiple configured projects expand effective default dispatch slots" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: Enum.map(1..12, &"project-#{&1}")
    )

    running_issues =
      Enum.map(1..10, fn i ->
        %Issue{
          id: "issue-#{i}",
          identifier: "MT-#{i}",
          title: "Project #{i} issue",
          state: "Todo",
          project: %{id: "project-#{i}-id", slug_id: "project-#{i}", name: "Project #{i}"}
        }
      end)

    next_issue = %Issue{
      id: "issue-11",
      identifier: "MT-11",
      title: "Project 11 issue",
      state: "Todo",
      project: %{id: "project-11-id", slug_id: "project-11", name: "Project 11"}
    }

    state = %Orchestrator.State{
      max_concurrent_agents: nil,
      running: Enum.into(running_issues, %{}, fn ri -> {ri.id, %{issue: ri, worker_host: nil}} end),
      claimed: MapSet.new(Enum.map(running_issues, & &1.id)),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert Orchestrator.should_dispatch_issue_for_test(next_issue, state)
  end

  test "explicit max_concurrent_agents is strictly respected and not expanded by projects" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: ["project-a", "project-b"],
      max_concurrent_agents: 1
    )

    running_issue = %Issue{
      id: "issue-project-a",
      identifier: "MT-A",
      title: "Project A issue",
      state: "Todo",
      project: %{id: "project-a-id", slug_id: "project-a", name: "Project A"}
    }

    next_issue = %Issue{
      id: "issue-project-b",
      identifier: "MT-B",
      title: "Project B issue",
      state: "Todo",
      project: %{id: "project-b-id", slug_id: "project-b", name: "Project B"}
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{
        running_issue.id => %{issue: running_issue, worker_host: nil}
      },
      claimed: MapSet.new([running_issue.id]),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(next_issue, state)
  end

  for issue_state <- ["Todo", "In Progress", "Rework", "Merging"] do
    test "#{issue_state} issue with non-terminal blocker is not dispatch-eligible" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"]
      )

      state = %Orchestrator.State{
        max_concurrent_agents: 3,
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: "blocked-1",
        identifier: "MT-1001",
        title: "Blocked work",
        state: unquote(issue_state),
        blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
      }

      log =
        capture_log(fn ->
          refute Orchestrator.should_dispatch_issue_for_test(issue, state)
        end)

      assert log =~ "blocked_by=1"
    end
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "active issue with terminal blockers remains dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Merging",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "active issue without blockers remains dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-2",
      identifier: "MT-1010",
      title: "Ready work",
      state: "Rework",
      blocked_by: []
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale active issue once a non-terminal blocker appears" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"]
    )

    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "In Progress",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "In Progress",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads issue running and stopped hooks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "echo running",
      hook_issue_stopped: "echo stopped"
    )

    config = Config.settings!()
    assert String.trim(config.hooks.issue_running) == "echo running"
    assert String.trim(config.hooks.issue_stopped) == "echo stopped"
  end

  test "issue run hook receives issue context and runs from workflow directory" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-hook-context-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(marker) end)

    command = """
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
      "$PWD" \
      "$SYMPHONY_WORKFLOW_DIR" \
      "$SYMPHONY_HOOK_EVENT" \
      "$SYMPHONY_HOOK_REASON" \
      "$SYMPHONY_ISSUE_ID" \
      "$SYMPHONY_ISSUE_IDENTIFIER" \
      "$SYMPHONY_ISSUE_STATE" \
      "$SYMPHONY_ISSUE_URL" \
      "${SYMPHONY_WORKER_HOST:-}" > "#{marker}"
    """

    write_workflow_file!(Workflow.workflow_file_path(), hook_issue_running: command)

    issue = %Issue{
      id: "issue-hook-context",
      identifier: "MT-HOOK",
      title: "Hook context",
      state: "In Progress",
      url: "https://linear.example/MT-HOOK"
    }

    assert :ok =
             SymphonyElixir.IssueRunHook.run(:running, issue,
               worker_host: "worker-a",
               reason: "dispatch"
             )

    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    assert {:ok, canonical_workflow_dir} = SymphonyElixir.PathSafety.canonicalize(workflow_dir)

    assert File.read!(marker) ==
             Enum.join(
               [
                 canonical_workflow_dir,
                 workflow_dir,
                 "running",
                 "dispatch",
                 "issue-hook-context",
                 "MT-HOOK",
                 "In Progress",
                 "https://linear.example/MT-HOOK",
                 "worker-a"
               ],
               "|"
             )
  end

  test "issue run hook failures are logged and ignored" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "echo marker failed && exit 17"
    )

    issue = %Issue{
      id: "issue-hook-fail",
      identifier: "MT-HOOK-FAIL",
      title: "Hook failure",
      state: "In Progress"
    }

    log =
      capture_log(fn ->
        assert :ok = SymphonyElixir.IssueRunHook.run(:running, issue, reason: "dispatch")
      end)

    assert log =~ "Issue run hook failed"
    assert log =~ "hook=issue_running"
    assert log =~ "status=17"
  end

  test "issue run hook keeps failures ignored when analytics recording raises" do
    previous_analytics_file = Application.get_env(:symphony_elixir, :analytics_file)
    Application.put_env(:symphony_elixir, :analytics_file, :bad_path)

    on_exit(fn ->
      if is_nil(previous_analytics_file) do
        Application.delete_env(:symphony_elixir, :analytics_file)
      else
        Application.put_env(:symphony_elixir, :analytics_file, previous_analytics_file)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), hook_issue_running: "exit 17")

    issue = %Issue{id: "issue-hook-analytics-fail", identifier: "MT-HOOK-ANALYTICS-FAIL"}

    log =
      capture_log(fn ->
        assert :ok = SymphonyElixir.IssueRunHook.run(:running, issue, reason: "dispatch")
      end)

    assert log =~ "Failed to record hook_failed analytics event"
    assert log =~ "hook=issue_running"
  end

  test "issue run hook ignores unsupported events" do
    issue = %Issue{
      id: "issue-hook-unsupported",
      identifier: "MT-HOOK-UNSUPPORTED",
      title: "Unsupported hook",
      state: "In Progress"
    }

    refute SymphonyElixir.IssueRunHook.configured?(:unsupported)
    assert :ok = SymphonyElixir.IssueRunHook.run(:unsupported, issue, reason: "dispatch")
  end

  test "issue run hook stringifies non-binary option values" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-hook-non-binary-env-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(marker) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "printf '%s|%s' \"$SYMPHONY_HOOK_REASON\" \"$SYMPHONY_WORKER_HOST\" > #{marker}"
    )

    issue = %Issue{
      id: "issue-hook-non-binary",
      identifier: "MT-HOOK-NON-BINARY",
      title: "Non-binary hook opts",
      state: "In Progress"
    }

    assert :ok =
             SymphonyElixir.IssueRunHook.run(:running, issue,
               reason: :dispatch,
               worker_host: 123
             )

    assert File.read!(marker) == "dispatch|123"
  end

  test "issue run hook truncates long failure output in logs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "python3 -c 'import sys; sys.stdout.write(\"x\" * 3000); sys.exit(17)'"
    )

    issue = %Issue{
      id: "issue-hook-long-failure",
      identifier: "MT-HOOK-LONG-FAILURE",
      title: "Long hook failure",
      state: "In Progress"
    }

    log =
      capture_log(fn ->
        assert :ok = SymphonyElixir.IssueRunHook.run(:running, issue, reason: "dispatch")
      end)

    assert log =~ "Issue run hook failed"
    assert log =~ "hook=issue_running"
    assert log =~ "... (truncated)"
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)

      %{events: events} = SymphonyElixir.Analytics.read_events()

      assert Enum.any?(events, fn event ->
               event["event_type"] == "hook_failed" and
                 event["hook"] == "before_remove" and
                 event["issue_identifier"] == "MT-HOOKS-FAIL"
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config reads observability analytics path from workflow" do
    previous_analytics_file = Application.get_env(:symphony_elixir, :analytics_file)

    on_exit(fn ->
      if is_nil(previous_analytics_file) do
        Application.delete_env(:symphony_elixir, :analytics_file)
      else
        Application.put_env(:symphony_elixir, :analytics_file, previous_analytics_file)
      end
    end)

    Application.delete_env(:symphony_elixir, :analytics_file)

    analytics_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-analytics-#{System.unique_integer([:positive])}.ndjson"
      )

    write_workflow_file!(Workflow.workflow_file_path(), observability_analytics_path: analytics_path)

    config = Config.settings!()
    assert config.observability.analytics_path == analytics_path
    assert SymphonyElixir.Analytics.file_path() == analytics_path

    home_relative_path = Path.join(["~", "symphony", "events.ndjson"])

    write_workflow_file!(Workflow.workflow_file_path(), observability_analytics_path: home_relative_path)

    config = Config.settings!()
    assert config.observability.analytics_path == Path.expand(home_relative_path)
    assert SymphonyElixir.Analytics.file_path() == Path.expand(home_relative_path)
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    project_slug_env_var = "SYMP_LINEAR_PROJECT_SLUG_#{System.unique_integer([:positive])}"
    project_slugs_env_var = "SYMP_LINEAR_PROJECT_SLUGS_#{System.unique_integer([:positive])}"
    missing_project_slugs_env_var = "SYMP_MISSING_LINEAR_PROJECT_SLUGS_#{System.unique_integer([:positive])}"
    project_names_env_var = "SYMP_LINEAR_PROJECT_NAMES_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    project_slug = "resolved-project-slug"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)
    previous_project_slug = System.get_env(project_slug_env_var)
    previous_project_slugs = System.get_env(project_slugs_env_var)
    previous_missing_project_slugs = System.get_env(missing_project_slugs_env_var)
    previous_project_names = System.get_env(project_names_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)
    System.put_env(project_slug_env_var, project_slug)
    System.put_env(project_slugs_env_var, " project-a,project-b,project-a ")
    System.delete_env(missing_project_slugs_env_var)
    System.put_env(project_names_env_var, " grotto,symphony,grotto ")

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
      restore_env(project_slug_env_var, previous_project_slug)
      restore_env(project_slugs_env_var, previous_project_slugs)
      restore_env(missing_project_slugs_env_var, previous_missing_project_slugs)
      restore_env(project_names_env_var, previous_project_names)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      tracker_project_slug: "$#{project_slug_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.tracker.project_slug == project_slug
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      tracker_project_slug: nil,
      tracker_project_slugs: "$#{project_slugs_env_var}",
      workspace_root: "$#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.project_slug == nil
    assert config.tracker.project_slugs == ["project-a", "project-b"]
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      tracker_project_slug: nil,
      tracker_project_slugs: "$#{missing_project_slugs_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.project_slugs == []

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      tracker_project_slug: nil,
      tracker_project_names: "$#{project_names_env_var}",
      workspace_root: "$#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.project_names == ["grotto", "symphony"]
    assert :ok = Config.validate!()
  end

  test "string-or-string-list schema type accepts only strings or string lists" do
    assert StringOrStringList.type() == :any
    assert StringOrStringList.embed_as(:json) == :self
    assert StringOrStringList.equal?(["project-a"], ["project-a"])

    assert StringOrStringList.cast("project-a") == {:ok, "project-a"}
    assert StringOrStringList.cast(["project-a", "project-b"]) == {:ok, ["project-a", "project-b"]}
    assert StringOrStringList.cast(["project-a", 1]) == :error
    assert StringOrStringList.cast(1) == :error

    assert StringOrStringList.load("project-a") == {:ok, "project-a"}
    assert StringOrStringList.load(1) == :error
    assert StringOrStringList.dump(["project-a"]) == {:ok, ["project-a"]}
    assert StringOrStringList.dump(%{}) == :error
  end

  test "config resolves string and missing env-backed project scopes" do
    project_slugs_env_var = "SYMP_LINEAR_PROJECT_SLUGS_#{System.unique_integer([:positive])}"
    project_names_env_var = "SYMP_LINEAR_PROJECT_NAMES_#{System.unique_integer([:positive])}"
    previous_project_slugs = System.get_env(project_slugs_env_var)
    previous_project_names = System.get_env(project_names_env_var)

    on_exit(fn ->
      restore_env(project_slugs_env_var, previous_project_slugs)
      restore_env(project_names_env_var, previous_project_names)
    end)

    System.delete_env(project_slugs_env_var)
    System.delete_env(project_names_env_var)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: " project-a, project-b, project-a "
    )

    assert Config.settings!().tracker.project_slugs == ["project-a", "project-b"]
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: "$#{project_slugs_env_var}"
    )

    assert Config.settings!().tracker.project_slugs == []
    assert {:error, :missing_linear_project_scope} = Config.validate!()

    assert Schema.configured_project_slugs(%Schema.Tracker{project_slugs: "project-c,project-d"}) ==
             {:ok, ["project-c", "project-d"]}

    assert Schema.configured_project_slugs(%Schema.Tracker{project_slugs: :invalid}) == {:ok, []}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_name: " "
    )

    assert Config.settings!().tracker.project_name == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_names: "$#{project_names_env_var}"
    )

    assert Config.settings!().tracker.project_names == []
    assert {:error, :missing_linear_project_scope} = Config.validate!()

    assert Schema.configured_project_names(%Schema.Tracker{project_names: "grotto,symphony"}) ==
             {:ok, ["grotto", "symphony"]}

    assert Schema.configured_project_names(%Schema.Tracker{project_names: :invalid}) == {:ok, []}
  end

  test "config resolves string project names and missing env-backed project names" do
    project_names_env_var = "SYMP_LINEAR_PROJECT_NAMES_#{System.unique_integer([:positive])}"
    previous_project_names = System.get_env(project_names_env_var)

    on_exit(fn -> restore_env(project_names_env_var, previous_project_names) end)
    System.delete_env(project_names_env_var)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: nil,
      tracker_project_name: nil,
      tracker_project_names: " Project A, Project B, Project A "
    )

    assert Config.settings!().tracker.project_names == ["Project A", "Project B"]
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: nil,
      tracker_project_name: nil,
      tracker_project_names: "$#{project_names_env_var}"
    )

    assert Config.settings!().tracker.project_names == []
    assert {:error, :missing_linear_project_scope} = Config.validate!()

    assert Schema.configured_project_names(%Schema.Tracker{project_names: "Project C,Project D"}) ==
             {:ok, ["Project C", "Project D"]}

    assert Schema.configured_project_names(%Schema.Tracker{project_names: :invalid}) == {:ok, []}

    assert Schema.configured_project_names(%Schema.Tracker{project_names: [" "]}) ==
             {:error, {:invalid_linear_project_names, :blank}}
  end

  test "local workspace hooks receive workflow directory from symlinked workflow path" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workflow-dir-hook-#{System.unique_integer([:positive])}"
      )

    try do
      canonical_dir = Path.join(test_root, "agavemindlab")
      project_dir = Path.join(test_root, "symphony")
      canonical_workflow = Path.join(canonical_dir, "WORKFLOW.md")
      project_workflow = Path.join(project_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before-remove-workflow-dir.txt")

      File.mkdir_p!(canonical_dir)
      File.mkdir_p!(project_dir)

      write_workflow_file!(canonical_workflow,
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"$SYMPHONY_WORKFLOW_DIR\" > after-create-workflow-dir.txt",
        hook_before_remove: "printf '%s' \"$SYMPHONY_WORKFLOW_DIR\" > #{before_remove_marker}"
      )

      File.ln_s!("../agavemindlab/WORKFLOW.md", project_workflow)
      Workflow.set_workflow_file_path(Path.expand(project_workflow))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-WORKFLOW-DIR")

      assert File.read!(Path.join(workspace, "after-create-workflow-dir.txt")) ==
               Path.expand(project_dir)

      assert {:ok, _removed} = Workspace.remove(workspace)
      assert File.read!(before_remove_marker) == Path.expand(project_dir)
    after
      File.rm_rf(test_root)
    end
  end

  test "local workspace hooks receive Linear project environment" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-project-hook-env-#{System.unique_integer([:positive])}"
      )

    previous_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")
    previous_repo = System.get_env("SYMPHONY_REPO")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before-remove-project-env.txt")
      File.mkdir_p!(workspace_root)
      System.put_env("SYMPHONY_PROJECT_SLUG", "project-slug")
      System.put_env("SYMPHONY_REPO", "symphony")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '%s\\n%s\\n%s\\n' \"$SYMPHONY_LINEAR_PROJECT_ID\" \"$SYMPHONY_LINEAR_PROJECT_SLUG\" \"$SYMPHONY_LINEAR_PROJECT_NAME\" > after-create-project-env.txt",
        hook_before_run: "printf '%s\\n%s\\n%s\\n' \"$SYMPHONY_LINEAR_PROJECT_ID\" \"$SYMPHONY_LINEAR_PROJECT_SLUG\" \"$SYMPHONY_LINEAR_PROJECT_NAME\" > before-run-project-env.txt",
        hook_before_remove: "printf '%s\\n%s\\n%s\\n' \"$SYMPHONY_LINEAR_PROJECT_ID\" \"$SYMPHONY_LINEAR_PROJECT_SLUG\" \"$SYMPHONY_LINEAR_PROJECT_NAME\" > #{before_remove_marker}"
      )

      issue = %Issue{
        id: "issue-project-hook",
        identifier: "MT-PROJECT-HOOK",
        title: "Project hook env",
        state: "Todo",
        project: %{id: "project-id", slug_id: "project-slug", name: "Project Name"}
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert :ok = Workspace.run_before_run_hook(workspace, issue)

      assert File.read!(Path.join(workspace, "after-create-project-env.txt")) ==
               "project-id\nproject-slug\nProject Name\n"

      assert File.read!(Path.join(workspace, "before-run-project-env.txt")) ==
               "project-id\nproject-slug\nProject Name\n"

      assert :ok = Workspace.remove_issue_workspaces(issue)
      assert File.read!(before_remove_marker) == "project-id\nproject-slug\nProject Name\n"
    after
      restore_env("SYMPHONY_PROJECT_SLUG", previous_project_slug)
      restore_env("SYMPHONY_REPO", previous_repo)
      File.rm_rf(test_root)
    end
  end

  test "local workspace hooks clear project env omitted by the project selector" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-hook-clear-project-env-#{System.unique_integer([:positive])}")

    original_workflow_path = Workflow.workflow_file_path()
    previous_purpose = System.get_env("SYMPHONY_ACCEPTANCE_USER_PURPOSE")

    try do
      workflow_file = Path.join(test_root, "WORKFLOW.md")
      selector = Path.join(test_root, "project-for-linear-project.sh")
      workspace_root = Path.join(test_root, "workspaces")
      Workflow.set_workflow_file_path(workflow_file)
      System.put_env("SYMPHONY_ACCEPTANCE_USER_PURPOSE", "stale-purpose")

      File.mkdir_p!(test_root)
      File.write!(selector, "SYMPHONY_PROJECT_SLUG=project-slug\nSYMPHONY_REPO=symphony\n")

      write_workflow_file!(workflow_file,
        workspace_root: workspace_root,
        hook_after_create: "printf '%s' \"${SYMPHONY_ACCEPTANCE_USER_PURPOSE:-}\" > acceptance-purpose.txt"
      )

      issue = %Issue{
        id: "issue-hook-clear-project-env",
        identifier: "MT-HOOK-CLEAR-PROJECT-ENV",
        title: "Clear project env",
        state: "Todo",
        project: %{id: "project-id", slug_id: "project-slug", name: "Project"}
      }

      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert File.read!(Path.join(workspace, "acceptance-purpose.txt")) == ""
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      restore_env("SYMPHONY_ACCEPTANCE_USER_PURPOSE", previous_purpose)
      File.rm_rf(test_root)
    end
  end

  test "startup terminal workspace cleanup preserves Linear project environment" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-cleanup-project-env-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    orchestrator_name = Module.concat(__MODULE__, :"TerminalCleanupProjectEnv#{System.unique_integer([:positive])}")

    issue = %Issue{
      id: "issue-terminal-project-hook",
      identifier: "MT-TERMINAL-PROJECT-HOOK",
      title: "Terminal project hook env",
      state: "Closed",
      project: %{id: "terminal-project-id", slug_id: "terminal-project-slug", name: "Terminal Project"}
    }

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "startup-before-remove-project-env.txt")
      File.mkdir_p!(Path.join(workspace_root, issue.identifier))

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        tracker_terminal_states: ["Closed"],
        hook_before_remove: "printf '%s\\n%s\\n%s\\n' \"$SYMPHONY_LINEAR_PROJECT_ID\" \"$SYMPHONY_LINEAR_PROJECT_SLUG\" \"$SYMPHONY_LINEAR_PROJECT_NAME\" > #{before_remove_marker}"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:ok, _pid} = Orchestrator.start_link(name: orchestrator_name)

      assert File.read!(before_remove_marker) ==
               "terminal-project-id\nterminal-project-slug\nTerminal Project\n"

      refute File.exists?(Path.join(workspace_root, issue.identifier))
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)

      if pid = Process.whereis(orchestrator_name) do
        Process.exit(pid, :normal)
      end

      File.rm_rf(test_root)
    end
  end

  test "canonical workflow installs missing skills and preserves repo-owned skills" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workflow-skill-install-#{System.unique_integer([:positive])}"
      )

    workflow_root_env_var = "SYMPHONY_WORKSPACE_ROOT"
    previous_workflow_root = System.get_env(workflow_root_env_var)
    previous_path = System.get_env("PATH")
    previous_clone_source = System.get_env("SYMPHONY_TEST_CLONE_SOURCE")
    previous_fork_owner = System.get_env("GITHUB_FORK_OWNER")
    previous_repo = System.get_env("SYMPHONY_REPO")
    previous_base_branch = System.get_env("SYMPHONY_BASE_BRANCH")
    previous_workflow_dir = System.get_env("SYMPHONY_WORKFLOW_DIR")
    original_workflow_path = Workflow.workflow_file_path()

    try do
      configure_fake_gh_clone!(test_root)

      canonical_workflow = Path.expand("../workflows/agavemindlab/WORKFLOW.md", File.cwd!())
      canonical_skills = Path.expand("../workflows/agavemindlab/skills", File.cwd!())
      canonical_dir = Path.join(test_root, "agavemindlab")
      clone_source = Path.join(test_root, "clone-source")
      fake_bin_dir = Path.join(test_root, "bin")
      project_dir = Path.join(test_root, "symphony")
      project_workflow = Path.join(project_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")
      teardown_marker = Path.join(test_root, "teardown-workflow-dir.txt")

      File.mkdir_p!(canonical_dir)
      File.mkdir_p!(project_dir)
      create_clone_source_repo!(clone_source)
      install_fake_gh!(fake_bin_dir)
      File.ln_s!(canonical_workflow, Path.join(canonical_dir, "WORKFLOW.md"))
      File.ln_s!(canonical_skills, Path.join(canonical_dir, "skills"))
      File.ln_s!("../agavemindlab/WORKFLOW.md", project_workflow)
      File.ln_s!("../agavemindlab/skills", Path.join(project_dir, "skills"))

      File.write!(Path.join(project_dir, "setup.sh"), """
      #!/usr/bin/env bash
      set -euo pipefail

      git init -b main >/dev/null
      git config user.name "Test User"
      git config user.email "test@example.com"
      mkdir -p .agents/skills/linear
      printf 'repo version\\n' > .agents/skills/linear/SKILL.md
      git add .agents/skills/linear/SKILL.md
      git commit -m initial >/dev/null
      """)

      File.write!(Path.join(project_dir, "teardown.sh"), """
      #!/usr/bin/env bash
      set -euo pipefail

      printf '%s' "$SYMPHONY_WORKFLOW_DIR" > #{teardown_marker}
      """)

      File.chmod!(Path.join(project_dir, "setup.sh"), 0o755)
      File.chmod!(Path.join(project_dir, "teardown.sh"), 0o755)

      System.put_env(workflow_root_env_var, workspace_root)
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))
      System.put_env("SYMPHONY_TEST_CLONE_SOURCE", clone_source)
      System.put_env("GITHUB_FORK_OWNER", "test-owner")
      System.put_env("SYMPHONY_REPO", "symphony")
      System.put_env("SYMPHONY_BASE_BRANCH", "main")
      System.delete_env("SYMPHONY_WORKFLOW_DIR")
      Workflow.set_workflow_file_path(Path.expand(project_workflow))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-SKILL-INSTALL")

      assert File.exists?(Path.join([workspace, ".agents", "skills", "phase-implementation", "SKILL.md"]))
      assert File.exists?(Path.join([workspace, ".agents", "skills", "symphony-commit", "SKILL.md"]))
      assert File.exists?(Path.join([workspace, ".agents", "skills", "symphony-linear", "SKILL.md"]))
      assert File.read!(Path.join([workspace, ".agents", "skills", "linear", "SKILL.md"])) == "repo version\n"

      exclude = File.read!(Path.join([workspace, ".git", "info", "exclude"]))
      assert exclude =~ ".agents/skills/phase-implementation"
      assert exclude =~ ".agents/skills/symphony-commit"
      assert exclude =~ ".agents/skills/symphony-linear"
      refute exclude =~ ".agents/skills/linear"

      assert {"", 0} = System.cmd("git", ["-C", workspace, "status", "--short"])

      assert {:ok, _removed} = Workspace.remove(workspace)
      assert File.read!(teardown_marker) == Path.expand(project_dir)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      restore_env(workflow_root_env_var, previous_workflow_root)
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_TEST_CLONE_SOURCE", previous_clone_source)
      restore_env("GITHUB_FORK_OWNER", previous_fork_owner)
      restore_env("SYMPHONY_REPO", previous_repo)
      restore_env("SYMPHONY_BASE_BRANCH", previous_base_branch)
      restore_env("SYMPHONY_WORKFLOW_DIR", previous_workflow_dir)
      File.rm_rf(test_root)
    end
  end

  test "canonical workflow skills expose string metadata for Codex" do
    skills_dir = Path.expand("../workflows/agavemindlab/skills", File.cwd!())

    skills_dir
    |> Path.join("*/SKILL.md")
    |> Path.wildcard()
    |> Enum.each(fn skill_path ->
      metadata = read_skill_front_matter(skill_path)

      assert {:ok, %{"name" => name, "description" => description}} = metadata,
             "#{skill_path} has invalid skill metadata: #{inspect(metadata)}"

      assert is_binary(name), "#{skill_path} has non-string name metadata"
      assert is_binary(description), "#{skill_path} has non-string description metadata"
    end)
  end

  test "running marker script chooses a system CA bundle when Python has no default cafile" do
    ca_bundle = first_existing_ca_bundle!()
    test_root = Path.join(System.tmp_dir!(), "symphony-marker-ca-#{System.unique_integer([:positive])}")
    fake_bin_dir = Path.join(test_root, "bin")
    env_capture = Path.join(test_root, "env.txt")
    script_path = Path.expand("../workflows/agavemindlab/mark-running-issue.sh", File.cwd!())
    previous_path = System.get_env("PATH")

    try do
      File.mkdir_p!(fake_bin_dir)

      File.write!(Path.join(fake_bin_dir, "python3"), """
      #!/usr/bin/env sh
      printf 'SSL_CERT_FILE=%s\\n' "${SSL_CERT_FILE:-}" > #{env_capture}
      printf 'REQUESTS_CA_BUNDLE=%s\\n' "${REQUESTS_CA_BUNDLE:-}" >> #{env_capture}
      printf 'CURL_CA_BUNDLE=%s\\n' "${CURL_CA_BUNDLE:-}" >> #{env_capture}
      """)

      File.chmod!(Path.join(fake_bin_dir, "python3"), 0o755)

      assert {"", 0} =
               System.cmd("sh", [script_path, "running"],
                 env: [
                   {"PATH", fake_bin_dir <> ":" <> (previous_path || "")},
                   {"LINEAR_API_KEY", "test-token"},
                   {"SYMPHONY_ISSUE_ID", "issue-1"},
                   {"SYMPHONY_HOOK_EVENT", "running"},
                   {"SSL_CERT_FILE", nil},
                   {"REQUESTS_CA_BUNDLE", nil},
                   {"CURL_CA_BUNDLE", nil}
                 ],
                 stderr_to_stdout: true
               )

      assert File.read!(env_capture) =~ "SSL_CERT_FILE=#{ca_bundle}\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "canonical workflow surfaces setup failures before installing shared skills" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workflow-setup-failure-#{System.unique_integer([:positive])}"
      )

    workflow_root_env_var = "SYMPHONY_WORKSPACE_ROOT"
    previous_workflow_root = System.get_env(workflow_root_env_var)
    previous_path = System.get_env("PATH")
    previous_clone_source = System.get_env("SYMPHONY_TEST_CLONE_SOURCE")
    previous_fork_owner = System.get_env("GITHUB_FORK_OWNER")
    previous_repo = System.get_env("SYMPHONY_REPO")
    previous_base_branch = System.get_env("SYMPHONY_BASE_BRANCH")
    previous_workflow_dir = System.get_env("SYMPHONY_WORKFLOW_DIR")
    original_workflow_path = Workflow.workflow_file_path()

    try do
      configure_fake_gh_clone!(test_root)

      canonical_workflow = Path.expand("../workflows/agavemindlab/WORKFLOW.md", File.cwd!())
      canonical_skills = Path.expand("../workflows/agavemindlab/skills", File.cwd!())
      canonical_dir = Path.join(test_root, "agavemindlab")
      clone_source = Path.join(test_root, "clone-source")
      fake_bin_dir = Path.join(test_root, "bin")
      project_dir = Path.join(test_root, "symphony")
      project_workflow = Path.join(project_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT_SETUP_FAIL")

      File.mkdir_p!(canonical_dir)
      File.mkdir_p!(project_dir)
      create_clone_source_repo!(clone_source)
      install_fake_gh!(fake_bin_dir)
      File.ln_s!(canonical_workflow, Path.join(canonical_dir, "WORKFLOW.md"))
      File.ln_s!(canonical_skills, Path.join(canonical_dir, "skills"))
      File.ln_s!("../agavemindlab/WORKFLOW.md", project_workflow)
      File.ln_s!("../agavemindlab/skills", Path.join(project_dir, "skills"))

      File.write!(Path.join(project_dir, "setup.sh"), """
      #!/usr/bin/env bash
      printf 'setup failed\\n' >&2
      exit 42
      """)

      File.write!(Path.join(project_dir, "teardown.sh"), """
      #!/usr/bin/env bash
      exit 0
      """)

      File.chmod!(Path.join(project_dir, "setup.sh"), 0o755)
      File.chmod!(Path.join(project_dir, "teardown.sh"), 0o755)

      System.put_env(workflow_root_env_var, workspace_root)
      System.put_env("PATH", fake_bin_dir <> ":" <> (previous_path || ""))
      System.put_env("SYMPHONY_TEST_CLONE_SOURCE", clone_source)
      System.put_env("GITHUB_FORK_OWNER", "test-owner")
      System.put_env("SYMPHONY_REPO", "symphony")
      System.put_env("SYMPHONY_BASE_BRANCH", "main")
      System.delete_env("SYMPHONY_WORKFLOW_DIR")
      Workflow.set_workflow_file_path(Path.expand(project_workflow))

      assert {:error, {:workspace_hook_failed, "after_create", 42, output}} =
               Workspace.create_for_issue("MT-SETUP-FAIL")

      assert output =~ "setup failed"

      refute File.exists?(Path.join([workspace, ".agents", "skills", "symphony-commit", "SKILL.md"]))
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      restore_env(workflow_root_env_var, previous_workflow_root)
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_TEST_CLONE_SOURCE", previous_clone_source)
      restore_env("GITHUB_FORK_OWNER", previous_fork_owner)
      restore_env("SYMPHONY_REPO", previous_repo)
      restore_env("SYMPHONY_BASE_BRANCH", previous_base_branch)
      restore_env("SYMPHONY_WORKFLOW_DIR", previous_workflow_dir)
      File.rm_rf(test_root)
    end
  end

  test "canonical workflow fails fast when workflow directory env is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workflow-dir-missing-#{System.unique_integer([:positive])}"
      )

    workflow_root_env_var = "SYMPHONY_WORKSPACE_ROOT"
    project_slug_env_var = "SYMPHONY_PROJECT_SLUG"
    previous_workflow_root = System.get_env(workflow_root_env_var)
    previous_project_slug = System.get_env(project_slug_env_var)
    original_workflow_path = Workflow.workflow_file_path()

    try do
      canonical_workflow = Path.expand("../workflows/agavemindlab/WORKFLOW.md", File.cwd!())
      workspace = Path.join(test_root, "workspace")

      File.mkdir_p!(workspace)
      System.put_env(workflow_root_env_var, Path.join(test_root, "workspaces"))
      System.put_env(project_slug_env_var, "symphony-test-project")
      Workflow.set_workflow_file_path(canonical_workflow)

      command = Config.settings!().hooks.after_create

      assert {output, status} =
               System.cmd("sh", ["-lc", command],
                 cd: workspace,
                 env: [{"SYMPHONY_WORKFLOW_DIR", nil}],
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "SYMPHONY_WORKFLOW_DIR is not set"
      refute File.exists?(Path.join([workspace, ".agents", "skills"]))
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      restore_env(workflow_root_env_var, previous_workflow_root)
      restore_env(project_slug_env_var, previous_project_slug)
      File.rm_rf(test_root)
    end
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert StringOrStringList.type() == :any
    assert StringOrStringList.embed_as(:json) == :self
    assert StringOrStringList.equal?(["a"], ["a"])
    refute StringOrStringList.equal?(["a"], ["b"])

    assert {:ok, "value"} = StringOrStringList.cast("value")
    assert {:ok, ["a", "b"]} = StringOrStringList.cast(["a", "b"])
    assert :error = StringOrStringList.cast(["a", 1])
    assert :error = StringOrStringList.cast(123)

    assert {:ok, ["a"]} = StringOrStringList.load(["a"])
    assert :error = StringOrStringList.load([1])

    assert {:ok, "a,b"} = StringOrStringList.dump("a,b")
    assert :error = StringOrStringList.dump(%{a: 1})

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]

    assert {:ok, ["project-a", "project-b"]} =
             Schema.configured_project_slugs(%Schema.Tracker{
               project_slug: nil,
               project_slugs: " project-a,project-b,project-a "
             })

    assert {:ok, []} =
             Schema.configured_project_slugs(%Schema.Tracker{
               project_slug: nil,
               project_slugs: 123
             })
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    previous_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")
    previous_repo = System.get_env("SYMPHONY_REPO")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      restore_env("SYMPHONY_PROJECT_SLUG", previous_project_slug)
      restore_env("SYMPHONY_REPO", previous_repo)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
      System.put_env("SYMPHONY_PROJECT_SLUG", "remote-project")
      System.put_env("SYMPHONY_REPO", "symphony")

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE_INSPECT__"*)
          printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_INSPECT__' 'missing'
          ;;
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      issue = %Issue{
        id: "issue-ssh-ws",
        identifier: "MT-SSH-WS",
        title: "Remote workspace project env",
        state: "Todo",
        project: %{id: "remote-project-id", slug_id: "remote-project", name: "Remote 'Project"}
      }

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, issue, "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, issue, "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces(issue, "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "SYMPHONY_LINEAR_PROJECT_ID="
      assert trace =~ "remote-project-id"
      assert trace =~ "export SYMPHONY_LINEAR_PROJECT_ID"
      assert trace =~ "SYMPHONY_LINEAR_PROJECT_SLUG="
      assert trace =~ "remote-project"
      assert trace =~ "export SYMPHONY_LINEAR_PROJECT_SLUG"
      assert trace =~ "SYMPHONY_LINEAR_PROJECT_NAME="
      assert trace =~ "Remote "
      assert trace =~ "Project"
      assert trace =~ "export SYMPHONY_LINEAR_PROJECT_NAME"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace identity mismatch quarantines before after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-identity-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    with_project_env("remote-project", "symphony", fn ->
      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      end)

      try do
        trace_file = Path.join(test_root, "ssh.trace")
        fake_ssh = Path.join(test_root, "ssh")
        workspace_root = "~/.symphony-remote-workspaces"
        workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-IDENTITY"

        stale_marker =
          Jason.encode!(%{
            "version" => 1,
            "linear_project_id" => "old-project-id",
            "linear_project_slug_id" => "grotto",
            "linear_project_name" => "Grotto",
            "workflow_dir" => "/old/workflow",
            "workflow_file" => "/old/workflow/WORKFLOW.md",
            "symphony_project_slug" => "grotto",
            "symphony_repo" => "grotto"
          })

        File.mkdir_p!(test_root)
        System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
        printf 'ARGV:%s\\n' "$*" >> "$trace_file"

        case "$*" in
          *"__SYMPHONY_WORKSPACE_INSPECT__"*)
            printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_INSPECT__' 'dir'
            printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_MARKER__' '#{Base.encode64(stale_marker)}'
            ;;
          *"__SYMPHONY_WORKSPACE__"*)
            printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
            ;;
        esac

        exit 0
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          worker_ssh_hosts: ["worker-identity"],
          hook_after_create: "echo after-create"
        )

        issue = %Issue{
          id: "issue-ssh-identity",
          identifier: "MT-SSH-IDENTITY",
          title: "Remote identity",
          state: "Todo",
          project: %{id: "remote-project-id", slug_id: "remote-project", name: "Remote Project"}
        }

        assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-identity")

        trace = File.read!(trace_file)
        assert trace =~ "__SYMPHONY_WORKSPACE_INSPECT__"
        assert trace =~ ".symphony/workspace-identity.json"
        assert trace =~ "__SYMPHONY_WORKSPACE_MARKER_WRITE__"
        assert trace =~ ".quarantine."
        assert trace =~ "echo after-create"

        assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
        assert trace_index(trace, "echo after-create") < trace_index(trace, "__SYMPHONY_WORKSPACE_MARKER_WRITE__")
      after
        File.rm_rf(test_root)
      end
    end)
  end

  test "remote unsafe workspace identity marker quarantines before after_create hook" do
    trace = run_remote_marker_case!("MT-SSH-UNSAFE-MARKER", "unsafe_marker", nil)
    assert trace =~ "[ -L"
    assert trace =~ "wc -c"
    assert trace =~ "65536"
    assert trace =~ ~s([ ! -d "$marker_dir" ])
    assert trace =~ ~s([ ! -f "$marker" ])
    assert trace_index(trace, "[ -L") < trace_index(trace, ".symphony/workspace-identity.json")
    assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
  end

  test "remote final workspace symlink is quarantined" do
    trace = run_remote_marker_case!("MT-SSH-WORKSPACE-LINK", "link", nil)
    assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
  end

  test "remote malformed workspace identity marker is quarantined" do
    trace =
      run_remote_marker_case!(
        "MT-SSH-MALFORMED-MARKER",
        "dir",
        "{partial\n__SYMPHONY_WORKSPACE_INSPECT__\tmissing"
      )

    assert trace =~ "__SYMPHONY_WORKSPACE_MARKER__"
    assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
  end

  test "remote empty workspace identity marker is quarantined" do
    trace = run_remote_marker_case!("MT-SSH-EMPTY-MARKER", "dir", "")
    assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
  end

  test "remote legacy no-marker workspace with matching git remote backfills marker and reuses" do
    trace =
      run_remote_legacy_no_marker_case!(
        "MT-SSH-LEGACY-MATCH",
        "worker-legacy-match",
        "git@github.com:agavemindlab/symphony.git"
      )

    assert trace =~ "__SYMPHONY_WORKSPACE_INSPECT__"
    assert trace =~ "__SYMPHONY_WORKSPACE_REMOTE__"
    assert trace =~ "REMOTE_OUTPUT:git@github.com:agavemindlab/symphony.git"
    assert trace =~ "__SYMPHONY_WORKSPACE_MARKER_WRITE__"
    refute trace =~ ".quarantine."
    refute trace =~ "echo after-create"
    assert trace_index(trace, "__SYMPHONY_WORKSPACE_INSPECT__") < trace_index(trace, "__SYMPHONY_WORKSPACE_MARKER_WRITE__")
  end

  test "remote legacy no-marker workspace with mismatching git remote is quarantined" do
    trace =
      run_remote_legacy_no_marker_case!(
        "MT-SSH-LEGACY-MISMATCH",
        "worker-legacy-mismatch",
        "https://github.com/agavemindlab/grotto.git"
      )

    assert trace =~ "__SYMPHONY_WORKSPACE_INSPECT__"
    assert trace =~ "REMOTE_OUTPUT:https://github.com/agavemindlab/grotto.git"
    assert trace =~ ".quarantine."
    assert trace =~ "echo after-create"
    assert trace =~ "__SYMPHONY_WORKSPACE_MARKER_WRITE__"
    assert trace_index(trace, "__SYMPHONY_WORKSPACE_REMOTE__") < trace_index(trace, ".quarantine.")
    assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
    assert trace_index(trace, "echo after-create") < trace_index(trace, "__SYMPHONY_WORKSPACE_MARKER_WRITE__")
  end

  test "remote legacy no-marker workspace with unknown git remote is quarantined" do
    trace = run_remote_legacy_no_marker_case!("MT-SSH-LEGACY-UNKNOWN", "worker-legacy-unknown", nil)

    assert trace =~ "__SYMPHONY_WORKSPACE_INSPECT__"
    assert trace =~ "REMOTE_OUTPUT:<none>"
    assert trace =~ ".quarantine."
    assert trace =~ "echo after-create"
    assert trace =~ "__SYMPHONY_WORKSPACE_MARKER_WRITE__"
    assert trace_index(trace, "__SYMPHONY_WORKSPACE_INSPECT__") < trace_index(trace, ".quarantine.")
    assert trace_index(trace, ".quarantine.") < trace_index(trace, "echo after-create")
    assert trace_index(trace, "echo after-create") < trace_index(trace, "__SYMPHONY_WORKSPACE_MARKER_WRITE__")
  end

  test "remote workspace intermediate symlink escape fails closed before marker read or hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-symlink-escape-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    with_project_env("remote-project", "symphony", fn ->
      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      end)

      try do
        trace_file = Path.join(test_root, "ssh.trace")
        fake_ssh = Path.join(test_root, "ssh")
        workspace_root = "~/.symphony-remote-workspaces"
        workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-ESCAPE"

        File.mkdir_p!(test_root)
        System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
        printf 'ARGV:%s\\n' "$*" >> "$trace_file"

        case "$*" in
          *"__SYMPHONY_WORKSPACE_INSPECT__"*)
            printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_INSPECT__' 'escape'
            printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PATH__' '#{Base.encode64("/outside/old-repo")}'
            ;;
          *"__SYMPHONY_WORKSPACE__"*)
            printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
            ;;
        esac

        exit 0
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          worker_ssh_hosts: ["worker-escape"],
          hook_after_create: "echo after-create"
        )

        issue = %Issue{
          id: "issue-ssh-escape",
          identifier: "MT-SSH-ESCAPE",
          title: "Remote escape",
          state: "Todo",
          project: %{id: "remote-project-id", slug_id: "remote-project", name: "Remote Project"}
        }

        assert {:error, {:workspace_symlink_escape, :intermediate_symlink}} =
                 Workspace.create_for_issue(issue, "worker-escape")

        trace = File.read!(trace_file)
        assert trace =~ "__SYMPHONY_WORKSPACE_INSPECT__"
        assert trace =~ "pwd -P"
        refute trace =~ ".quarantine."
        refute trace =~ "echo after-create"
        assert trace_index(trace, "pwd -P") < trace_index(trace, ".symphony/workspace-identity.json")
      after
        File.rm_rf(test_root)
      end
    end)
  end

  defp configure_fake_gh_clone!(test_root) do
    source_repo = Path.join(test_root, "source-repo")
    fake_bin = Path.join(test_root, "bin")
    fake_gh = Path.join(fake_bin, "gh")

    File.mkdir_p!(source_repo)
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(source_repo, "README.md"), "source repo\n")
    System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
    System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", source_repo, "add", "README.md"])
    System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

    File.write!(fake_gh, """
    #!/usr/bin/env bash
    set -euo pipefail

    case "${1:-} ${2:-}" in
      "repo clone")
        destination="${4:-.}"
        git clone --depth 1 "$SYMPHONY_TEST_SOURCE_REPO" "$destination" >/dev/null 2>&1
        git -C "$destination" remote add upstream "$SYMPHONY_TEST_SOURCE_REPO" >/dev/null 2>&1 || true
        ;;
      "api user")
        printf 'test-owner\\n'
        ;;
      *)
        printf 'unexpected gh invocation: %s\\n' "$*" >&2
        exit 2
        ;;
    esac
    """)

    File.chmod!(fake_gh, 0o755)

    previous_path = System.get_env("PATH")
    previous_repo = System.get_env("SYMPHONY_REPO")
    previous_source_repo = System.get_env("SYMPHONY_TEST_SOURCE_REPO")
    previous_fork_owner = System.get_env("GITHUB_FORK_OWNER")
    previous_base_branch = System.get_env("SYMPHONY_BASE_BRANCH")

    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
    System.put_env("SYMPHONY_REPO", "source-repo")
    System.put_env("SYMPHONY_TEST_SOURCE_REPO", source_repo)
    System.put_env("GITHUB_FORK_OWNER", "test-owner")
    System.put_env("SYMPHONY_BASE_BRANCH", "main")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_REPO", previous_repo)
      restore_env("SYMPHONY_TEST_SOURCE_REPO", previous_source_repo)
      restore_env("GITHUB_FORK_OWNER", previous_fork_owner)
      restore_env("SYMPHONY_BASE_BRANCH", previous_base_branch)
    end)
  end

  defp read_skill_front_matter(path) do
    ["---" | lines] = File.read!(path) |> String.split(["\r\n", "\n", "\r"], trim: false)
    {front_matter_lines, _rest} = Enum.split_while(lines, &(&1 != "---"))
    YamlElixir.read_from_string(Enum.join(front_matter_lines, "\n"))
  end

  defp first_existing_ca_bundle! do
    [
      "/etc/ssl/cert.pem",
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      "/etc/ssl/ca-bundle.pem",
      "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
    ]
    |> Enum.find(&File.regular?/1) ||
      flunk("test host has no known system CA bundle path")
  end

  defp create_clone_source_repo!(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), "clone source\n")

    assert {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: path)
    assert {_output, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: path)
    assert {_output, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    assert {_output, 0} = System.cmd("git", ["add", "README.md"], cd: path)
    assert {_output, 0} = System.cmd("git", ["commit", "-m", "initial"], cd: path)
  end

  defp install_fake_gh!(fake_bin_dir) do
    File.mkdir_p!(fake_bin_dir)

    fake_gh = Path.join(fake_bin_dir, "gh")

    File.write!(fake_gh, """
    #!/usr/bin/env bash
    set -euo pipefail

    if [ "$#" -ge 4 ] && [ "$1" = "repo" ] && [ "$2" = "clone" ]; then
      destination="$4"
      git clone "$SYMPHONY_TEST_CLONE_SOURCE" "$destination" >/dev/null 2>&1
      git -C "$destination" remote add upstream "$SYMPHONY_TEST_CLONE_SOURCE"
      exit 0
    fi

    if [ "$#" -ge 2 ] && [ "$1" = "api" ] && [ "$2" = "user" ]; then
      printf 'test-owner\\n'
      exit 0
    fi

    printf 'unexpected fake gh invocation: %s\\n' "$*" >&2
    exit 1
    """)

    File.chmod!(fake_gh, 0o755)
  end

  defp with_project_env(project_slug, repo, fun) when is_function(fun, 0) do
    previous_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")
    previous_repo = System.get_env("SYMPHONY_REPO")

    try do
      System.put_env("SYMPHONY_PROJECT_SLUG", project_slug)
      System.put_env("SYMPHONY_REPO", repo)
      fun.()
    after
      restore_env("SYMPHONY_PROJECT_SLUG", previous_project_slug)
      restore_env("SYMPHONY_REPO", previous_repo)
    end
  end

  defp workspace_identity_marker(workspace) do
    workspace
    |> Path.join(".symphony/workspace-identity.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_workspace_identity_marker!(workspace, marker) when is_map(marker) do
    marker_path = Path.join(workspace, ".symphony/workspace-identity.json")
    File.mkdir_p!(Path.dirname(marker_path))
    File.write!(marker_path, Jason.encode!(marker))
  end

  defp run_remote_legacy_no_marker_case!(identifier, worker_host, remote_url) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-legacy-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    with_project_env("remote-project", "symphony", fn ->
      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      end)

      try do
        trace_file = Path.join(test_root, "ssh.trace")
        fake_ssh = Path.join(test_root, "ssh")
        workspace_root = "~/.symphony-remote-workspaces"
        workspace_path = "/remote/home/.symphony-remote-workspaces/#{identifier}"

        File.mkdir_p!(test_root)
        System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, remote_legacy_no_marker_ssh_script(workspace_path, remote_url))
        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          worker_ssh_hosts: [worker_host],
          hook_after_create: "echo after-create"
        )

        issue = %Issue{
          id: "issue-#{String.downcase(identifier)}",
          identifier: identifier,
          title: "Remote legacy no-marker",
          state: "Todo",
          project: %{id: "remote-project-id", slug_id: "remote-project", name: "Remote Project"}
        }

        assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, worker_host)
        File.read!(trace_file)
      after
        File.rm_rf(test_root)
      end
    end)
  end

  defp remote_legacy_no_marker_ssh_script(workspace_path, nil) do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    case "$*" in
      *"__SYMPHONY_WORKSPACE_INSPECT__"*)
        printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_INSPECT__' 'dir'
        printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PATH__' '#{Base.encode64(workspace_path)}'
        printf 'REMOTE_OUTPUT:<none>\\n' >> "$trace_file"
        ;;
      *"__SYMPHONY_WORKSPACE__"*)
        printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
        ;;
    esac

    exit 0
    """
  end

  defp remote_legacy_no_marker_ssh_script(workspace_path, remote_url) when is_binary(remote_url) do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    case "$*" in
      *"__SYMPHONY_WORKSPACE_INSPECT__"*)
        printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_INSPECT__' 'dir'
        printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PATH__' '#{Base.encode64(workspace_path)}'
        printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_REMOTE__' '#{Base.encode64(remote_url)}'
        printf 'REMOTE_OUTPUT:%s\\n' '#{remote_url}' >> "$trace_file"
        ;;
      *"__SYMPHONY_WORKSPACE__"*)
        printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
        ;;
    esac

    exit 0
    """
  end

  defp run_remote_marker_case!(identifier, inspection_kind, marker) do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-remote-marker-#{System.unique_integer([:positive])}")

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    with_project_env("remote-project", "symphony", fn ->
      try do
        trace_file = Path.join(test_root, "ssh.trace")
        fake_ssh = Path.join(test_root, "ssh")
        workspace_path = "/remote/home/.symphony-remote-workspaces/#{identifier}"
        marker_output = if marker, do: "printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_MARKER__' '#{Base.encode64(marker)}'", else: ""

        File.mkdir_p!(test_root)
        System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "$SYMP_TEST_SSH_TRACE"
        case "$*" in
          *"__SYMPHONY_WORKSPACE_INSPECT__"*)
            printf '%s\\t%s\\n' '__SYMPHONY_WORKSPACE_INSPECT__' '#{inspection_kind}'
            #{marker_output}
            ;;
          *"__SYMPHONY_WORKSPACE__"*)
            printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
            ;;
        esac
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: "~/.symphony-remote-workspaces",
          worker_ssh_hosts: ["worker-marker"],
          hook_after_create: "echo after-create"
        )

        issue = %Issue{
          id: "issue-#{String.downcase(identifier)}",
          identifier: identifier,
          title: "Remote marker",
          state: "Todo",
          project: %{id: "remote-project-id", slug_id: "remote-project", name: "Remote Project"}
        }

        assert {:ok, ^workspace_path} = Workspace.create_for_issue(issue, "worker-marker")
        trace = File.read!(trace_file)
        assert trace =~ ".quarantine."
        trace
      after
        restore_env("PATH", previous_path)
        restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
        File.rm_rf(test_root)
      end
    end)
  end

  defp trace_index(trace, needle) do
    case :binary.match(trace, needle) do
      {index, _length} -> index
      :nomatch -> flunk("expected trace to contain #{inspect(needle)}")
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
