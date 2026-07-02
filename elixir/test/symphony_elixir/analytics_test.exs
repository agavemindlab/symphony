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
        tokens: %{input_tokens: 10, output_tokens: 4, total_tokens: 14},
        recorded_at: "2026-06-15T10:00:05Z"
      },
      %{
        event_type: :phase_event,
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        phase: "Implementation",
        transition: "posted_artifact",
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

    assert %{status: "gap", metrics: cost_metrics} =
             panel(summary, "cost_per_accepted_issue")

    assert %{label: "Runtime seconds", value: 42, status: "partial"} in cost_metrics
    assert %{label: "Total tokens", value: 14, status: "partial"} in cost_metrics

    assert %{status: "partial", metrics: autonomy_metrics} =
             panel(summary, "autonomy_funnel")

    assert %{label: "Linear phase handoffs", value: "Linear phase handoff proof required", status: "gap"} in autonomy_metrics
    refute Enum.any?(autonomy_metrics, &(&1.label == "Phase events"))

    assert %{status: "gap", metrics: quality_metrics} =
             panel(summary, "quality_rework")

    assert %{label: "PR review quality", value: "GitHub review/CI data gap", status: "gap"} in quality_metrics

    assert %{status: "gap", metrics: capacity_metrics} =
             panel(summary, "capacity_reliability")

    assert %{label: "Retry events", value: 1, status: "partial"} in capacity_metrics
    assert %{label: "Blocked events", value: 1, status: "partial"} in capacity_metrics
    assert %{label: "Effective capacity", value: 12, status: "partial"} in capacity_metrics

    assert "GitHub review/CI data is not configured in v1" in summary.data_quality.gaps
  end

  test "summarizes latest token totals per run without double-counting snapshots" do
    path = tmp_path("token-snapshots.ndjson")

    [
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
        recorded_at: "2026-06-15T10:00:05Z"
      },
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 6, output_tokens: 3, total_tokens: 9},
        recorded_at: "2026-06-15T10:00:10Z"
      },
      %{
        event_type: :run_completed,
        issue_id: "issue-1",
        run_id: "run-1",
        runtime_seconds: 21,
        tokens: %{input_tokens: 6, output_tokens: 3, total_tokens: 9},
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
  end

  test "uses the latest outcome proof snapshot outside the default runtime read window" do
    path = tmp_path("outcome-proof-window.ndjson")

    write_event!(path, proof_snapshot())

    1..501
    |> Enum.each(fn index ->
      write_event!(path, %{
        event_type: "run_started",
        issue_id: "noise-#{index}",
        recorded_at: "2026-06-30T12:00:00Z"
      })
    end)

    summary = Analytics.summary(path: path)

    assert summary.event_sample_count == 500
    assert summary.outcome_proof.accepted_issue_count == 2
    assert Enum.map(summary.outcome_proof.cohorts, & &1.week) == ["2026-W25", "2026-W26"]

    assert %{status: "direct", metrics: autonomy_metrics} = panel(summary, "autonomy_funnel")

    assert %{
             label: "Linear phase handoffs",
             value: 3,
             status: "direct",
             source: "linear",
             numerator: 3,
             denominator: 2
           } in autonomy_metrics

    assert %{label: "Auto-advance rate", value: "1 / 3", status: "direct", source: "linear", numerator: 1, denominator: 3} in autonomy_metrics
    assert %{label: "Human touch count", value: 1, status: "direct", source: "linear", numerator: 1, denominator: 2} in autonomy_metrics

    assert %{status: "direct", metrics: quality_metrics} = panel(summary, "quality_rework")
    assert %{label: "PR review quality", value: 2, status: "direct", source: "github", numerator: 2, denominator: 2} in quality_metrics
    assert %{label: "GitHub CI pass rate", value: "1 / 2", status: "partial", source: "github", numerator: 1, denominator: 2} in quality_metrics

    refute "Linear phase metrics require collector availability" in summary.data_quality.gaps
    refute "GitHub review/CI data is not configured in v1" in summary.data_quality.gaps
  end

  test "fails closed when the outcome proof snapshot is outside the proof read window" do
    path = tmp_path("outcome-proof-outside-window.ndjson")

    write_event!(path, proof_snapshot())

    1..5_001
    |> Enum.each(fn index ->
      write_event!(path, %{
        event_type: "run_started",
        issue_id: "noise-#{index}",
        recorded_at: "2026-06-30T12:00:00Z"
      })
    end)

    summary = Analytics.summary(path: path)

    assert summary.outcome_proof.status == "gap"
    assert "proof_snapshot_outside_read_window" in summary.data_quality.gaps
    assert %{status: "partial", metrics: autonomy_metrics} = panel(summary, "autonomy_funnel")
    assert %{label: "Auto-advance rate", value: "Linear phase comments required", status: "gap"} in autonomy_metrics
  end

  test "normalizes partial and malformed outcome proof snapshots safely" do
    partial_path = tmp_path("outcome-proof-partial.ndjson")

    write_event!(partial_path, %{
      event_type: "outcome_proof_snapshot",
      collected_at: "2026-07-01T00:00:00Z",
      accepted_issue_count: 1.8,
      cohorts: nil,
      baseline: nil,
      latest: %{week: "2026-W26", nested: %{status: "direct"}},
      trend: %{status: "partial", reason: "single_complete_accepted_issue_cohort"},
      metrics: nil,
      data_quality: %{direct: ["linear"], partial: [], gaps: ["capacity source required"], nested: %{status: "direct"}}
    })

    partial_summary = Analytics.summary(path: partial_path)

    assert partial_summary.outcome_proof.status == "partial"
    assert partial_summary.outcome_proof.accepted_issue_count == 1
    assert partial_summary.outcome_proof.cohorts == []
    assert partial_summary.outcome_proof.baseline == nil
    assert partial_summary.outcome_proof.latest["nested"][:status] == "direct"
    assert "capacity source required" in partial_summary.data_quality.gaps

    gap_path = tmp_path("outcome-proof-gap.ndjson")
    write_event!(gap_path, %{event_type: "outcome_proof_snapshot", trend: %{status: "gap"}})

    assert Analytics.summary(path: gap_path).outcome_proof.status == "gap"
  end

  test "cost and capacity panel statuses fail closed from proof metric gaps" do
    path = tmp_path("outcome-proof-runtime-gaps.ndjson")

    snapshot =
      proof_snapshot()
      |> Map.update!(:metrics, fn metrics ->
        metrics ++
          [
            %{
              id: "tokens_per_accepted_issue",
              label: "Tokens per accepted issue",
              value: "runtime cost snapshot required",
              status: "gap",
              source: "runtime",
              numerator: 0,
              denominator: 2
            },
            %{
              id: "capacity_trend",
              label: "Capacity trend",
              value: "capacity source required",
              status: "gap",
              source: "runtime",
              numerator: nil,
              denominator: nil
            },
            %{
              id: "retry_denominator",
              label: "Retry denominator",
              value: "runtime retry source required",
              status: "gap",
              source: "runtime",
              numerator: nil,
              denominator: 2
            },
            %{
              id: "blocked_denominator",
              label: "Blocked denominator",
              value: "runtime blocked source required",
              status: "gap",
              source: "runtime",
              numerator: nil,
              denominator: 2
            }
          ]
      end)
      |> put_in([:data_quality, :gaps], [
        "runtime cost snapshot required",
        "capacity source required",
        "runtime retry source required",
        "runtime blocked source required"
      ])

    write_event!(path, snapshot)

    summary = Analytics.summary(path: path)

    assert %{status: "gap", metrics: cost_metrics} = panel(summary, "cost_per_accepted_issue")

    assert %{
             label: "Tokens per accepted issue",
             value: "runtime cost snapshot required",
             status: "gap",
             source: "runtime",
             numerator: 0,
             denominator: 2
           } in cost_metrics

    assert %{status: "gap", metrics: capacity_metrics} = panel(summary, "capacity_reliability")

    assert %{
             label: "Capacity trend",
             value: "capacity source required",
             status: "gap",
             source: "runtime",
             numerator: nil,
             denominator: nil
           } in capacity_metrics

    assert %{
             label: "Retry denominator",
             value: "runtime retry source required",
             status: "gap",
             source: "runtime",
             numerator: nil,
             denominator: 2
           } in capacity_metrics

    assert %{
             label: "Blocked denominator",
             value: "runtime blocked source required",
             status: "gap",
             source: "runtime",
             numerator: nil,
             denominator: 2
           } in capacity_metrics

    assert "runtime cost snapshot required" in summary.data_quality.gaps
  end

  test "cost and capacity panel statuses derive partial direct and fallback states from proof metrics" do
    direct_path = tmp_path("outcome-proof-runtime-direct.ndjson")

    direct_snapshot =
      proof_snapshot()
      |> Map.update!(:metrics, fn metrics ->
        metrics ++
          [
            %{
              id: "tokens_per_accepted_issue",
              label: "Tokens per accepted issue",
              value: 15,
              status: "direct",
              source: "runtime",
              numerator: 30,
              denominator: 2
            },
            %{
              id: "capacity_trend",
              label: "Capacity trend",
              value: "+2",
              status: "direct",
              source: "runtime",
              numerator: 6,
              denominator: 4
            },
            %{
              id: "retry_denominator",
              label: "Retry denominator",
              value: "1 / 2",
              status: "direct",
              source: "runtime",
              numerator: 1,
              denominator: 2
            },
            %{
              id: "blocked_denominator",
              label: "Blocked denominator",
              value: "1 / 2",
              status: "direct",
              source: "runtime",
              numerator: 1,
              denominator: 2
            }
          ]
      end)

    write_event!(direct_path, direct_snapshot)
    direct_summary = Analytics.summary(path: direct_path)

    assert %{status: "direct"} = panel(direct_summary, "cost_per_accepted_issue")
    assert %{status: "direct"} = panel(direct_summary, "capacity_reliability")

    partial_path = tmp_path("outcome-proof-runtime-partial.ndjson")

    partial_snapshot =
      direct_snapshot
      |> update_in([:metrics], fn metrics ->
        Enum.map(metrics, fn
          %{id: "tokens_per_accepted_issue"} = metric ->
            metric
            |> Map.put(:status, "partial")
            |> Map.put(:reason, "runtime cost snapshot missing for accepted issues")

          %{id: "retry_denominator"} = metric ->
            metric
            |> Map.put(:status, "partial")
            |> Map.put(:reason, "runtime retry source missing for accepted issues")

          metric ->
            metric
        end)
      end)

    write_event!(partial_path, partial_snapshot)
    partial_summary = Analytics.summary(path: partial_path)

    assert %{status: "partial"} = panel(partial_summary, "cost_per_accepted_issue")
    assert %{status: "partial"} = panel(partial_summary, "capacity_reliability")

    fallback_path = tmp_path("outcome-proof-runtime-fallback.ndjson")

    fallback_snapshot =
      proof_snapshot()
      |> Map.update!(:metrics, fn metrics ->
        metrics ++
          [
            %{
              id: "tokens_per_accepted_issue",
              label: "Tokens per accepted issue",
              value: "unknown",
              status: "unknown",
              source: "runtime"
            }
          ]
      end)

    write_event!(fallback_path, fallback_snapshot)
    assert %{status: "gap"} = fallback_path |> then(&Analytics.summary(path: &1)) |> panel("cost_per_accepted_issue")
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

  defp write_event!(path, event) do
    File.write!(path, Jason.encode!(event) <> "\n", [:append])
  end

  defp proof_snapshot do
    %{
      event_type: "outcome_proof_snapshot",
      collected_at: "2026-07-01T00:00:00Z",
      accepted_issue_count: 2,
      proof_window: %{accepted_weeks: 9, issue_cap: 200, proof_read_events: 5_000},
      cohorts: [
        %{week: "2026-W25", project: "symphony", sample_count: 1, complete_week?: true, truncated?: false},
        %{week: "2026-W26", project: "symphony", sample_count: 1, complete_week?: true, truncated?: false}
      ],
      baseline: %{week: "2026-W25", sample_count: 1},
      latest: %{week: "2026-W26", sample_count: 1},
      trend: %{status: "direct"},
      metrics: [
        %{
          id: "linear_phase_handoff_count",
          label: "Linear phase handoffs",
          value: 3,
          status: "direct",
          source: "linear",
          numerator: 3,
          denominator: 2
        },
        %{
          id: "auto_advance_rate",
          label: "Auto-advance rate",
          value: "1 / 3",
          status: "direct",
          source: "linear",
          numerator: 1,
          denominator: 3
        },
        %{
          id: "human_touch_count",
          label: "Human touch count",
          value: 1,
          status: "direct",
          source: "linear",
          numerator: 1,
          denominator: 2
        },
        %{
          id: "rework_rate",
          label: "Rework rate",
          value: "1 / 2",
          status: "direct",
          source: "linear",
          numerator: 1,
          denominator: 2
        },
        %{
          id: "pr_human_review_count",
          label: "PR review quality",
          value: 2,
          status: "direct",
          source: "github",
          numerator: 2,
          denominator: 2
        },
        %{
          id: "ci_success_rate",
          label: "GitHub CI pass rate",
          value: "1 / 2",
          status: "partial",
          source: "github",
          numerator: 1,
          denominator: 2
        }
      ],
      data_quality: %{direct: ["linear", "github"], partial: ["ci"], gaps: [], warnings: []}
    }
  end
end
