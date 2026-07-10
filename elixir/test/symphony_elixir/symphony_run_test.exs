defmodule SymphonyElixir.SymphonyRunTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @launcher Path.join(@repo_root, "bin/symphony-run")

  test "launcher is implemented in Python without a Ruby runtime" do
    launcher = File.read!(@launcher)

    assert String.starts_with?(launcher, "#!/usr/bin/env python3\n")
    refute launcher =~ "ruby"
  end

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

    assert capture["SYMPHONY_PROJECT_NAMES"] == "grotto,gl-infra,gl-skills,symphony,voxvault,tuneframe"
    assert capture["SYMPHONY_REPO"] == ""
    assert capture["SYMPHONY_BASE_BRANCH"] == ""
  end

  test "rebuilds the escript before launching" do
    capture = run_launcher!("grandline", project_env: "SYMPHONY_PROJECT_SLUGS=\"project-a\"\n")

    assert capture["CALLS"] ==
             "exec -- mix escript.build|exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails #{capture["WORKFLOW"]}"
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

  test "can launch the Maestro workflow with a caller-selected profile" do
    capture =
      run_launcher!("symphony",
        profile: "maestro",
        workflow_file: "MAESTRO_WORKFLOW.md",
        profile_env: """
        LINEAR_API_KEY="maestro-token"
        """
      )

    assert capture["SYMPHONY_PROFILE"] == "maestro"
    assert capture["WORKFLOW"] =~ "/workflows/symphony/MAESTRO_WORKFLOW.md"
    assert capture["SYMPHONY_MAESTRO_WORKSPACE_ROOT"] == capture["SYMPHONY_WORKSPACE_ROOT"] <> "-maestro"
  end

  test "--maestro selects the Maestro workflow, profile, and its own port" do
    capture =
      run_launcher!("symphony",
        launcher_args: ["--maestro"],
        profile: "maestro",
        caller_profile: nil,
        workflow_file: "MAESTRO_WORKFLOW.md",
        caller_workflow_file: nil,
        project_env: """
        SYMPHONY_PROJECT_SLUGS="project-a"
        SYMPHONY_PORT="4000"
        """,
        profile_env: """
        LINEAR_API_KEY="maestro-token"
        SYMPHONY_MAESTRO_PORT="4001"
        """
      )

    assert capture["SYMPHONY_PROFILE"] == "maestro"
    assert capture["WORKFLOW"] =~ "/workflows/symphony/MAESTRO_WORKFLOW.md"
    assert capture["ARGS"] =~ " --port 4001 "
    refute capture["ARGS"] =~ "--port 4000"
  end

  test "--maestro without SYMPHONY_MAESTRO_PORT disables the dashboard" do
    capture =
      run_launcher!("symphony",
        launcher_args: ["--maestro"],
        profile: "maestro",
        caller_profile: nil,
        workflow_file: "MAESTRO_WORKFLOW.md",
        caller_workflow_file: nil,
        project_env: """
        SYMPHONY_PROJECT_SLUGS="project-a"
        SYMPHONY_PORT="4000"
        """,
        profile_env: """
        LINEAR_API_KEY="maestro-token"
        """
      )

    refute capture["ARGS"] =~ "--port"
  end

  test "Agavemindlab Linear project slugs use Linear slugId values" do
    expected_slugs = %{
      "gl-infra" => "02773795419d",
      "gl-skills" => "1ecc8649e9da",
      "grotto" => "bb8f9b7a6364",
      "symphony" => "977d7a7b6c0e",
      "tuneframe" => "8d3ce7cdbdea",
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

  test "mints GitHub App token when app credentials are configured" do
    capture = run_launcher!("symphony", github_app: true)

    assert capture["GH_TOKEN"] == "test-installation-token"
    assert capture["GITHUB_TOKEN"] == "test-installation-token"
    assert capture["GITHUB_FORK_OWNER"] == "agavemindlab"
    assert capture["GIT_AUTHOR_NAME"] == "gl-symphony[bot]"
    assert capture["GIT_AUTHOR_EMAIL"] == "gl-symphony[bot]@users.noreply.github.com"
    assert capture["GIT_COMMITTER_NAME"] == "gl-symphony[bot]"
    assert capture["GIT_COMMITTER_EMAIL"] == "gl-symphony[bot]@users.noreply.github.com"

    refute String.contains?(capture["GH_TOKEN"], "BEGIN")
    refute String.contains?(capture["GIT_AUTHOR_EMAIL"], "test-private-key")
  end

  test "GitHub App mode replaces profile GitHub credentials" do
    capture =
      run_launcher!("symphony",
        github_app: true,
        profile_env: """
        LINEAR_API_KEY="test-token"
        GH_TOKEN="profile-pat"
        GITHUB_TOKEN="profile-pat"
        GITHUB_FORK_OWNER="hongqn"
        GIT_AUTHOR_NAME="hongqn-bot"
        GIT_COMMITTER_NAME="hongqn-bot"
        GITHUB_APP_ID="4075542"
        GITHUB_APP_INSTALLATION_ID="140846909"
        GITHUB_APP_PRIVATE_KEY_PATH="{PRIVATE_KEY_PATH}"
        """
      )

    assert capture["GH_TOKEN"] == "test-installation-token"
    assert capture["GITHUB_TOKEN"] == "test-installation-token"
    assert capture["GITHUB_FORK_OWNER"] == "agavemindlab"
  end

  test "keeps profile GitHub credentials when the project has not enabled the app" do
    capture =
      run_launcher!("gl-infra",
        github_app: true,
        profile_env: """
        LINEAR_API_KEY="test-token"
        GH_TOKEN="profile-pat"
        GITHUB_TOKEN="profile-pat"
        GITHUB_FORK_OWNER="hongqn"
        GIT_AUTHOR_NAME="hongqn-bot"
        GIT_COMMITTER_NAME="hongqn-bot"
        GITHUB_APP_ID="4075542"
        GITHUB_APP_INSTALLATION_ID="140846909"
        GITHUB_APP_PRIVATE_KEY_PATH="{PRIVATE_KEY_PATH}"
        """
      )

    assert capture["GH_TOKEN"] == "profile-pat"
    assert capture["GITHUB_TOKEN"] == "profile-pat"
    assert capture["GITHUB_FORK_OWNER"] == "hongqn"
    assert capture["GIT_AUTHOR_NAME"] == "hongqn-bot"
    assert capture["GIT_COMMITTER_NAME"] == "hongqn-bot"
    assert capture["GITHUB_APP_API_CALLS"] == ""
  end

  test "skips GitHub App API calls when app credentials are absent" do
    capture =
      run_launcher!("symphony",
        profile_env: """
        LINEAR_API_KEY="test-token"
        GH_TOKEN="profile-pat"
        GITHUB_TOKEN="profile-pat"
        GITHUB_FORK_OWNER="hongqn"
        """
      )

    assert capture["GH_TOKEN"] == "profile-pat"
    assert capture["GITHUB_TOKEN"] == "profile-pat"
    assert capture["GITHUB_FORK_OWNER"] == "hongqn"
    assert capture["GITHUB_APP_API_CALLS"] == ""
  end

  defp run_launcher!(project, opts \\ []) do
    run_id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "symphony-run-test-#{run_id}")
    home = Path.join(tmp_root, "home")
    fake_bin = Path.join(tmp_root, "bin")
    fake_repo_root = Path.join(tmp_root, "repo")
    capture_path = Path.join(tmp_root, "capture.env")
    calls_path = Path.join(tmp_root, "calls.log")
    curl_capture_path = Path.join(tmp_root, "curl-capture.log")
    private_key_path = Path.join(tmp_root, "test-private-key.pem")

    File.mkdir_p!(Path.join(home, ".config/symphony"))
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.join(fake_repo_root, "elixir"))
    File.mkdir_p!(Path.join(fake_repo_root, "workflows/#{project}"))
    File.mkdir_p!(Path.join(fake_repo_root, "workflows/agavemindlab"))
    File.write!(Path.join(fake_repo_root, "workflows/agavemindlab/WORKFLOW.md"), "# Test workflow\n")
    File.write!(Path.join(fake_repo_root, "workflows/agavemindlab/MAESTRO_WORKFLOW.md"), "# Maestro workflow\n")

    workflow_name = Keyword.get(opts, :workflow_file, "WORKFLOW.md")
    namespace = setup_workflow_fixture!(fake_repo_root, project, workflow_name)

    real_defaults = Path.join(@repo_root, "workflows/#{namespace}/project.env.defaults")

    if File.exists?(real_defaults) do
      File.mkdir_p!(Path.join(fake_repo_root, "workflows/#{namespace}"))

      File.write!(
        Path.join(fake_repo_root, "workflows/#{namespace}/project.env.defaults"),
        File.read!(real_defaults)
      )
    end

    File.write!(Path.join(fake_repo_root, "workflows/agavemindlab/WORKFLOW.md"), "# Test workflow\n")

    project_env = project_env_fixture(project, opts)
    File.write!(Path.join(fake_repo_root, "workflows/#{project}/project.env"), project_env)

    launcher_args = Keyword.get(opts, :launcher_args, [])
    profile = Keyword.get(opts, :profile, "grandline")

    profile_env =
      opts
      |> Keyword.get(:profile_env, profile_env(opts, private_key_path))
      |> String.replace("{PRIVATE_KEY_PATH}", private_key_path)

    File.write!(
      Path.join(home, ".config/symphony/grandline.env"),
      profile_env
    )

    File.write!(Path.join(home, ".config/symphony/#{profile}.env"), profile_env)

    File.write!(Path.join(fake_bin, "mise"), fake_mise_script())
    File.chmod!(Path.join(fake_bin, "mise"), 0o755)
    File.write!(Path.join(fake_bin, "curl"), fake_curl_script())
    File.chmod!(Path.join(fake_bin, "curl"), 0o755)

    maybe_write_private_key!(opts, private_key_path)

    env = [
      {"HOME", home},
      {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")},
      {"SYMPHONY_REPO_ROOT", fake_repo_root},
      {"SYMPHONY_RUN_CAPTURE", capture_path},
      {"SYMPHONY_RUN_CALLS", calls_path},
      {"SYMPHONY_RUN_CURL_CAPTURE", curl_capture_path},
      {"SYMPHONY_PROFILE",
       case Keyword.fetch(opts, :caller_profile) do
         {:ok, value} -> value
         :error -> if(profile == "grandline", do: nil, else: profile)
       end},
      {"SYMPHONY_WORKFLOW_FILE",
       case Keyword.fetch(opts, :caller_workflow_file) do
         {:ok, value} -> value
         :error -> if(workflow_name == "WORKFLOW.md", do: nil, else: workflow_name)
       end},
      {"SYMPHONY_PROJECT_SLUG", nil},
      {"SYMPHONY_PROJECT_SLUGS", nil},
      {"SYMPHONY_PROJECT_NAME", nil},
      {"SYMPHONY_PROJECT_NAMES", nil},
      {"SYMPHONY_REPO", nil},
      {"SYMPHONY_BASE_BRANCH", nil},
      {"SYMPHONY_PROJECT_DIR", nil},
      {"SYMPHONY_PORT", nil},
      {"SYMPHONY_MAESTRO_PORT", nil},
      {"SYMPHONY_MAESTRO_WORKSPACE_ROOT", nil},
      {"AUTOMATED_REVIEWER", nil},
      {"GH_TOKEN", nil},
      {"GITHUB_TOKEN", nil},
      {"GITHUB_FORK_OWNER", nil},
      {"GITHUB_APP_ENABLED", nil},
      {"GIT_AUTHOR_NAME", nil},
      {"GIT_AUTHOR_EMAIL", nil},
      {"GIT_COMMITTER_NAME", nil},
      {"GIT_COMMITTER_EMAIL", nil}
    ]

    try do
      assert {output, 0} =
               System.cmd(@launcher, [project | launcher_args], env: env, stderr_to_stdout: true)

      assert output =~ "symphony-run: starting project=#{project} profile=#{profile}"

      capture_path
      |> File.read!()
      |> parse_capture()
      |> Map.put("GITHUB_APP_API_CALLS", read_if_exists(curl_capture_path))
    after
      File.rm_rf(tmp_root)
    end
  end

  defp profile_env(opts, private_key_path) do
    if Keyword.get(opts, :github_app, false) do
      """
      LINEAR_API_KEY="test-token"
      GITHUB_APP_ID="4075542"
      GITHUB_APP_INSTALLATION_ID="140846909"
      GITHUB_APP_PRIVATE_KEY_PATH="#{private_key_path}"
      """
    else
      "LINEAR_API_KEY=\"test-token\"\n"
    end
  end

  defp maybe_write_private_key!(opts, path) do
    if Keyword.get(opts, :github_app, false) do
      assert {_, 0} =
               System.cmd("openssl", ["genrsa", "-out", path, "2048"], stderr_to_stdout: true)
    end
  end

  defp setup_workflow_fixture!(fake_repo_root, project, workflow_name) do
    real_workflow_file = Path.join(@repo_root, "workflows/#{project}/WORKFLOW.md")
    fake_workflow_file = Path.join(fake_repo_root, "workflows/#{project}/WORKFLOW.md")

    case File.read_link(real_workflow_file) do
      {:ok, target} ->
        File.ln_s!(target, fake_workflow_file)
        maybe_link_alternate_workflow!(fake_repo_root, project, target, workflow_name)

        resolved_target = Path.expand(target, Path.dirname(fake_workflow_file))
        File.mkdir_p!(Path.dirname(resolved_target))
        File.write!(resolved_target, "# Test workflow\n")
        target |> Path.dirname() |> Path.basename()

      {:error, _} ->
        File.write!(fake_workflow_file, "# Test workflow\n")
        project
    end
  end

  defp maybe_link_alternate_workflow!(_fake_repo_root, _project, _target, "WORKFLOW.md"), do: :ok

  defp maybe_link_alternate_workflow!(fake_repo_root, project, target, workflow_name) do
    File.ln_s!(
      "../#{Path.basename(Path.dirname(target))}/#{workflow_name}",
      Path.join(fake_repo_root, "workflows/#{project}/#{workflow_name}")
    )
  end

  defp project_env_fixture(project, opts) do
    case Keyword.fetch(opts, :project_env) do
      {:ok, contents} ->
        contents

      :error ->
        Path.join(@repo_root, "workflows/#{project}/project.env")
        |> File.read!()
        |> Kernel.<>(Keyword.get(opts, :project_env_extra, ""))
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
      printf 'SYMPHONY_WORKSPACE_ROOT=%s\\n' "${SYMPHONY_WORKSPACE_ROOT-}"
      printf 'SYMPHONY_MAESTRO_WORKSPACE_ROOT=%s\\n' "${SYMPHONY_MAESTRO_WORKSPACE_ROOT-}"
      printf 'GH_TOKEN=%s\\n' "${GH_TOKEN-}"
      printf 'GITHUB_TOKEN=%s\\n' "${GITHUB_TOKEN-}"
      printf 'GITHUB_FORK_OWNER=%s\\n' "${GITHUB_FORK_OWNER-}"
      printf 'GIT_AUTHOR_NAME=%s\\n' "${GIT_AUTHOR_NAME-}"
      printf 'GIT_AUTHOR_EMAIL=%s\\n' "${GIT_AUTHOR_EMAIL-}"
      printf 'GIT_COMMITTER_NAME=%s\\n' "${GIT_COMMITTER_NAME-}"
      printf 'GIT_COMMITTER_EMAIL=%s\\n' "${GIT_COMMITTER_EMAIL-}"
      printf 'PWD=%s\\n' "$PWD"
      printf 'ARGS=%s\\n' "$*"
      printf 'WORKFLOW=%s\\n' "$workflow"
      printf 'CALLS=%s\\n' "$(paste -sd '|' "$SYMPHONY_RUN_CALLS")"
    } > "$SYMPHONY_RUN_CAPTURE"
    """
  end

  defp fake_curl_script do
    """
    #!/bin/sh
    method="GET"
    output_file=""
    url=""
    status="200"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o)
          output_file="$2"
          shift 2
          ;;
        -w)
          shift 2
          ;;
        -X)
          method="$2"
          shift 2
          ;;
        -H)
          shift 2
          ;;
        -s|-S|-L|-sS|-fsS)
          shift
          ;;
        *)
          url="$1"
          shift
          ;;
      esac
    done

    printf '%s %s\\n' "$method" "$url" >> "$SYMPHONY_RUN_CURL_CAPTURE"

    case "$method $url" in
      "GET https://api.github.com/app/installations/140846909")
        body='{"account":{"login":"agavemindlab"},"app_slug":"gl-symphony"}'
        ;;
      "POST https://api.github.com/app/installations/140846909/access_tokens")
        body='{"token":"test-installation-token","expires_at":"2026-06-17T13:00:00Z"}'
        ;;
      *)
        status="404"
        body='{"message":"unexpected fake curl request"}'
        ;;
    esac

    if [ -n "$output_file" ]; then
      printf '%s' "$body" > "$output_file"
    else
      printf '%s' "$body"
    fi

    printf '%s' "$status"
    """
  end

  defp read_if_exists(path) do
    if File.exists?(path), do: File.read!(path), else: ""
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
