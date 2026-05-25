defmodule SymphonyElixir.SymphonyRunTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @launcher Path.join(@repo_root, "bin/symphony-run")

  test "loads the Agavemindlab automated reviewer default" do
    capture = run_launcher!("gl-infra")

    assert capture["AUTOMATED_REVIEWER"] == "gl-swe"
  end

  test "lets the project env override the profile env" do
    capture =
      run_launcher!("symphony",
        project_env_extra: """
        AUTOMATED_REVIEWER="project-reviewer"
        """,
        profile_env: """
        LINEAR_API_KEY="test-token"
        AUTOMATED_REVIEWER="profile-reviewer"
        """
      )

    assert capture["AUTOMATED_REVIEWER"] == "project-reviewer"
  end

  defp run_launcher!(project, opts \\ []) do
    run_id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "symphony-run-test-#{run_id}")
    home = Path.join(tmp_root, "home")
    fake_bin = Path.join(tmp_root, "bin")
    fake_repo_root = Path.join(tmp_root, "repo")
    capture_path = Path.join(tmp_root, "capture.env")

    File.mkdir_p!(Path.join(home, ".config/symphony"))
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.join(fake_repo_root, "elixir"))
    File.mkdir_p!(Path.join(fake_repo_root, "workflows/agavemindlab"))
    File.mkdir_p!(Path.join(fake_repo_root, "workflows/#{project}"))

    File.write!(
      Path.join(fake_repo_root, "workflows/agavemindlab/project.env.defaults"),
      File.read!(Path.join(@repo_root, "workflows/agavemindlab/project.env.defaults"))
    )

    project_env =
      Path.join(@repo_root, "workflows/#{project}/project.env")
      |> File.read!()
      |> Kernel.<>(Keyword.get(opts, :project_env_extra, ""))

    File.write!(Path.join(fake_repo_root, "workflows/#{project}/project.env"), project_env)
    File.write!(Path.join(fake_repo_root, "workflows/#{project}/WORKFLOW.md"), "# Test workflow\n")

    File.write!(
      Path.join(home, ".config/symphony/grandline.env"),
      Keyword.get(opts, :profile_env, "LINEAR_API_KEY=\"test-token\"\n")
    )

    File.write!(Path.join(fake_bin, "mise"), fake_mise_script())
    File.chmod!(Path.join(fake_bin, "mise"), 0o755)

    env = [
      {"HOME", home},
      {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")},
      {"SYMPHONY_REPO_ROOT", fake_repo_root},
      {"SYMPHONY_RUN_CAPTURE", capture_path},
      {"SYMPHONY_PROFILE", nil},
      {"AUTOMATED_REVIEWER", nil}
    ]

    try do
      assert {output, 0} = System.cmd(@launcher, [project], env: env, stderr_to_stdout: true)
      assert output == ""

      capture_path
      |> File.read!()
      |> parse_capture()
    after
      File.rm_rf(tmp_root)
    end
  end

  defp fake_mise_script do
    """
    #!/bin/sh
    {
      printf 'AUTOMATED_REVIEWER=%s\\n' "${AUTOMATED_REVIEWER-}"
      printf 'SYMPHONY_PROFILE=%s\\n' "${SYMPHONY_PROFILE-}"
      printf 'PWD=%s\\n' "$PWD"
      printf 'ARGS=%s\\n' "$*"
    } > "$SYMPHONY_RUN_CAPTURE"
    """
  end

  defp parse_capture(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, value}
    end)
  end
end
