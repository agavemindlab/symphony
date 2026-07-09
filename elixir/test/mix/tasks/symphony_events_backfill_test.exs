defmodule Mix.Tasks.Symphony.Events.BackfillTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Events.Backfill

  defmodule FailingCommentsClient do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(_state_names) do
      {:ok, [%Issue{id: "issue-fail", identifier: "DEV-500", url: "https://linear.app/DEV-500", state: "Done", labels: ["symphony"]}]}
    end

    def fetch_issue_comments(_issue_id), do: {:error, :comment_fetch_failed}
  end

  defmodule FailingIssuesClient do
    def fetch_issues_by_states(_state_names), do: {:error, :issue_fetch_failed}
  end

  defmodule RaisingCommentsClient do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(_state_names) do
      {:ok, [:not_an_issue, %Issue{id: "issue-raise", identifier: "DEV-501", url: "https://linear.app/DEV-501", state: "Done"}]}
    end

    def fetch_issue_comments(_issue_id), do: raise("comment fetch exploded")
  end

  setup do
    previous_linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(previous_linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_linear_client_module)
      end
    end)

    :ok
  end

  test "backfills terminal + active issues, filters labels client-side, dedups issue ids, and is idempotent" do
    dir = tmp_dir!()
    workflow_path = Path.join(dir, "WORKFLOW.md")
    analytics_path = Path.join(dir, "analytics.ndjson")

    write_workflow_file!(workflow_path, tracker_kind: "memory", tracker_required_labels: ["Symphony"])
    seed_memory_issues_and_comments()

    output = capture_io(fn -> Backfill.run(["--workflow", workflow_path, "--analytics", analytics_path]) end)

    assert output =~ "backfill: 2 issues scanned, 5 events appended (0 already present, 0 fetch failures) -> #{analytics_path}"

    events = read_events(analytics_path)
    assert length(events) == 5
    assert Enum.all?(events, &(&1["source"] == "backfill"))

    assert Enum.map(events, & &1["event_id"]) |> Enum.sort() == [
             "human-comment-impl-1-human",
             "maestro_review:impl-1-maestro",
             "phase_published:impl-1",
             "phase_published:req-1",
             "phase_reworked:impl-1-rework"
           ]

    maestro = Enum.find(events, &(&1["event_type"] == "maestro_review"))
    assert maestro["artifact_comment_id"] == "impl-1"
    assert maestro["recommendation"] == "request_changes"
    assert maestro["issue_id"] == "issue-done"
    assert maestro["issue_identifier"] == "DEV-201"
    assert maestro["issue_url"] == "https://linear.app/DEV-201"

    human = Enum.find(events, &(&1["event_type"] == "human_comment"))
    assert human["event_id"] == "human-comment-impl-1-human"
    assert human["occurred_at"] == "2026-07-01T11:30:00Z"
    assert human["author_name"] == "Alice"
    assert human["issue_identifier"] == "DEV-201"

    refute Enum.any?(events, &(&1["issue_id"] in ["issue-unlabeled", "issue-backlog"]))

    # Re-running appends nothing: every derived event id is already present.
    rerun_output = capture_io(fn -> Backfill.run(["--workflow", workflow_path, "--analytics", analytics_path]) end)
    assert rerun_output =~ "backfill: 2 issues scanned, 0 events appended (5 already present, 0 fetch failures)"
    assert length(read_events(analytics_path)) == 5
  end

  test "dry-run prints per-issue counts and writes nothing" do
    dir = tmp_dir!()
    workflow_path = Path.join(dir, "WORKFLOW.md")
    analytics_path = Path.join(dir, "analytics.ndjson")

    write_workflow_file!(workflow_path, tracker_kind: "memory", tracker_required_labels: ["Symphony"])
    seed_memory_issues_and_comments()

    output =
      capture_io(fn -> Backfill.run(["--workflow", workflow_path, "--analytics", analytics_path, "--dry-run"]) end)

    assert output =~ "dry-run DEV-201: 4 new event(s), 0 already present"
    assert output =~ "dry-run DEV-202: 1 new event(s), 0 already present"

    assert output =~
             "backfill (dry-run): 2 issues scanned, 5 events would be appended (0 already present, 0 fetch failures)"

    refute File.exists?(analytics_path)
  end

  test "comment fetch errors are logged per issue and counted without aborting the sweep" do
    dir = tmp_dir!()
    workflow_path = Path.join(dir, "WORKFLOW.md")
    analytics_path = Path.join(dir, "analytics.ndjson")

    write_workflow_file!(workflow_path, tracker_kind: "linear")
    Application.put_env(:symphony_elixir, :linear_client_module, FailingCommentsClient)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> Backfill.run(["--workflow", workflow_path, "--analytics", analytics_path]) end)
        assert output =~ "backfill: 1 issues scanned, 0 events appended (0 already present, 1 fetch failures)"
      end)

    assert stderr =~ "DEV-500"
    assert stderr =~ ":comment_fetch_failed"
    refute File.exists?(analytics_path)
  end

  test "issue fetch errors abort with the fetched state list" do
    dir = tmp_dir!()
    workflow_path = Path.join(dir, "WORKFLOW.md")

    write_workflow_file!(workflow_path, tracker_kind: "linear")
    Application.put_env(:symphony_elixir, :linear_client_module, FailingIssuesClient)

    assert_raise Mix.Error, ~r/Unable to fetch issues by states/, fn ->
      Backfill.run(["--workflow", workflow_path, "--analytics", Path.join(dir, "analytics.ndjson")])
    end
  end

  test "comment fetch raises are logged per issue and counted" do
    dir = tmp_dir!()
    workflow_path = Path.join(dir, "WORKFLOW.md")
    analytics_path = Path.join(dir, "analytics.ndjson")

    write_workflow_file!(workflow_path, tracker_kind: "linear")
    Application.put_env(:symphony_elixir, :linear_client_module, RaisingCommentsClient)

    stderr =
      capture_io(:stderr, fn ->
        output = capture_io(fn -> Backfill.run(["--workflow", workflow_path, "--analytics", analytics_path]) end)
        assert output =~ "backfill: 1 issues scanned, 0 events appended (0 already present, 1 fetch failures)"
      end)

    assert stderr =~ "DEV-501"
    assert stderr =~ "comment fetch exploded"
    refute File.exists?(analytics_path)
  end

  test "rejects missing --workflow and invalid options" do
    assert_raise Mix.Error, ~r/--workflow PATH is required/, fn -> Backfill.run([]) end
    assert_raise Mix.Error, ~r/Invalid option/, fn -> Backfill.run(["--wat"]) end
  end

  test "an unparsable workflow config raises with a hint to source the env layers" do
    dir = tmp_dir!()
    workflow_path = Path.join(dir, "WORKFLOW.md")
    write_workflow_file!(workflow_path, poll_interval_ms: "invalid")

    assert_raise Mix.Error, ~r/bin\/README\.md/, fn ->
      Backfill.run(["--workflow", workflow_path, "--analytics", Path.join(dir, "analytics.ndjson")])
    end
  end

  defp seed_memory_issues_and_comments do
    issues = [
      %Issue{id: "issue-done", identifier: "DEV-201", url: "https://linear.app/DEV-201", state: "Done", labels: ["SYMPHONY", "backend"]},
      # Duplicate id: de-duplicated before processing.
      %Issue{id: "issue-done", identifier: "DEV-201", url: "https://linear.app/DEV-201", state: "Done", labels: ["SYMPHONY"]},
      %Issue{id: "issue-active", identifier: "DEV-202", url: "https://linear.app/DEV-202", state: "In Progress", labels: ["symphony"]},
      %Issue{id: "issue-unlabeled", identifier: "DEV-203", url: "https://linear.app/DEV-203", state: "Done", labels: ["other"]},
      %Issue{id: "issue-backlog", identifier: "DEV-204", url: "https://linear.app/DEV-204", state: "Backlog", labels: ["symphony"]},
      :not_an_issue
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-done" => [
        comment("impl-1", "## Implementation\n\nPR: https://github.com/x/y/pull/1", created_at: "2026-07-01T10:00:00Z", author_is_bot: true),
        comment(
          "impl-1-maestro",
          "🤖 Maestro 预审核: 本轮交付还需修改。\n\n建议回复方式: request changes\n置信度 7/10",
          parent_id: "impl-1",
          created_at: "2026-07-01T11:00:00Z",
          author_is_bot: true
        ),
        comment("impl-1-human", "同意 Maestro，请修改。", parent_id: "impl-1", created_at: "2026-07-01T11:30:00Z", author_name: "Alice"),
        comment("impl-1-rework", "🔧 本轮修改：按反馈调整。", parent_id: "impl-1", created_at: "2026-07-01T12:00:00Z", author_is_bot: true)
      ],
      "issue-active" => [
        comment("req-1", "## Requirements\n\n目标", created_at: "2026-07-01T09:00:00Z", author_is_bot: true)
      ],
      "issue-unlabeled" => [
        comment("skip-1", "## Design\n\n不应出现", created_at: "2026-07-01T09:00:00Z")
      ],
      "issue-backlog" => [
        comment("skip-2", "## Design\n\n不应出现", created_at: "2026-07-01T09:00:00Z")
      ]
    })
  end

  defp read_events(analytics_path) do
    analytics_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp comment(id, body, opts) do
    %{
      id: id,
      body: body,
      created_at: Keyword.fetch!(opts, :created_at),
      parent_id: Keyword.get(opts, :parent_id),
      author_name: Keyword.get(opts, :author_name),
      author_is_bot: Keyword.get(opts, :author_is_bot, false),
      resolved_at: Keyword.get(opts, :resolved_at)
    }
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "symphony-backfill-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
