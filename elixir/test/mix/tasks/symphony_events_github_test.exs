defmodule Mix.Tasks.Symphony.Events.GithubTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Events.Github

  @demo_prs Jason.encode!([
              %{
                "number" => 7,
                "title" => "Fix DEV-33 comment flow",
                "headRefName" => "hongqn/dev-33-fix",
                "url" => "https://github.com/hongqn/demo/pull/7",
                "mergedAt" => "2026-07-01T10:00:00Z",
                "reviews" => [%{"state" => "APPROVED"}, %{"state" => "COMMENTED"}]
              },
              %{
                "number" => 8,
                "title" => "chore: bump deps",
                "headRefName" => "chore/bump-deps",
                "url" => "https://github.com/hongqn/demo/pull/8",
                "mergedAt" => "2026-07-02T10:00:00Z",
                "reviews" => []
              },
              %{
                "number" => 9,
                "title" => "Rollback per review",
                "headRefName" => "hongqn/DEV-44-rollback",
                "url" => "https://github.com/hongqn/demo/pull/9",
                "mergedAt" => "2026-07-03T10:00:00Z",
                "reviews" => [%{"state" => "CHANGES_REQUESTED"}, %{"state" => "APPROVED"}]
              }
            ])

  setup do
    Mix.Task.reenable("symphony.events.github")
    :ok
  end

  test "sweeps merged PRs, derives review fields and issue identifiers, and is idempotent" do
    analytics_path = tmp_path("github-events.ndjson")

    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$4" = "hongqn/demo" ]; then
        cat "$GH_DEMO_PRS"
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        output =
          capture_io(fn ->
            Github.run(["--repo", "hongqn/demo", "--analytics", analytics_path])
          end)

        assert output =~
                 "github: 1 repos scanned, 3 events appended (0 already present, 0 fetch failures) -> #{analytics_path}"

        assert File.read!(log_path) =~
                 "pr list --repo hongqn/demo --state merged --limit 200 --json number,title,headRefName,url,mergedAt,reviews"

        assert [reviewed, unreviewed, changes_requested] = read_events(analytics_path)

        assert %{
                 "event_type" => "pr_merged",
                 "event_id" => "github-pr-hongqn/demo#7",
                 "repo" => "hongqn/demo",
                 "pr_number" => 7,
                 "pr_url" => "https://github.com/hongqn/demo/pull/7",
                 "issue_identifier" => "DEV-33",
                 "reviews_count" => 2,
                 "changes_requested" => false,
                 "approved" => true,
                 "occurred_at" => "2026-07-01T10:00:00Z",
                 "source" => "github"
               } = reviewed

        assert is_binary(reviewed["recorded_at"])

        assert %{
                 "event_id" => "github-pr-hongqn/demo#8",
                 "issue_identifier" => nil,
                 "reviews_count" => 0,
                 "changes_requested" => false,
                 "approved" => false
               } = unreviewed

        # The identifier comes from headRefName first, title as fallback.
        assert %{
                 "event_id" => "github-pr-hongqn/demo#9",
                 "issue_identifier" => "DEV-44",
                 "reviews_count" => 2,
                 "changes_requested" => true,
                 "approved" => true
               } = changes_requested

        # Re-running appends nothing: every event id is already present.
        Mix.Task.reenable("symphony.events.github")

        rerun_output =
          capture_io(fn ->
            Github.run(["--repo", "hongqn/demo", "--analytics", analytics_path])
          end)

        assert rerun_output =~ "github: 1 repos scanned, 0 events appended (3 already present, 0 fetch failures)"
        assert length(read_events(analytics_path)) == 3
      end
    )
  end

  test "dry-run prints per-repo counts, counts fetch failures, and writes nothing" do
    analytics_path = tmp_path("github-dry-run.ndjson")

    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$4" = "hongqn/demo" ]; then
        cat "$GH_DEMO_PRS"
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$4" = "hongqn/broken" ]; then
        printf 'GraphQL: Could not resolve to a Repository\n' >&2
        exit 1
      fi

      exit 99
      """,
      fn log_path ->
        stderr =
          capture_io(:stderr, fn ->
            output =
              capture_io(fn ->
                Github.run([
                  "--repo",
                  "hongqn/demo",
                  "--repo",
                  "hongqn/broken",
                  "--limit",
                  "5",
                  "--analytics",
                  analytics_path,
                  "--dry-run"
                ])
              end)

            assert output =~ "dry-run hongqn/demo: 3 new event(s), 0 already present"

            assert output =~
                     "github (dry-run): 2 repos scanned, 3 events would be appended (0 already present, 1 fetch failures)"
          end)

        assert stderr =~ "github: merged PR fetch failed for hongqn/broken: exit 1: GraphQL"
        assert File.read!(log_path) =~ "pr list --repo hongqn/demo --state merged --limit 5 --json"
        refute File.exists?(analytics_path)
      end
    )
  end

  test "counts malformed and non-list gh JSON payloads as fetch failures" do
    analytics_path = tmp_path("github-bad-json.ndjson")

    with_fake_gh(
      """
      #!/bin/sh
      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$4" = "hongqn/not-json" ]; then
        printf 'not-json\n'
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ] && [ "$4" = "hongqn/not-a-list" ]; then
        printf '{"data": []}\n'
        exit 0
      fi

      exit 99
      """,
      fn _log_path ->
        stderr =
          capture_io(:stderr, fn ->
            output =
              capture_io(fn ->
                Github.run(["--repo", "hongqn/not-json", "--repo", "hongqn/not-a-list", "--analytics", analytics_path])
              end)

            assert output =~ "github: 2 repos scanned, 0 events appended (0 already present, 2 fetch failures)"
          end)

        assert stderr =~ ~r/merged PR fetch failed for hongqn\/not-json: unexpected byte at position \d+/
        assert stderr =~ "merged PR fetch failed for hongqn/not-a-list: unexpected gh pr list JSON payload"
        refute File.exists?(analytics_path)
      end
    )
  end

  test "default repos resolve from the app env override, then SYMPHONY_GITHUB_REPOS" do
    analytics_path = tmp_path("github-default-repos.ndjson")

    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        printf '[]\n'
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        Application.put_env(:symphony_elixir, :github_repos, ["hongqn/from-app-env"])

        try do
          output = capture_io(fn -> Github.run(["--analytics", analytics_path, "--dry-run"]) end)
          assert output =~ "github (dry-run): 1 repos scanned, 0 events would be appended"
          assert File.read!(log_path) =~ "pr list --repo hongqn/from-app-env"
        after
          Application.delete_env(:symphony_elixir, :github_repos)
        end

        Mix.Task.reenable("symphony.events.github")
        File.write!(log_path, "")

        with_env(%{"SYMPHONY_GITHUB_REPOS" => "hongqn/one, hongqn/two,"}, fn ->
          output = capture_io(fn -> Github.run(["--analytics", analytics_path, "--dry-run"]) end)
          assert output =~ "github (dry-run): 2 repos scanned, 0 events would be appended"
        end)

        log = File.read!(log_path)
        assert log =~ "pr list --repo hongqn/one"
        assert log =~ "pr list --repo hongqn/two"
      end
    )
  end

  test "--since forwards a merged-date search filter to gh" do
    analytics_path = tmp_path("github-since-events.ndjson")

    with_fake_gh(
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$GH_LOG"

      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 0
      fi

      if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
        cat "$GH_DEMO_PRS"
        exit 0
      fi

      exit 99
      """,
      fn log_path ->
        capture_io(fn ->
          Github.run(["--repo", "hongqn/demo", "--since", "2026-06-01", "--analytics", analytics_path])
        end)

        assert File.read!(log_path) =~ "--search merged:>=2026-06-01"
      end
    )
  end

  test "raises without repos, without gh, without gh auth, and on invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn -> Github.run(["--wat"]) end
    assert_raise Mix.Error, ~r/Invalid --since date/, fn -> Github.run(["--repo", "a/b", "--since", "junk"]) end

    with_env(%{"SYMPHONY_GITHUB_REPOS" => nil}, fn ->
      assert_raise Mix.Error, ~r/No GitHub repos to sweep/, fn -> Github.run([]) end
    end)

    with_env(%{"PATH" => ""}, fn ->
      assert_raise Mix.Error, ~r/gh CLI is required/, fn -> Github.run(["--repo", "hongqn/demo"]) end
    end)

    with_fake_gh(
      """
      #!/bin/sh
      if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
        exit 1
      fi
      exit 99
      """,
      fn _log_path ->
        assert_raise Mix.Error, ~r/gh is not authenticated/, fn -> Github.run(["--repo", "hongqn/demo"]) end
      end
    )
  end

  defp with_fake_gh(script, fun) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "symphony-events-github-test-#{unique}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "gh.log")
    prs_path = Path.join(root, "demo-prs.json")

    try do
      File.mkdir_p!(bin_dir)
      File.write!(log_path, "")
      File.write!(prs_path, @demo_prs)
      gh_path = Path.join(bin_dir, "gh")
      File.write!(gh_path, script)
      File.chmod!(gh_path, 0o755)

      with_env(
        %{
          "GH_LOG" => log_path,
          "GH_DEMO_PRS" => prs_path,
          "PATH" => Enum.join([bin_dir, System.get_env("PATH") || ""], ":")
        },
        fn -> fun.(log_path) end
      )
    after
      File.rm_rf!(root)
    end
  end

  defp with_env(overrides, fun) do
    previous = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(overrides, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp read_events(analytics_path) do
    analytics_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp tmp_path(name) do
    root = Path.join(System.tmp_dir!(), "symphony-events-github-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Path.join(root, name)
  end
end
