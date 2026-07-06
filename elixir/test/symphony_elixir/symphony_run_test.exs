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

  test "allows aggregate projects to use project slugs without a singular repo" do
    capture =
      run_launcher!("grandline",
        project_env: """
        SYMPHONY_PROJECT_SLUGS="project-a,project-b"
        SYMPHONY_PROFILE="grandline"
        """
      )

    assert capture["SYMPHONY_PROJECT_SLUGS"] == "project-a,project-b"
    assert capture["SYMPHONY_REPO"] == ""
    assert capture["SYMPHONY_BASE_BRANCH"] == ""
  end

  test "allows aggregate projects to use project names without a singular repo" do
    capture = run_launcher!("grandline")

    assert capture["SYMPHONY_PROJECT_NAMES"] == "grotto,gl-infra,gl-skills,symphony,voxvault"
    assert capture["SYMPHONY_REPO"] == ""
    assert capture["SYMPHONY_BASE_BRANCH"] == ""
  end

  test "rebuilds the escript before launching" do
    capture = run_launcher!("grandline", project_env: "SYMPHONY_PROJECT_SLUGS=\"project-a\"\n")

    assert capture["CALLS"] == "exec -- mix escript.build|exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails #{capture["WORKFLOW"]}"
  end

  test "passes configured port to the Symphony CLI" do
    capture =
      run_launcher!("grandline",
        project_env: """
        SYMPHONY_PROJECT_SLUGS="project-a"
        SYMPHONY_PORT="4321"
        """
      )

    assert capture["ARGS"] =~ " --port 4321 "
  end

  test "Agavemindlab Linear project slugs use Linear slugId values" do
    expected_slugs = %{
      "gl-infra" => "02773795419d",
      "gl-skills" => "1ecc8649e9da",
      "grotto" => "bb8f9b7a6364",
      "symphony" => "977d7a7b6c0e",
      "voxvault" => "25c113bb4717"
    }

    actual_slugs =
      Map.new(expected_slugs, fn {project, _expected_slug} ->
        project_env = File.read!(Path.join(@repo_root, "workflows/#{project}/project.env"))
        [slug] = Regex.run(~r/^SYMPHONY_PROJECT_SLUG="([^"]+)"/m, project_env, capture: :all_but_first)
        {project, slug}
      end)

    assert actual_slugs == expected_slugs
  end

  defp run_launcher!(project, opts \\ []) do
    run_id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "symphony-run-test-#{run_id}")
    home = Path.join(tmp_root, "home")
    fake_bin = Path.join(tmp_root, "bin")
    fake_repo_root = Path.join(tmp_root, "repo")
    capture_path = Path.join(tmp_root, "capture.env")
    calls_path = Path.join(tmp_root, "calls.log")

    File.mkdir_p!(Path.join(home, ".config/symphony"))
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.join(fake_repo_root, "elixir"))
    File.mkdir_p!(Path.join(fake_repo_root, "workflows/#{project}"))
    File.mkdir_p!(Path.join(fake_repo_root, "workflows/agavemindlab"))
    File.write!(Path.join(fake_repo_root, "workflows/agavemindlab/WORKFLOW.md"), "# Test workflow\n")

    real_workflow_file = Path.join(@repo_root, "workflows/#{project}/WORKFLOW.md")
    fake_workflow_file = Path.join(fake_repo_root, "workflows/#{project}/WORKFLOW.md")

    namespace =
      case File.read_link(real_workflow_file) do
        {:ok, target} ->
          File.ln_s!(target, fake_workflow_file)
          resolved_target = Path.expand(target, Path.dirname(fake_workflow_file))
          File.mkdir_p!(Path.dirname(resolved_target))
          File.write!(resolved_target, "# Test workflow\n")
          target |> Path.dirname() |> Path.basename()

        {:error, _} ->
          File.write!(fake_workflow_file, "# Test workflow\n")
          project
      end

    real_defaults = Path.join(@repo_root, "workflows/#{namespace}/project.env.defaults")

    if File.exists?(real_defaults) do
      File.mkdir_p!(Path.join(fake_repo_root, "workflows/#{namespace}"))

      File.write!(
        Path.join(fake_repo_root, "workflows/#{namespace}/project.env.defaults"),
        File.read!(real_defaults)
      )
    end

    File.write!(Path.join(fake_repo_root, "workflows/agavemindlab/WORKFLOW.md"), "# Test workflow\n")

    project_env =
      case Keyword.fetch(opts, :project_env) do
        {:ok, contents} ->
          contents

        :error ->
          Path.join(@repo_root, "workflows/#{project}/project.env")
          |> File.read!()
          |> Kernel.<>(Keyword.get(opts, :project_env_extra, ""))
      end

    File.write!(Path.join(fake_repo_root, "workflows/#{project}/project.env"), project_env)

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
      {"SYMPHONY_RUN_CALLS", calls_path},
      {"SYMPHONY_PROFILE", nil},
      {"SYMPHONY_PROJECT_SLUG", nil},
      {"SYMPHONY_PROJECT_SLUGS", nil},
      {"SYMPHONY_PROJECT_NAME", nil},
      {"SYMPHONY_PROJECT_NAMES", nil},
      {"SYMPHONY_REPO", nil},
      {"SYMPHONY_BASE_BRANCH", nil},
      {"SYMPHONY_PROJECT_DIR", nil},
      {"SYMPHONY_PORT", nil},
      {"AUTOMATED_REVIEWER", nil}
    ]

    try do
      assert {output, 0} = System.cmd(@launcher, [project], env: env, stderr_to_stdout: true)
      assert output =~ "symphony-run: starting project=#{project} profile=grandline"

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
    printf '%s\\n' "$*" >> "$SYMPHONY_RUN_CALLS"

    if [ "$*" = "exec -- mix escript.build" ]; then
      exit 0
    fi

    workflow=""
    for arg in "$@"; do
      workflow="$arg"
    done

    {
      printf 'AUTOMATED_REVIEWER=%s\\n' "${AUTOMATED_REVIEWER-}"
      printf 'SYMPHONY_PROFILE=%s\\n' "${SYMPHONY_PROFILE-}"
      printf 'SYMPHONY_PROJECT_SLUGS=%s\\n' "${SYMPHONY_PROJECT_SLUGS-}"
      printf 'SYMPHONY_PROJECT_NAMES=%s\\n' "${SYMPHONY_PROJECT_NAMES-}"
      printf 'SYMPHONY_REPO=%s\\n' "${SYMPHONY_REPO-}"
      printf 'SYMPHONY_BASE_BRANCH=%s\\n' "${SYMPHONY_BASE_BRANCH-}"
      printf 'PWD=%s\\n' "$PWD"
      printf 'ARGS=%s\\n' "$*"
      printf 'WORKFLOW=%s\\n' "$workflow"
      printf 'CALLS=%s\\n' "$(paste -sd '|' "$SYMPHONY_RUN_CALLS")"
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
