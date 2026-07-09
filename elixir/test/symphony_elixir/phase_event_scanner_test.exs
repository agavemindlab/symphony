defmodule SymphonyElixir.PhaseEventScannerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Analytics
  alias SymphonyElixir.PhaseEventScanner

  defmodule FailingLinearClient do
    def fetch_issue_comments(_issue_id), do: {:error, :comment_fetch_failed}
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

  test "scan records derived phase and human comment events with issue fields and dedupes across rescans" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "issue-scan-1",
      identifier: "DEV-101",
      title: "Scan me",
      state: "In Progress",
      url: "https://linear.app/DEV-101"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-scan-1" => [
        comment("req-1", "## Requirements\n\n### 目标\n交付分析事件解析。", created_at: "2026-07-01T10:00:00Z", author_name: "symphony-agent", author_is_bot: true),
        comment("req-1-advance", "⏩ 自动进入 Design（agent 自评通过，未经人工评审）", parent_id: "req-1", created_at: "2026-07-01T10:05:00Z", author_name: "symphony-agent", author_is_bot: true),
        comment("design-1", "## Design\n\n模块拆分。", created_at: "2026-07-01T10:10:00Z", author_name: "symphony-agent", author_is_bot: true),
        comment("design-1-approve", "✅ 已批准，进入 Implementation", parent_id: "design-1", created_at: "2026-07-01T11:00:00Z", author_name: "Alice"),
        comment("chatter", "人类普通评论，也计入 human touch。", created_at: "not-a-timestamp", author_name: "Bob")
      ]
    })

    server = start_scanner!(:ScanRecordsEvents)

    # Async cast path, followed by a synchronous rescan that acts as a barrier
    # and proves already-emitted events are not written twice.
    assert :ok = PhaseEventScanner.scan(issue, server)
    assert :ok = PhaseEventScanner.scan_now(issue, server)

    assert [human_chatter, published_requirements, auto_advanced, published_design, approved, human_approve] =
             recorded_phase_events()

    assert %{
             "event_type" => "phase_published",
             "event_id" => "phase_published:req-1",
             "phase" => "Requirements",
             "comment_id" => "req-1",
             "occurred_at" => "2026-07-01T10:00:00Z",
             "needs_clarification" => false,
             "author_name" => "symphony-agent",
             "issue_id" => "issue-scan-1",
             "issue_identifier" => "DEV-101",
             "issue_url" => "https://linear.app/DEV-101",
             "source" => "phase_scan"
           } = published_requirements

    assert is_binary(published_requirements["recorded_at"])

    assert %{
             "event_type" => "phase_auto_advanced",
             "event_id" => "phase_auto_advanced:req-1-advance",
             "phase" => "Requirements",
             "artifact_comment_id" => "req-1",
             "issue_identifier" => "DEV-101",
             "source" => "phase_scan"
           } = auto_advanced

    assert %{"event_type" => "phase_published", "event_id" => "phase_published:design-1"} = published_design

    assert %{
             "event_type" => "phase_approved",
             "event_id" => "phase_approved:design-1-approve",
             "phase" => "Design",
             "author_name" => "Alice",
             "issue_id" => "issue-scan-1",
             "source" => "phase_scan"
           } = approved

    # Every non-bot comment yields a human_comment event, including plain
    # chatter outside artifact threads and marker replies inside them.
    assert %{
             "event_type" => "human_comment",
             "event_id" => "human-comment-chatter",
             "occurred_at" => "not-a-timestamp",
             "author_name" => "Bob",
             "issue_id" => "issue-scan-1",
             "source" => "phase_scan"
           } = human_chatter

    assert %{
             "event_type" => "human_comment",
             "event_id" => "human-comment-design-1-approve",
             "occurred_at" => "2026-07-01T11:00:00Z",
             "author_name" => "Alice"
           } = human_approve
  end

  test "a comment appearing between scans emits only the new event" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{id: "issue-scan-2", identifier: "DEV-102", state: "In Progress", url: "https://linear.app/DEV-102"}

    artifact =
      comment("impl-1", "## Implementation\n\nPR: https://github.com/x/y/pull/1", created_at: "2026-07-01T12:00:00Z", author_is_bot: true)

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-scan-2" => [artifact]})

    server = start_scanner!(:ScanNewComments)
    assert :ok = PhaseEventScanner.scan_now(issue, server)

    assert ["phase_published:impl-1"] = recorded_phase_events() |> Enum.map(& &1["event_id"])

    maestro_reply =
      comment(
        "impl-1-maestro",
        "🤖 Maestro 预审核: 本轮交付可以接受。\n\n建议回复方式: approve\n置信度 8/10",
        parent_id: "impl-1",
        created_at: "2026-07-01T13:00:00Z",
        author_is_bot: true
      )

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-scan-2" => [artifact, maestro_reply]})

    assert :ok = PhaseEventScanner.scan_now(issue, server)

    assert ["phase_published:impl-1", "maestro_review:impl-1-maestro"] =
             recorded_phase_events() |> Enum.map(& &1["event_id"])

    assert [%{"event_type" => "maestro_review", "recommendation" => "approve", "confidence" => 8.0}] =
             Enum.filter(recorded_phase_events(), &(&1["event_type"] == "maestro_review"))
  end

  test "fetch errors are logged and do not crash or record events" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    Application.put_env(:symphony_elixir, :linear_client_module, FailingLinearClient)

    issue = %Issue{id: "issue-scan-error", identifier: "DEV-103", state: "In Progress"}
    server = start_scanner!(:ScanFetchError)

    log =
      capture_log(fn ->
        assert :ok = PhaseEventScanner.scan_now(issue, server)
      end)

    assert log =~ "phase event scan failed"
    assert log =~ "DEV-103"
    assert Process.alive?(GenServer.whereis(server))
    assert recorded_phase_events() == []
  end

  test "scan survives exceptions raised while resolving the tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    issue = %Issue{id: "issue-scan-raise", identifier: "DEV-104", state: "In Progress"}
    server = start_scanner!(:ScanRaise)

    log =
      capture_log(fn ->
        assert :ok = PhaseEventScanner.scan_now(issue, server)
      end)

    assert log =~ "phase event scan failed"
    assert log =~ "DEV-104"
    assert Process.alive?(GenServer.whereis(server))
    assert recorded_phase_events() == []
  end

  test "scans without comments or without an issue id emit nothing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    server = start_scanner!(:ScanNoComments)

    assert :ok = PhaseEventScanner.scan_now(%Issue{id: "issue-scan-empty", identifier: "DEV-105"}, server)
    assert :ok = PhaseEventScanner.scan_now(%{}, server)
    assert :ok = PhaseEventScanner.scan_now(nil, server)

    # The supervised singleton handles the default-server API the same way.
    assert :ok = PhaseEventScanner.scan_now(%Issue{id: "issue-scan-empty-global", identifier: "DEV-105G"})

    assert recorded_phase_events() == []
  end

  test "scan is a silent no-op when the scanner is not running" do
    assert :ok = PhaseEventScanner.scan(%Issue{id: "issue-scan-down"}, Module.concat(__MODULE__, :NotRunning))
  end

  test "start_link registers the module name by default" do
    assert {:error, {:already_started, pid}} = PhaseEventScanner.start_link()
    assert pid == GenServer.whereis(PhaseEventScanner)
  end

  defp start_scanner!(name_suffix) do
    name = Module.concat(__MODULE__, name_suffix)
    {:ok, pid} = PhaseEventScanner.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    name
  end

  defp recorded_phase_events do
    %{events: events} = Analytics.read_events()
    Enum.filter(events, &(&1["source"] == "phase_scan"))
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
end
