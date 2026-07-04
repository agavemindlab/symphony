defmodule SymphonyElixir.AnalyticsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Analytics

  test "records runtime events as newline-delimited JSON and skips malformed rows" do
    path = tmp_path("events.ndjson")
    recorded_at = ~U[2026-06-15 10:00:00Z]

    assert :ok =
             Analytics.record_event(
               %{
                 event_type: :run_started,
                 issue_id: "issue-1",
                 issue_identifier: "DEV-1",
                 issue_url: "https://linear.app/DEV-1",
                 run_id: "issue-1-20260615T100000Z",
                 attempt: 0,
                 tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
               },
               path: path,
               recorded_at: recorded_at
             )

    File.write!(path, "not-json\n", [:append])

    assert %{
             events: [
               %{
                 "event_type" => "run_started",
                 "issue_id" => "issue-1",
                 "issue_identifier" => "DEV-1",
                 "recorded_at" => "2026-06-15T10:00:00Z",
                 "tokens" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
               }
             ],
             warnings: ["skipped malformed analytics event line 2"],
             truncated?: false
           } = Analytics.read_events(path: path)
  end

  test "summarizes runtime events into the six v1 dashboard panels" do
    path = tmp_path("summary.ndjson")

    [
      %{
        event_type: :run_started,
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        run_id: "run-1",
        recorded_at: "2026-06-15T10:00:00Z"
      },
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        tokens: %{input_tokens: 10, output_tokens: 4, total_tokens: 14, cached_input_tokens: 4, reasoning_output_tokens: 2},
        recorded_at: "2026-06-15T10:00:05Z"
      },
      %{
        event_type: :phase_published,
        event_id: "phase_published:comment-1",
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        phase: "Implementation",
        comment_id: "comment-1",
        source: "phase_scan",
        recorded_at: "2026-06-15T10:00:06Z"
      },
      %{
        event_type: :retry_scheduled,
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        attempt: 2,
        reason: "agent exited",
        recorded_at: "2026-06-15T10:00:10Z"
      },
      %{
        event_type: :blocked,
        issue_id: "issue-2",
        issue_identifier: "DEV-2",
        reason: "codex turn requires operator input",
        recorded_at: "2026-06-15T10:00:11Z"
      },
      %{
        event_type: :run_completed,
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        runtime_seconds: 42,
        recorded_at: "2026-06-15T10:00:42Z"
      },
      %{
        event_type: :capacity_snapshot,
        running_count: 1,
        retrying_count: 1,
        blocked_count: 1,
        configured_capacity: 10,
        effective_capacity: 12,
        recorded_at: "2026-06-15T10:00:43Z"
      }
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    summary = Analytics.summary(path: path)

    assert summary.event_sample_count == 7

    assert Enum.map(summary.panels, & &1.id) == [
             "delivery_cycle",
             "autonomy_funnel",
             "quality_rework",
             "cost_per_accepted_issue",
             "capacity_reliability",
             "data_quality_exclusions"
           ]

    assert Enum.all?(summary.panels, &(is_binary(&1.question) and &1.question != ""))

    assert Enum.all?(summary.panels, fn panel ->
             Enum.all?(panel.metrics, &(&1.status in ["direct", "partial", "gap"]))
           end)

    assert %{question: "Can accepted issues move faster with the current persisted signals?"} =
             panel(summary, "delivery_cycle")

    assert %{status: "direct", metrics: cost_metrics} =
             panel(summary, "cost_per_accepted_issue")

    assert %{label: "Runtime seconds", value: 42, status: "partial"} in cost_metrics
    assert %{label: "Total tokens", value: 14, status: "partial"} in cost_metrics
    assert %{label: "Cached input tokens", value: 4, status: "partial"} in cost_metrics
    assert %{label: "Cache hit share", value: "40.0%", status: "partial"} in cost_metrics

    assert %{status: "partial", metrics: autonomy_metrics} =
             panel(summary, "autonomy_funnel")

    assert %{label: "Phases published", value: 1, status: "direct"} in autonomy_metrics
    assert %{label: "Human approvals", value: 0, status: "direct"} in autonomy_metrics
    assert %{label: "Auto-advances", value: 0, status: "direct"} in autonomy_metrics
    assert %{label: "Auto-advance rate", value: "n/a", status: "direct"} in autonomy_metrics
    assert %{label: "Rework rounds", value: 0, status: "direct"} in autonomy_metrics
    assert %{label: "Human touch count", value: "Linear comments required", status: "gap"} in autonomy_metrics

    assert %{status: "gap", metrics: quality_metrics} =
             panel(summary, "quality_rework")

    assert %{label: "Rework rate", value: "0.0%", status: "partial"} in quality_metrics
    assert %{label: "PR review quality", value: "GitHub review/CI data gap", status: "gap"} in quality_metrics

    assert %{status: "direct", metrics: capacity_metrics} =
             panel(summary, "capacity_reliability")

    assert %{label: "Retry events", value: 1, status: "partial"} in capacity_metrics
    assert %{label: "Blocked events", value: 1, status: "partial"} in capacity_metrics
    assert %{label: "Effective capacity", value: 12, status: "partial"} in capacity_metrics

    assert "GitHub review/CI data is not configured in v1" in summary.data_quality.gaps
  end

  test "counts phase events once per event_id and computes autonomy funnel rates" do
    path = tmp_path("phase-funnel.ndjson")

    duplicated_published = %{
      event_type: :phase_published,
      event_id: "phase_published:pub-1",
      issue_id: "issue-1",
      phase: "Requirements",
      comment_id: "pub-1",
      source: "phase_scan",
      recorded_at: "2026-06-15T10:00:00Z"
    }

    [
      duplicated_published,
      duplicated_published,
      %{
        event_type: :phase_published,
        event_id: "phase_published:pub-2",
        issue_id: "issue-1",
        phase: "Design",
        comment_id: "pub-2",
        source: "phase_scan",
        recorded_at: "2026-06-15T10:05:00Z"
      },
      %{
        event_type: :phase_approved,
        event_id: "phase_approved:appr-1",
        issue_id: "issue-1",
        phase: "Requirements",
        comment_id: "appr-1",
        source: "phase_scan",
        recorded_at: "2026-06-15T10:10:00Z"
      },
      %{
        event_type: :phase_auto_advanced,
        event_id: "phase_auto_advanced:adv-1",
        issue_id: "issue-1",
        phase: "Design",
        comment_id: "adv-1",
        source: "phase_scan",
        recorded_at: "2026-06-15T10:15:00Z"
      },
      %{
        event_type: :phase_reworked,
        event_id: "phase_reworked:rw-1",
        issue_id: "issue-1",
        phase: "Design",
        comment_id: "rw-1",
        source: "phase_scan",
        recorded_at: "2026-06-15T10:20:00Z"
      },
      %{
        event_type: :phase_rollback,
        event_id: "phase_rollback:rb-1",
        issue_id: "issue-1",
        from_phase: "Design",
        target_phase: "Requirements",
        comment_id: "rb-1",
        source: "phase_scan",
        recorded_at: "2026-06-15T10:25:00Z"
      },
      %{event_type: :run_started, issue_id: "issue-1", recorded_at: "2026-06-15T10:30:00Z"},
      %{event_type: :run_started, issue_id: "issue-1", recorded_at: "2026-06-15T10:30:00Z"}
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    summary = Analytics.summary(path: path)

    %{metrics: autonomy_metrics} = panel(summary, "autonomy_funnel")

    assert %{label: "Phases published", value: 2, status: "direct"} in autonomy_metrics
    assert %{label: "Human approvals", value: 1, status: "direct"} in autonomy_metrics
    assert %{label: "Auto-advances", value: 1, status: "direct"} in autonomy_metrics
    assert %{label: "Auto-advance rate", value: "50.0%", status: "direct"} in autonomy_metrics
    assert %{label: "Rework rounds", value: 2, status: "direct"} in autonomy_metrics

    %{metrics: quality_metrics} = panel(summary, "quality_rework")
    assert %{label: "Rework rate", value: "100.0%", status: "partial"} in quality_metrics

    # Events without an event_id are not deduplicated.
    %{metrics: delivery_metrics} = panel(summary, "delivery_cycle")
    assert %{label: "Runtime-backed runs", value: 2, status: "partial"} in delivery_metrics
  end

  test "summarizes latest token totals per run without double-counting snapshots" do
    path = tmp_path("token-snapshots.ndjson")

    [
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 3, output_tokens: 2, total_tokens: 5, cached_input_tokens: 2},
        recorded_at: "2026-06-15T10:00:05Z"
      },
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 6, output_tokens: 3, total_tokens: 9, cached_input_tokens: 4},
        recorded_at: "2026-06-15T10:00:10Z"
      },
      %{
        event_type: :run_completed,
        issue_id: "issue-1",
        run_id: "run-1",
        runtime_seconds: 21,
        tokens: %{input_tokens: 6, output_tokens: 3, total_tokens: 9, cached_input_tokens: 4},
        recorded_at: "2026-06-15T10:00:21Z"
      }
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    %{metrics: cost_metrics} =
      [path: path]
      |> Analytics.summary()
      |> panel("cost_per_accepted_issue")

    assert %{label: "Total tokens", value: 9, status: "partial"} in cost_metrics
    assert %{label: "Input tokens", value: 6, status: "partial"} in cost_metrics
    assert %{label: "Output tokens", value: 3, status: "partial"} in cost_metrics
    assert %{label: "Cached input tokens", value: 4, status: "partial"} in cost_metrics
    assert %{label: "Cache hit share", value: "66.7%", status: "partial"} in cost_metrics
  end

  test "handles best-effort write and timestamp edge cases" do
    path = tmp_path("edge-events.ndjson")
    previous_analytics_file = Application.get_env(:symphony_elixir, :analytics_file)

    on_exit(fn ->
      if is_nil(previous_analytics_file) do
        Application.delete_env(:symphony_elixir, :analytics_file)
      else
        Application.put_env(:symphony_elixir, :analytics_file, previous_analytics_file)
      end
    end)

    Application.put_env(:symphony_elixir, :analytics_file, path)

    assert capture_log(fn ->
             assert :ok = Analytics.record_event(%{event_type: :bad_event, value: self()}, path: path)
           end) =~ "Skipping analytics event"

    assert :ok =
             Analytics.record_event(
               %{"event_type" => "run_started", "issue_id" => "issue-string"},
               path: path,
               recorded_at: "2026-06-15T11:00:00Z"
             )

    assert :ok =
             Analytics.record_event(
               %{event_type: :run_started, issue_id: "issue-invalid-lock-timeout"},
               path: path,
               lock_timeout_ms: :invalid
             )

    assert :ok = Analytics.record_event(%{event_type: :run_completed, runtime_seconds: 2.8}, recorded_at: :bad)

    assert %{events: events} = Analytics.read_events()
    assert Enum.any?(events, &(&1["event_type"] == "run_started" and &1["recorded_at"] == "2026-06-15T11:00:00Z"))
    assert Enum.any?(events, &(&1["event_type"] == "run_completed" and is_binary(&1["recorded_at"])))

    assert capture_log(fn ->
             assert :ok = Analytics.record_event(%{event_type: :run_started}, path: Path.dirname(path))
           end) =~ "Failed to write analytics event"

    not_a_directory = tmp_path("not-a-directory")
    File.write!(not_a_directory, "not a directory")

    assert capture_log(fn ->
             assert :ok =
                      Analytics.record_event(
                        %{event_type: :run_started},
                        path: Path.join(not_a_directory, "events.ndjson")
                      )
           end) =~ "Failed to create analytics directory"
  end

  test "reads truncated windows and reports unreadable files" do
    path = tmp_path("window-events.ndjson")

    [
      %{event_type: :run_started, issue_id: "issue-1", recorded_at: "2026-06-15T11:00:00Z"},
      %{event_type: :cost_snapshot, issue_id: "issue-1", tokens: %{total_tokens: 1.8}, recorded_at: "2026-06-15T11:00:01Z"},
      %{event_type: :run_completed, issue_id: "issue-1", runtime_seconds: 4.2, recorded_at: "2026-06-15T11:00:02Z"}
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    assert %{events: [_latest], truncated?: true} = Analytics.read_events(path: path, max_events: 1)
    assert %{events: all_events, truncated?: false} = Analytics.read_events(path: path, max_events: :all)
    assert length(all_events) == 3

    assert %{metrics: cost_metrics} =
             [path: path]
             |> Analytics.summary()
             |> panel("cost_per_accepted_issue")

    assert %{label: "Runtime seconds", value: 4, status: "partial"} in cost_metrics
    assert %{label: "Total tokens", value: 1, status: "partial"} in cost_metrics
    assert %{label: "Cached input tokens", value: 0, status: "partial"} in cost_metrics
    assert %{label: "Cache hit share", value: "n/a", status: "partial"} in cost_metrics

    unreadable_path = tmp_path("unreadable.ndjson")
    File.write!(unreadable_path, "{}\n")
    File.chmod!(unreadable_path, 0)

    try do
      result = Analytics.read_events(path: unreadable_path)

      assert result.events == []
      assert Enum.any?(result.warnings, &String.contains?(&1, "analytics event file unavailable"))
    after
      File.chmod!(unreadable_path, 0o600)
    end
  end

  test "keeps analytics event files append-only and bounds reads" do
    path = tmp_path("retained-events.ndjson")

    1..505
    |> Enum.each(fn index ->
      Analytics.record_event(
        %{event_type: :run_started, issue_id: "issue-#{index}"},
        path: path,
        recorded_at: "2026-06-15T12:00:00Z"
      )
    end)

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 505

    assert %{
             events: [%{"issue_id" => "issue-6"} | _] = events,
             truncated?: true
           } = Analytics.read_events(path: path)

    assert List.last(events)["issue_id"] == "issue-505"

    assert %{
             events: [%{"issue_id" => "issue-1"} | all_events],
             truncated?: false
           } = Analytics.read_events(path: path, max_events: :all)

    assert length(all_events) == 504

    assert "Analytics event file was truncated to the latest window" in Analytics.summary(path: path).data_quality.gaps
  end

  test "bounded reads do not scan old bytes outside the latest window" do
    path = tmp_path("large-events.ndjson")
    latest = Jason.encode!(%{event_type: :run_started, issue_id: "latest"})

    File.write!(path, <<255>> <> String.duplicate("x", 70_000) <> "\n" <> latest <> "\n")

    assert %{
             events: [%{"event_type" => "run_started", "issue_id" => "latest"}],
             warnings: [],
             truncated?: true
           } = Analytics.read_events(path: path, max_events: 1)
  end

  test "serializes analytics writes with a filesystem lock" do
    path = tmp_path("locked-events.ndjson")
    lock_path = path <> ".lock"
    File.mkdir!(lock_path)

    task =
      Task.async(fn ->
        Analytics.record_event(
          %{event_type: :run_started, issue_id: "issue-locked"},
          path: path,
          lock_timeout_ms: 1_000
        )
      end)

    Process.sleep(50)
    refute File.exists?(path)

    File.rmdir!(lock_path)
    assert :ok = Task.await(task, 1_000)

    assert %{
             events: [%{"event_type" => "run_started", "issue_id" => "issue-locked"}],
             warnings: [],
             truncated?: false
           } = Analytics.read_events(path: path)
  end

  test "skips analytics events when the filesystem lock times out" do
    path = tmp_path("locked-timeout-events.ndjson")
    lock_path = path <> ".lock"
    File.mkdir!(lock_path)

    try do
      assert capture_log(fn ->
               assert :ok =
                        Analytics.record_event(
                          %{event_type: :run_started, issue_id: "issue-timeout"},
                          path: path,
                          lock_timeout_ms: 0
                        )
             end) =~ "Failed to acquire analytics event file lock: timed out"

      refute File.exists?(path)
    after
      File.rmdir!(lock_path)
    end
  end

  defp panel(summary, id) do
    Enum.find(summary.panels, &(&1.id == id))
  end

  defp tmp_path(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-analytics-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, name)
  end
end
