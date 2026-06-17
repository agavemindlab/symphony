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
        GITHUB_APP_ID="4075542"
        GITHUB_APP_INSTALLATION_ID="140846909"
        GITHUB_APP_PRIVATE_KEY_PATH="{PRIVATE_KEY_PATH}"
        """
      )

    assert capture["GH_TOKEN"] == "test-installation-token"
    assert capture["GITHUB_TOKEN"] == "test-installation-token"
    assert capture["GITHUB_FORK_OWNER"] == "agavemindlab"
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
    curl_capture_path = Path.join(tmp_root, "curl-capture.log")
    private_key_path = Path.join(tmp_root, "test-private-key.pem")

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

    profile_env =
      opts
      |> Keyword.get(:profile_env, profile_env(opts, private_key_path))
      |> String.replace("{PRIVATE_KEY_PATH}", private_key_path)

    File.write!(Path.join(home, ".config/symphony/grandline.env"), profile_env)

    File.write!(Path.join(fake_bin, "mise"), fake_mise_script())
    File.chmod!(Path.join(fake_bin, "mise"), 0o755)
    File.write!(Path.join(fake_bin, "curl"), fake_curl_script())
    File.chmod!(Path.join(fake_bin, "curl"), 0o755)

    if Keyword.get(opts, :github_app, false) do
      File.write!(private_key_path, test_private_key())
    end

    env = [
      {"HOME", home},
      {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")},
      {"SYMPHONY_REPO_ROOT", fake_repo_root},
      {"SYMPHONY_RUN_CAPTURE", capture_path},
      {"SYMPHONY_RUN_CURL_CAPTURE", curl_capture_path},
      {"SYMPHONY_PROFILE", nil},
      {"AUTOMATED_REVIEWER", nil},
      {"GH_TOKEN", nil},
      {"GITHUB_TOKEN", nil},
      {"GITHUB_FORK_OWNER", nil},
      {"GIT_AUTHOR_NAME", nil},
      {"GIT_AUTHOR_EMAIL", nil},
      {"GIT_COMMITTER_NAME", nil},
      {"GIT_COMMITTER_EMAIL", nil}
    ]

    try do
      assert {output, 0} = System.cmd(@launcher, [project], env: env, stderr_to_stdout: true)
      assert output == ""

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

  defp fake_mise_script do
    """
    #!/bin/sh
    {
      printf 'AUTOMATED_REVIEWER=%s\\n' "${AUTOMATED_REVIEWER-}"
      printf 'SYMPHONY_PROFILE=%s\\n' "${SYMPHONY_PROFILE-}"
      printf 'GH_TOKEN=%s\\n' "${GH_TOKEN-}"
      printf 'GITHUB_TOKEN=%s\\n' "${GITHUB_TOKEN-}"
      printf 'GITHUB_FORK_OWNER=%s\\n' "${GITHUB_FORK_OWNER-}"
      printf 'GIT_AUTHOR_NAME=%s\\n' "${GIT_AUTHOR_NAME-}"
      printf 'GIT_AUTHOR_EMAIL=%s\\n' "${GIT_AUTHOR_EMAIL-}"
      printf 'GIT_COMMITTER_NAME=%s\\n' "${GIT_COMMITTER_NAME-}"
      printf 'GIT_COMMITTER_EMAIL=%s\\n' "${GIT_COMMITTER_EMAIL-}"
      printf 'PWD=%s\\n' "$PWD"
      printf 'ARGS=%s\\n' "$*"
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

  defp test_private_key do
    {pem, 0} =
      System.cmd("ruby", ["-ropenssl", "-e", "puts OpenSSL::PKey::RSA.new(2048).to_pem"])

    pem
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
