defmodule SymphonyElixir.SharedSkillsSnapshotTest do
  use ExUnit.Case

  @script Path.expand("../../../workflows/agavemindlab/snapshot-shared-skills.sh", __DIR__)

  test "committed snapshots isolate turns, migrate links, preserve tracked skills, and stay excluded" do
    root = tmp_dir("shared-skills")
    canonical = Path.join(root, "canonical repo")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha-a\n")
      write_skill!(canonical, "tracked", "shared-tracked\n")
      write_skill!(canonical, "alpha", "other-alpha\n", "other-skills")
      shared_source = Path.join(canonical, "shared-skills")
      File.ln_s!("skills", shared_source)
      commit_all!(canonical, "initial skills")

      init_repo!(workspace)
      write_skill!(Path.join(workspace, ".agents"), "tracked", "repo-tracked\n")
      commit_all!(workspace, "tracked workspace skill")

      legacy = Path.join(workspace, ".agents/skills/alpha")
      File.mkdir_p!(Path.dirname(legacy))
      File.ln_s!(realpath!(Path.join(canonical, "skills/alpha")), legacy)

      run_snapshot!(workspace, [shared_source])
      first_generation = File.read_link!(Path.join(workspace, ".symphony/shared-skills/current"))

      alpha = Path.join(workspace, ".agents/skills/alpha/SKILL.md")
      assert File.read!(alpha) == "alpha-a\n"
      assert File.read!(Path.join(workspace, ".agents/skills/tracked/SKILL.md")) == "repo-tracked\n"
      assert inside?(realpath!(alpha), workspace)

      File.rm!(shared_source)
      File.ln_s!("other-skills", shared_source)
      File.write!(alpha, "workspace edit\n")
      stale_tmp = Path.join(workspace, ".symphony/shared-skills/generations/.tmp-stale")
      File.mkdir_p!(stale_tmp)
      assert File.read!(Path.join(canonical, "skills/alpha/SKILL.md")) == "alpha-a\n"
      run_snapshot!(workspace, [shared_source])
      assert File.read!(alpha) == "alpha-a\n"
      refute File.exists?(stale_tmp)

      refute File.read_link!(Path.join(workspace, ".symphony/shared-skills/current")) ==
               first_generation

      File.write!(Path.join(canonical, "skills/alpha/SKILL.md"), "dirty canonical\n")
      run_snapshot!(workspace, [shared_source])
      assert File.read!(alpha) == "alpha-a\n"

      File.rm!(shared_source)
      File.ln_s!("skills", shared_source)
      File.write!(Path.join(canonical, "skills/alpha/SKILL.md"), "alpha-b\n")
      write_skill!(canonical, "added", "added\n")
      commit_all!(canonical, "update skills")
      assert File.read!(alpha) == "alpha-a\n"
      run_snapshot!(workspace, [shared_source])
      assert File.read!(alpha) == "alpha-b\n"
      assert File.read!(Path.join(workspace, ".agents/skills/added/SKILL.md")) == "added\n"

      git!(workspace, ["add", "-A"])
      assert git!(workspace, ["diff", "--cached", "--name-only"]) == ""

      File.rm_rf!(Path.join(canonical, "skills/alpha"))
      commit_all!(canonical, "remove alpha")
      run_snapshot!(workspace, [shared_source])
      refute File.exists?(Path.join(workspace, ".agents/skills/alpha"))
      assert {:error, :enoent} = File.read_link(Path.join(workspace, ".agents/skills/alpha"))
      assert File.read!(Path.join(workspace, ".agents/skills/tracked/SKILL.md")) == "repo-tracked\n"
    after
      File.rm_rf(root)
    end
  end

  test "snapshot build failure preserves the active generation and managed links" do
    root = tmp_dir("shared-skills-failure")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      write_skill!(canonical, "gamma", "gamma\n")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")

      run_snapshot!(workspace, [Path.join(canonical, "skills")])
      current = Path.join(workspace, ".symphony/shared-skills/current")
      before_target = File.read_link!(current)
      before_content = File.read!(Path.join(workspace, ".agents/skills/alpha/SKILL.md"))
      stale_tmp = Path.join(workspace, ".symphony/shared-skills/generations/.tmp-stale")
      File.mkdir_p!(stale_tmp)

      duplicate_source = Path.join(canonical, "duplicate")
      write_skill!(canonical, "alpha", "duplicate\n", "duplicate")
      commit_all!(canonical, "add duplicate source")

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills"), duplicate_source],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "duplicate shared skill name"
      assert File.read_link!(current) == before_target
      assert File.read!(Path.join(workspace, ".agents/skills/alpha/SKILL.md")) == before_content
      refute File.exists?(stale_tmp)

      File.rm_rf!(duplicate_source)
      write_skill!(canonical, "added", "added\n")
      write_skill!(canonical, "beta", "beta\n")
      commit_all!(canonical, "replace duplicate with new skill")
      agents = Path.join(workspace, ".agents/skills")
      alpha_link = Path.join(agents, "alpha")
      File.rm!(alpha_link)
      File.ln_s!("-outside", alpha_link)
      gamma_link = Path.join(agents, "gamma")
      File.rm!(gamma_link)
      File.ln_s!("MISSING", gamma_link)
      source = Path.join(canonical, "skills")

      try do
        assert {output, status} =
                 System.cmd(
                   "sh",
                   [
                     "-c",
                     ": > .agents/skills/.snapshot-beta-$$; exec \"#{@script}\" \"#{source}\""
                   ],
                   cd: workspace,
                   stderr_to_stdout: true
                 )

        assert status != 0
        assert output =~ "File exists"
      after
        File.rm_rf(Path.join(agents, ".snapshot-beta-#{System.pid()}"))
      end

      assert File.read_link!(current) == before_target
      assert File.read_link!(alpha_link) == "./-outside"
      assert File.read_link!(gamma_link) == "MISSING"
      refute File.exists?(Path.join(workspace, ".agents/skills/added"))
      refute File.exists?(Path.join(workspace, ".agents/skills/beta"))
    after
      File.rm_rf(root)
    end
  end

  test "publication interruption rolls back current and every managed link" do
    root = tmp_dir("shared-skills-interruption")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")
    fake_bin = Path.join(root, "bin")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha-a\n")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      source = Path.join(canonical, "skills")
      run_snapshot!(workspace, [source])
      current = Path.join(workspace, ".symphony/shared-skills/current")
      before_target = File.read_link!(current)
      outside_link = Path.join(workspace, "outside-link")
      File.ln_s!("safe", outside_link)

      write_skill!(canonical, "alpha", "alpha-b\n")
      write_skill!(canonical, "added", "added\n")
      commit_all!(canonical, "update")
      File.mkdir_p!(fake_bin)
      sent = Path.join(root, "sent")
      fake_mv = Path.join(fake_bin, "mv")

      File.write!(fake_mv, """
      #!/bin/sh
      last=
      for arg in "$@"; do last=$arg; done
      /bin/mv "$@"
      status=$?
      case "$last" in
        */.symphony/shared-skills/current)
          if [ "$status" -eq 0 ] && [ ! -e "#{sent}" ]; then
            : > "#{sent}"
            printf '%s\t%s\n' '../../outside-link' missing > \
              "#{workspace}/.symphony/shared-skills/$(/usr/bin/readlink "$last")/links"
            kill -TERM "$PPID"
          fi
          ;;
      esac
      exit "$status"
      """)

      File.chmod!(fake_mv, 0o755)

      assert {_output, status} =
               System.cmd(@script, [source],
                 cd: workspace,
                 env: [{"PATH", fake_bin <> ":" <> System.fetch_env!("PATH")}],
                 stderr_to_stdout: true
               )

      assert status != 0
      assert File.read_link!(current) == before_target
      assert File.read_link!(outside_link) == "safe"
      assert File.read!(Path.join(workspace, ".agents/skills/alpha/SKILL.md")) == "alpha-a\n"
      refute File.exists?(Path.join(workspace, ".agents/skills/added"))

      assert File.ls!(Path.join(workspace, ".symphony/shared-skills/generations")) == [
               Path.basename(before_target)
             ]
    after
      File.rm_rf(root)
    end
  end

  test "snapshot rejects escaping workspace state and committed symlinks" do
    root = tmp_dir("shared-skills-containment")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(workspace, ".symphony"))

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "workspace state directory is a symlink"
      assert File.ls!(outside) == []

      File.rm!(Path.join(workspace, ".symphony"))
      exclude = Path.join(workspace, ".git/info/exclude")
      exclude_content = File.read!(exclude)
      outside_exclude = Path.join(outside, "exclude")
      File.write!(outside_exclude, "sentinel\n")
      File.rm!(exclude)
      File.ln_s!(outside_exclude, exclude)

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "workspace Git exclude file is a symlink"
      assert File.read!(outside_exclude) == "sentinel\n"
      File.rm!(exclude)
      File.write!(exclude, exclude_content)

      git_dir = Path.join(outside, "workspace-git")
      File.rename!(Path.join(workspace, ".git"), git_dir)
      File.ln_s!(git_dir, Path.join(workspace, ".git"))

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "workspace Git metadata is a symlink"
      File.rm!(Path.join(workspace, ".git"))
      File.rename!(git_dir, Path.join(workspace, ".git"))

      run_snapshot!(workspace, [Path.join(canonical, "skills")])
      current = Path.join(workspace, ".symphony/shared-skills/current")
      before_target = File.read_link!(current)
      before_content = File.read!(Path.join(workspace, ".agents/skills/alpha/SKILL.md"))
      manifest = Path.join([workspace, ".symphony/shared-skills", before_target, "manifest"])
      manifest_content = File.read!(manifest)
      File.write!(manifest, manifest_content <> "managed=../escape\n")

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "invalid managed skill name in prior snapshot"
      File.write!(manifest, manifest_content)

      File.ln_s!("/tmp", Path.join(canonical, "skills/alpha/escape"))
      commit_all!(canonical, "add escaping symlink")

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "absolute symlink is not supported"
      assert File.read_link!(current) == before_target
      assert File.read!(Path.join(workspace, ".agents/skills/alpha/SKILL.md")) == before_content

      File.rm!(Path.join(canonical, "skills/alpha/escape"))
      File.ln_s!("../../../outside", Path.join(canonical, "skills/alpha/escape"))
      commit_all!(canonical, "replace absolute symlink with relative escape")

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ ~r/(dangling symlink is not supported|symlink escapes the snapshot)/
      assert File.read_link!(current) == before_target
    after
      File.rm_rf(root)
    end
  end

  test "snapshot accepts a single-skill source and rejects unsafe rollback targets" do
    root = tmp_dir("shared-skills-single-source")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      write_skill!(canonical, "0alpha", "zero alpha\n")
      write_skill!(canonical, "-alpha", "dash alpha\n")
      write_skill!(canonical, "maestro", "maestro\n", ".codex/skills")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      maestro = Path.join(workspace, ".agents/skills/maestro")
      File.mkdir_p!(Path.dirname(maestro))
      File.ln_s!(realpath!(Path.join(canonical, ".codex/skills/maestro")), maestro)

      run_snapshot!(workspace, [
        Path.join(canonical, "skills"),
        Path.join(canonical, ".codex/skills/maestro")
      ])

      assert File.read!(Path.join(workspace, ".agents/skills/maestro/SKILL.md")) == "maestro\n"
      assert File.read_link!(maestro) == "../../.symphony/shared-skills/current/skills/maestro"
      assert File.read!(Path.join(workspace, ".agents/skills/0alpha/SKILL.md")) == "zero alpha\n"
      assert File.read!(Path.join(workspace, ".agents/skills/-alpha/SKILL.md")) == "dash alpha\n"
      current = Path.join(workspace, ".symphony/shared-skills/current")
      before_target = File.read_link!(current)
      alpha = Path.join(workspace, ".agents/skills/alpha")
      File.rm!(alpha)
      File.ln_s!("../../bad\ntarget", alpha)

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "managed skill link target contains a newline"
      assert File.read_link!(current) == before_target
      assert File.read_link!(alpha) == "../../bad\ntarget"
    after
      File.rm_rf(root)
    end
  end

  test "snapshot resolves committed collection symlinks from the same repository" do
    root = tmp_dir("shared-skills-collection-links")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "phase", "phase\n", "collection")
      write_skill!(canonical, "shared", "shared\n", "base-skills")
      File.ln_s!("../base-skills/shared", Path.join(canonical, "collection/shared"))
      commit_all!(canonical, "linked skill collection")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      legacy = Path.join(workspace, ".agents/skills/shared")
      File.mkdir_p!(Path.dirname(legacy))
      File.ln_s!(realpath!(Path.join(canonical, "base-skills/shared")), legacy)

      run_snapshot!(workspace, [Path.join(canonical, "collection")])

      assert File.read!(Path.join(workspace, ".agents/skills/phase/SKILL.md")) == "phase\n"
      assert File.read!(Path.join(workspace, ".agents/skills/shared/SKILL.md")) == "shared\n"
      assert inside?(realpath!(Path.join(workspace, ".agents/skills/shared")), workspace)
      assert File.read_link!(legacy) == "../../.symphony/shared-skills/current/skills/shared"
    after
      File.rm_rf(root)
    end
  end

  test "snapshot installs the repository's lite workflow collection" do
    root = tmp_dir("shared-skills-lite-workflow")
    workspace = Path.join(root, "workspace")
    source = Path.expand("../../../workflows/agavemindlab-lite/skills", __DIR__)

    try do
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")

      run_snapshot!(workspace, [source])

      assert File.exists?(Path.join(workspace, ".agents/skills/phase-implementation/SKILL.md"))
      assert File.exists?(Path.join(workspace, ".agents/skills/symphony-linear/SKILL.md"))
      assert inside?(realpath!(Path.join(workspace, ".agents/skills/symphony-linear")), workspace)
    after
      File.rm_rf(root)
    end
  end

  test "fresh snapshot accepts an emptied committed symlink collection" do
    root = tmp_dir("shared-skills-fresh-empty")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      source = Path.join(canonical, "shared-skills")
      File.ln_s!("skills", source)
      commit_all!(canonical, "initial")
      File.rm_rf!(Path.join(canonical, "skills"))
      commit_all!(canonical, "empty collection")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")

      run_snapshot!(workspace, [source])

      manifest = File.read!(Path.join(workspace, ".symphony/shared-skills/current/manifest"))
      assert manifest =~ "source=skills\n"
      refute manifest =~ "managed="
      assert File.ls!(Path.join(workspace, ".agents/skills")) == []
    after
      File.rm_rf(root)
    end
  end

  test "snapshot rejects repository-tracked shared skill state without changing it" do
    root = tmp_dir("shared-skills-tracked-state")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      owned = Path.join(workspace, ".symphony/shared-skills/generations/owned/file")
      File.mkdir_p!(Path.dirname(owned))
      File.write!(owned, "owned\n")
      commit_all!(workspace, "tracked state collision")

      assert {output, status} =
               System.cmd(@script, [Path.join(canonical, "skills")],
                 cd: workspace,
                 stderr_to_stdout: true
               )

      assert status != 0
      assert output =~ "repository tracks Symphony shared skill state"
      assert File.read!(owned) == "owned\n"
      assert git!(workspace, ["status", "--porcelain"]) == ""
    after
      File.rm_rf(root)
    end
  end

  test "source repoint does not guess legacy provenance" do
    root = tmp_dir("shared-skills-repoint")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "old\n")
      write_skill!(canonical, "alpha", "new\n", "other-skills")
      source = Path.join(canonical, "shared-skills")
      File.ln_s!("skills", source)
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      legacy = Path.join(workspace, ".agents/skills/alpha")
      File.mkdir_p!(Path.dirname(legacy))
      File.ln_s!(Path.join(canonical, "skills/alpha"), legacy)

      File.rm!(source)
      File.ln_s!("other-skills", source)
      commit_all!(canonical, "repoint source")
      run_snapshot!(workspace, [source])

      assert File.read_link!(legacy) == Path.join(canonical, "skills/alpha")

      assert File.read!(Path.join(workspace, ".symphony/shared-skills/current/manifest")) =~
               "source=other-skills\n"

      assert File.read!(Path.join(legacy, "SKILL.md")) == "old\n"
    after
      File.rm_rf(root)
    end
  end

  test "snapshot preserves an unrelated same-name symlink in the canonical repository" do
    root = tmp_dir("shared-skills-unmanaged")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "shared\n")
      write_skill!(canonical, "alpha", "unrelated\n", "unrelated")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      link = Path.join(workspace, ".agents/skills/alpha")
      File.mkdir_p!(Path.dirname(link))
      unrelated = Path.join(canonical, "unrelated/alpha")
      File.ln_s!(unrelated, link)

      run_snapshot!(workspace, [Path.join(canonical, "skills")])

      assert File.read_link!(link) == unrelated
      assert File.read!(Path.join(link, "SKILL.md")) == "unrelated\n"

      refute File.read!(Path.join(workspace, ".symphony/shared-skills/current/manifest")) =~
               "managed=alpha\n"
    after
      File.rm_rf(root)
    end
  end

  test "option-like committed source prefixes cannot write to the canonical checkout" do
    root = tmp_dir("shared-skills-option-prefix")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n", "--output=pwn")
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")

      run_snapshot!(workspace, [Path.join(canonical, "--output=pwn")])

      assert File.read!(Path.join(workspace, ".agents/skills/alpha/SKILL.md")) == "alpha\n"
      refute File.exists?(Path.join(canonical, "pwn"))
      assert git!(canonical, ["status", "--porcelain"]) == ""
    after
      File.rm_rf(root)
    end
  end

  test "snapshot excludes managed state from a linked worktree" do
    root = tmp_dir("shared-skills-linked-worktree")
    canonical = Path.join(root, "canonical")
    repository = Path.join(root, "repository")
    workspace = Path.join(root, "linked-workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      commit_all!(canonical, "initial")
      init_repo!(repository)
      File.write!(Path.join(repository, "README.md"), "workspace\n")
      commit_all!(repository, "initial")
      git!(repository, ["worktree", "add", "-b", "linked", workspace])

      run_snapshot!(workspace, [Path.join(canonical, "skills")])

      skill = Path.join(workspace, ".agents/skills/alpha/SKILL.md")
      assert File.read!(skill) == "alpha\n"
      assert inside?(realpath!(skill), workspace)
      git!(workspace, ["add", "-A"])
      assert git!(workspace, ["diff", "--cached", "--name-only"]) == ""
    after
      File.rm_rf(root)
    end
  end

  test "snapshot removes the last managed skill from a committed collection" do
    root = tmp_dir("shared-skills-empty")
    canonical = Path.join(root, "canonical")
    workspace = Path.join(root, "workspace")

    try do
      init_repo!(canonical)
      write_skill!(canonical, "alpha", "alpha\n")
      source = Path.join(canonical, "shared-skills")
      File.ln_s!("skills", source)
      commit_all!(canonical, "initial")
      init_repo!(workspace)
      File.write!(Path.join(workspace, "README.md"), "workspace\n")
      commit_all!(workspace, "initial")
      run_snapshot!(workspace, [source])
      manifest = Path.join(workspace, ".symphony/shared-skills/current/manifest")
      File.write!(manifest, String.replace(File.read!(manifest), "managed=alpha\n", ""))

      skills = Path.join(canonical, "skills")
      File.rm_rf!(skills)
      commit_all!(canonical, "remove final skill")
      run_snapshot!(workspace, [source])

      refute File.exists?(Path.join(workspace, ".agents/skills/alpha"))
      refute File.read!(manifest) =~ "managed="

      write_skill!(canonical, ".hidden", "hidden\n")
      commit_all!(canonical, "add hidden skill")
      before_target = File.read_link!(Path.join(workspace, ".symphony/shared-skills/current"))

      assert {output, status} =
               System.cmd(@script, [source], cd: workspace, stderr_to_stdout: true)

      assert status != 0
      assert output =~ "invalid shared skill name: .hidden"
      assert File.read_link!(Path.join(workspace, ".symphony/shared-skills/current")) == before_target

      File.rm_rf!(skills)
      File.mkdir_p!(skills)
      File.ln_s!("missing", Path.join(skills, "dangling"))
      commit_all!(canonical, "add dangling skill")

      assert {output, status} =
               System.cmd(@script, [source], cd: workspace, stderr_to_stdout: true)

      assert status != 0
      assert output =~ "committed skill symlink does not target a directory: dangling"
      assert File.read_link!(Path.join(workspace, ".symphony/shared-skills/current")) == before_target

      File.rm_rf!(skills)
      write_skill!(canonical, "alpha", "wrong\n", "tmp")
      File.rm!(source)
      File.ln_s!("/tmp", source)
      commit_all!(canonical, "make source absolute")

      assert {output, status} =
               System.cmd(@script, [source], cd: workspace, stderr_to_stdout: true)

      assert status != 0
      assert output =~ "absolute committed skill source symlink is not supported"
      assert File.read_link!(Path.join(workspace, ".symphony/shared-skills/current")) == before_target
    after
      File.rm_rf(root)
    end
  end

  defp write_skill!(repo, name, content, parent \\ "skills") do
    path = Path.join([repo, parent, name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), content)
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.name", "Test User"])
    git!(path, ["config", "user.email", "test@example.com"])
  end

  defp commit_all!(repo, message) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", message])
  end

  defp run_snapshot!(workspace, sources) do
    assert {output, 0} = System.cmd(@script, sources, cd: workspace, stderr_to_stdout: true)
    assert output == ""
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp realpath!(path) do
    {output, 0} = System.cmd("realpath", [path], stderr_to_stdout: true)
    String.trim(output)
  end

  defp inside?(path, root), do: String.starts_with?(path <> "/", realpath!(root) <> "/")

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
  end
end
