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

  test "summarizes runtime events into the five v1 dashboard panels" do
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
    assert summary.window_started_at == "2026-06-15T10:00:00Z"
    assert summary.window_ended_at == "2026-06-15T10:00:43Z"

    assert Enum.map(summary.panels, & &1.id) == [
             "delivery_cycle",
             "autonomy_funnel",
             "quality_rework",
             "cost_per_accepted_issue",
             "capacity_reliability"
           ]

    assert Enum.all?(summary.panels, &(is_binary(&1.question) and &1.question != ""))

    assert Enum.all?(summary.panels, fn panel ->
             Enum.all?(panel.metrics, &(&1.status in ["direct", "partial", "gap"]))
           end)

    assert %{question: "Can accepted issues move faster with the current persisted signals?"} =
             panel(summary, "delivery_cycle")

    assert %{status: "partial", metrics: cost_metrics} =
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

    assert %{status: "partial", metrics: quality_metrics} =
             panel(summary, "quality_rework")

    assert %{label: "Rework rate", value: "0.0%", status: "partial"} in quality_metrics
    assert %{label: "Maestro reviews", value: 0, status: "direct"} in quality_metrics
    assert %{label: "Maestro agreement rate", value: "n/a", status: "direct"} in quality_metrics
    assert %{label: "Maestro overridden", value: 0, status: "direct"} in quality_metrics
    assert %{label: "PR review quality", value: "GitHub review/CI data gap", status: "gap"} in quality_metrics

    assert %{status: "direct", metrics: capacity_metrics} =
             panel(summary, "capacity_reliability")

    assert %{label: "Retry events", value: 1, status: "partial"} in capacity_metrics
    assert %{label: "Blocked events", value: 1, status: "partial"} in capacity_metrics
    assert %{label: "Hook failures", value: 0, status: "direct"} in capacity_metrics
    assert %{label: "Effective capacity", value: 12, status: "partial"} in capacity_metrics

    assert "GitHub review/CI data is not configured in v1" in summary.data_quality.gaps
  end

  test "window span is nil when the event window is empty" do
    summary = Analytics.summary(path: tmp_path("no-events.ndjson"))

    assert summary.event_sample_count == 0
    assert summary.window_started_at == nil
    assert summary.window_ended_at == nil
  end

  test "verdict join skips the reviewer instance's Human Review dispatches" do
    path = tmp_path("reviewer-dispatch.ndjson")

    [
      %{
        event_type: :maestro_review,
        event_id: "maestro_review:m1",
        recommendation: "request_changes",
        phase: "Implementation",
        issue_id: "issue-1",
        occurred_at: "2026-06-15T10:00:00Z",
        recorded_at: "2026-06-15T10:00:00Z"
      },
      %{
        event_type: :run_started,
        issue_id: "issue-1",
        state: "Human Review",
        recorded_at: "2026-06-15T10:01:00Z"
      },
      %{
        event_type: :run_started,
        issue_id: "issue-1",
        state: "Rework",
        recorded_at: "2026-06-15T10:30:00Z"
      }
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    %{metrics: quality_metrics} =
      [path: path]
      |> Analytics.summary()
      |> panel("quality_rework")

    assert %{label: "Maestro agreement rate", value: "100.0%", status: "direct"} in quality_metrics
  end

  test "counts hook failures and ignores legacy maestro_skipped events" do
    path = tmp_path("silent-failures.ndjson")

    [
      %{
        event_type: :maestro_skipped,
        reason: "missing_linear_auth",
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        issue_url: "https://linear.app/DEV-1",
        recorded_at: "2026-06-15T10:00:00Z"
      },
      %{
        event_type: :maestro_skipped,
        reason: "launch_error",
        issue_id: "issue-2",
        issue_identifier: "DEV-2",
        recorded_at: "2026-06-15T10:01:00Z"
      },
      %{
        event_type: :hook_failed,
        hook: "issue_stopped",
        issue_id: "issue-1",
        issue_identifier: "DEV-1",
        recorded_at: "2026-06-15T10:02:00Z"
      }
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    %{status: "direct", metrics: capacity_metrics} =
      [path: path]
      |> Analytics.summary()
      |> panel("capacity_reliability")

    assert %{label: "Hook failures", value: 1, status: "direct"} in capacity_metrics
    refute Enum.any?(capacity_metrics, &(&1.label == "Maestro skipped"))
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

  test "joins maestro reviews to the next run_started dispatch and scores agreement" do
    path = tmp_path("maestro-agreement.ndjson")

    rc_agree_review = %{
      event_type: :maestro_review,
      event_id: "maestro:rc-agree",
      issue_id: "issue-rc-agree",
      issue_identifier: "DEV-10",
      phase: "Implementation",
      recommendation: "request_changes",
      confidence: 0.9,
      auto: false,
      occurred_at: "2026-06-15T10:00:00Z",
      recorded_at: "2026-06-15T10:00:01Z"
    }

    [
      # Agreed request_changes: only the FIRST subsequent dispatch (Rework) counts,
      # not the later In Progress one; the duplicated review is deduplicated by event_id.
      rc_agree_review,
      rc_agree_review,
      %{event_type: :run_started, issue_id: "issue-rc-agree", state: "Rework", recorded_at: "2026-06-15T10:05:00Z"},
      %{event_type: :run_started, issue_id: "issue-rc-agree", state: "In Progress", recorded_at: "2026-06-15T10:20:00Z"},
      # Overridden request_changes: the human dispatched In Progress instead of Rework.
      %{
        event_type: :maestro_review,
        event_id: "maestro:rc-override",
        issue_id: "issue-rc-override",
        phase: "Design",
        recommendation: "request_changes",
        occurred_at: "2026-06-15T10:00:00Z",
        recorded_at: "2026-06-15T10:00:01Z"
      },
      %{event_type: :run_started, issue_id: "issue-rc-override", state: "In Progress", recorded_at: "2026-06-15T10:05:00Z"},
      # Agreed approve on Design. The occurred_at offset (12:00+02:00 == 10:00Z) sorts AFTER
      # the 10:05Z dispatch lexically, so only DateTime comparison joins them.
      %{
        event_type: :maestro_review,
        event_id: "maestro:design-agree",
        issue_id: "issue-design-agree",
        phase: "Design",
        recommendation: "approve",
        occurred_at: "2026-06-15T12:00:00+02:00",
        recorded_at: "2026-06-15T10:00:01Z"
      },
      %{event_type: :run_started, issue_id: "issue-design-agree", state: "In Progress", recorded_at: "2026-06-15T10:05:00Z"},
      # Agreed approve on Implementation followed by a Merging dispatch.
      %{
        event_type: :maestro_review,
        event_id: "maestro:impl-agree",
        issue_id: "issue-impl-agree",
        phase: "Implementation",
        recommendation: "approve",
        occurred_at: "2026-06-15T10:00:00Z",
        recorded_at: "2026-06-15T10:00:01Z"
      },
      %{event_type: :run_started, issue_id: "issue-impl-agree", state: "Merging", recorded_at: "2026-06-15T10:05:00Z"},
      # Pending: no subsequent run_started for the issue.
      %{
        event_type: :maestro_review,
        event_id: "maestro:pending",
        issue_id: "issue-pending",
        phase: "Requirements",
        recommendation: "request_changes",
        occurred_at: "2026-06-15T10:00:00Z",
        recorded_at: "2026-06-15T10:00:01Z"
      },
      # Excluded: ask_clarification never enters the agreement buckets, dispatch or not.
      %{
        event_type: :maestro_review,
        event_id: "maestro:clarify",
        issue_id: "issue-clarify",
        phase: "Requirements",
        recommendation: "ask_clarification",
        occurred_at: "2026-06-15T10:00:00Z",
        recorded_at: "2026-06-15T10:00:01Z"
      },
      %{event_type: :run_started, issue_id: "issue-clarify", state: "In Progress", recorded_at: "2026-06-15T10:05:00Z"},
      # Nil occurred_at falls back to the review's recorded_at (10:10), so the earlier
      # In Progress dispatch is skipped and the later Rework dispatch scores agreement.
      %{event_type: :run_started, issue_id: "issue-fallback", state: "In Progress", recorded_at: "2026-06-15T10:05:00Z"},
      %{
        event_type: :maestro_review,
        event_id: "maestro:fallback",
        issue_id: "issue-fallback",
        phase: "Implementation",
        recommendation: "request_changes",
        occurred_at: nil,
        recorded_at: "2026-06-15T10:10:00Z"
      },
      %{event_type: :run_started, issue_id: "issue-fallback", state: "Rework", recorded_at: "2026-06-15T10:15:00Z"},
      # Unparseable occurred_at: no verdict can be joined, so the review stays pending
      # even though a Rework dispatch follows.
      %{
        event_type: :maestro_review,
        event_id: "maestro:unparseable",
        issue_id: "issue-unparseable",
        phase: "Implementation",
        recommendation: "request_changes",
        occurred_at: "not-a-timestamp",
        recorded_at: "2026-06-15T10:00:01Z"
      },
      %{event_type: :run_started, issue_id: "issue-unparseable", state: "Rework", recorded_at: "2026-06-15T10:05:00Z"}
    ]
    |> Enum.each(&Analytics.record_event(&1, path: path))

    summary = Analytics.summary(path: path)

    assert %{status: "partial", metrics: quality_metrics} = panel(summary, "quality_rework")

    # 8 unique reviews; agreed = rc-agree + design-agree + impl-agree + fallback (4),
    # overridden = rc-override (1), pending = pending + unparseable (2), excluded = clarify.
    assert %{label: "Maestro reviews", value: 8, status: "direct"} in quality_metrics
    assert %{label: "Maestro agreement rate", value: "80.0%", status: "direct"} in quality_metrics
    assert %{label: "Maestro overridden", value: 1, status: "direct"} in quality_metrics
  end

  test "classifies maestro verdicts against the next dispatch state" do
    review = fn recommendation, phase -> %{"recommendation" => recommendation, "phase" => phase} end

    assert Analytics.maestro_verdict(review.("request_changes", nil), "Rework") == :agreed
    assert Analytics.maestro_verdict(review.("request_changes", "Design"), "In Progress") == :overridden
    assert Analytics.maestro_verdict(review.("request_changes", "Design"), "Merging") == :overridden
    assert Analytics.maestro_verdict(review.("request_changes", "Design"), nil) == :pending

    assert Analytics.maestro_verdict(review.("approve", "Requirements"), "In Progress") == :agreed
    assert Analytics.maestro_verdict(review.("approve", "Design"), "Rework") == :overridden
    assert Analytics.maestro_verdict(review.("approve", "Design"), "Merging") == :pending

    assert Analytics.maestro_verdict(review.("approve", "Implementation"), "Merging") == :agreed
    assert Analytics.maestro_verdict(review.("approve", "Implementation"), "Rework") == :overridden
    assert Analytics.maestro_verdict(review.("approve", "Implementation"), "In Progress") == :pending
    assert Analytics.maestro_verdict(review.("merge_nudge", nil), "Merging") == :agreed
    assert Analytics.maestro_verdict(review.("merge_nudge", "Implementation"), "Rework") == :overridden
    assert Analytics.maestro_verdict(review.("merge_nudge", "Implementation"), "In Progress") == :pending

    assert Analytics.maestro_verdict(review.("approve", nil), "In Progress") == :excluded
    assert Analytics.maestro_verdict(review.("approve", "Deployment"), "Merging") == :excluded
    assert Analytics.maestro_verdict(review.("ask_clarification", "Requirements"), "Rework") == :excluded
    assert Analytics.maestro_verdict(review.("no_reply_yet", "Design"), "In Progress") == :excluded
    assert Analytics.maestro_verdict(review.("completion_confirmation", "Deployment"), "Merging") == :excluded
    assert Analytics.maestro_verdict(review.("unknown", "Design"), "Rework") == :excluded
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

  test "window_report merges archives before the live file and dedupes across files" do
    live = tmp_path("analytics.ndjson")
    dir = Path.dirname(live)
    archive_one = Path.join(dir, "archive-2026-06-01.ndjson")
    archive_two = Path.join(dir, "archive-2026-06-10.ndjson")
    # An engine-log DIRECTORY and a stray text file next to the store must not match the glob.
    File.mkdir_p!(Path.join(dir, "archive-20260620-140057"))
    File.write!(Path.join(dir, "archive-notes.txt"), "ignored")

    Analytics.record_event(
      %{event_type: :run_started, event_id: "dup-1", issue_id: "issue-arch", issue_identifier: "ARCH-1"},
      path: archive_one,
      recorded_at: "2026-06-01T10:00:00Z"
    )

    File.write!(archive_one, "garbage\n", [:append])

    Analytics.record_event(
      %{event_type: :run_started, event_id: "arch-2", issue_id: "issue-arch-2"},
      path: archive_two,
      recorded_at: "2026-06-10T10:00:00Z"
    )

    # Live duplicate of the archived event_id: the archive copy must win.
    Analytics.record_event(
      %{event_type: :run_started, event_id: "dup-1", issue_id: "issue-live-dup"},
      path: live,
      recorded_at: "2026-06-15T10:00:00Z"
    )

    Analytics.record_event(
      %{event_type: :run_started, event_id: "live-1", issue_id: "issue-live"},
      path: live,
      recorded_at: "2026-06-15T11:00:00Z"
    )

    File.write!(live, "also-garbage\n", [:append])

    assert Analytics.archive_paths(live) == [archive_one, archive_two]

    report = Analytics.window_report(:all, path: live)

    assert report.window == :all
    assert report.summary.event_sample_count == 3
    assert report.summary.warnings == ["skipped 2 malformed analytics event line(s)"]
    assert report.summary.truncated? == false
    refute "Analytics event file was truncated to the latest window" in report.summary.data_quality.gaps
    assert report.summary.window_started_at == "2026-06-01T10:00:00Z"
    assert report.summary.window_ended_at == "2026-06-15T11:00:00Z"

    per_day = report.history.per_day
    expected_dates = Enum.map(Date.range(~D[2026-06-01], ~D[2026-06-15]), &Date.to_iso8601/1)
    assert Enum.map(per_day, & &1.date) == expected_dates
    assert Enum.map(report.history.north_star, & &1.date) == expected_dates

    # First-wins dedupe: dup-1 lands on the archive date, not the live one.
    assert %{runs_started: 1, active_issues: 1} = hd(per_day)
    assert %{runs_started: 1} = List.last(per_day)

    # Densified gap days carry zeroed counters and "n/a" north-star ratios.
    assert %{runs_started: 0, active_issues: 0, tokens: %{total: 0}, completed_by_state: %{}} = Enum.at(per_day, 1)

    assert %{cycle: %{issues_first_published: 0, runs_completed: 0}, rework_rate: "n/a", cost_per_issue: "n/a"} =
             Enum.at(report.history.north_star, 1)
  end

  test "window_report filters point events by cutoff and drops undatable events from bounded windows" do
    now = ~U[2026-06-15 12:00:00Z]
    live = tmp_path("windowed.ndjson")

    [
      {"2026-05-06T12:00:00Z", "all-only"},
      {"2026-05-26T12:00:00Z", "in-d30"},
      {"2026-06-12T12:00:00Z", "in-d7"},
      {"2026-06-15T10:00:00Z", "in-h24"},
      {"not-a-timestamp", "undated"}
    ]
    |> Enum.each(fn {recorded_at, issue_id} ->
      Analytics.record_event(%{event_type: :run_started, issue_id: issue_id}, path: live, recorded_at: recorded_at)
    end)

    # A raw line with no recorded_at at all is equally unplaceable.
    File.write!(live, Jason.encode!(%{event_type: "run_started", issue_id: "no-timestamp"}) <> "\n", [:append])

    for {window, expected_count} <- [h24: 1, d7: 2, d30: 3, all: 6] do
      report = Analytics.window_report(window, path: live, now: now)
      assert report.window == window
      assert report.summary.event_sample_count == expected_count
    end

    h24 = Analytics.window_report(:h24, path: live, now: now)
    assert Enum.map(h24.history.per_day, & &1.date) == ["2026-06-15"]
    assert h24.summary.window_started_at == "2026-06-15T10:00:00Z"

    d7 = Analytics.window_report(:d7, path: live, now: now)
    d7_dates = Enum.map(Date.range(~D[2026-06-12], ~D[2026-06-15]), &Date.to_iso8601/1)
    assert Enum.map(d7.history.per_day, & &1.date) == d7_dates
    assert Enum.map(d7.history.north_star, & &1.date) == d7_dates

    all = Analytics.window_report(:all, path: live, now: now)
    assert all.summary.window_started_at == "2026-05-06T12:00:00Z"
    # The trailing undated events are unplaceable: the window end stays nil and
    # they never land in per_day; they only count toward the :all totals.
    assert all.summary.window_ended_at == nil
    assert all.history.per_day |> Enum.map(& &1.runs_started) |> Enum.sum() == 4
  end

  test "window_report filters backfilled events on occurred_at, matching the day-bucketing axis" do
    now = ~U[2026-06-15 12:00:00Z]
    live = tmp_path("backfilled.ndjson")

    # A backfilled event: really happened a month ago (occurred_at) but was
    # recorded yesterday. Summary counts and history rows must agree it is
    # OUTSIDE the 7-day window and inside :all.
    Analytics.record_event(
      %{event_type: :phase_published, issue_id: "old-issue", occurred_at: "2026-05-10T09:00:00Z"},
      path: live,
      recorded_at: "2026-06-14T08:00:00Z"
    )

    Analytics.record_event(
      %{event_type: :phase_published, issue_id: "fresh-issue"},
      path: live,
      recorded_at: "2026-06-14T09:00:00Z"
    )

    d7 = Analytics.window_report(:d7, path: live, now: now)
    assert d7.summary.event_sample_count == 1
    assert d7.summary.window_started_at == "2026-06-14T09:00:00Z"
    assert d7.history.per_day |> Enum.map(& &1.phase_published) |> Enum.sum() == 1

    all = Analytics.window_report(:all, path: live, now: now)
    assert all.summary.event_sample_count == 2
    assert all.summary.window_started_at == "2026-05-10T09:00:00Z"
    assert List.first(all.history.per_day).date == "2026-05-10"
  end

  test "window_report and read_full_history default to the configured live file" do
    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-default"}, recorded_at: "2026-06-15T10:00:00Z")

    assert %{events: [%{"issue_id" => "issue-default"}], skipped_lines: 0} = Analytics.read_full_history()

    report = Analytics.window_report(:all)
    assert report.summary.event_sample_count == 1
    assert Enum.map(report.history.per_day, & &1.date) == ["2026-06-15"]
  end

  test "window_report sums sliced per-day token deltas instead of re-baselining filtered snapshots" do
    now = ~U[2026-06-15 12:00:00Z]
    live = tmp_path("token-window.ndjson")

    [
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 70, output_tokens: 30, total_tokens: 100, cached_input_tokens: 35},
        recorded_at: "2026-06-10T00:30:00Z"
      },
      %{event_type: :run_completed, issue_id: "issue-0", run_id: "run-0", runtime_seconds: 40, recorded_at: "2026-06-10T00:31:00Z"},
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 90, output_tokens: 40, total_tokens: 130, cached_input_tokens: 45},
        recorded_at: "2026-06-15T11:00:00Z"
      },
      %{event_type: :run_completed, issue_id: "issue-1", run_id: "run-1", runtime_seconds: 20, recorded_at: "2026-06-15T11:00:30Z"}
    ]
    |> Enum.each(&Analytics.record_event(&1, path: live))

    # run-1 was alive at the h24 cutoff: only the in-window DELTA may be booked,
    # never the run's full cumulative 130-token snapshot.
    h24_cost = :h24 |> Analytics.window_report(path: live, now: now) |> Map.fetch!(:summary) |> panel("cost_per_accepted_issue")

    assert %{label: "Total tokens", value: 30, status: "partial"} in h24_cost.metrics
    assert %{label: "Input tokens", value: 20, status: "partial"} in h24_cost.metrics
    assert %{label: "Output tokens", value: 10, status: "partial"} in h24_cost.metrics
    assert %{label: "Cached input tokens", value: 10, status: "partial"} in h24_cost.metrics
    assert %{label: "Cache hit share", value: "50.0%", status: "partial"} in h24_cost.metrics
    assert %{label: "Runtime seconds", value: 20, status: "partial"} in h24_cost.metrics

    all_cost = :all |> Analytics.window_report(path: live, now: now) |> Map.fetch!(:summary) |> panel("cost_per_accepted_issue")

    assert %{label: "Total tokens", value: 130, status: "partial"} in all_cost.metrics
    assert %{label: "Input tokens", value: 90, status: "partial"} in all_cost.metrics
    assert %{label: "Output tokens", value: 40, status: "partial"} in all_cost.metrics
    assert %{label: "Cached input tokens", value: 45, status: "partial"} in all_cost.metrics
    assert %{label: "Runtime seconds", value: 60, status: "partial"} in all_cost.metrics
  end

  test "window_report on a missing store returns an empty report" do
    report = Analytics.window_report(:d30, path: tmp_path("missing.ndjson"), now: ~U[2026-06-15 12:00:00Z])

    assert report.window == :d30
    assert report.summary.event_sample_count == 0
    assert report.summary.window_started_at == nil
    assert report.summary.window_ended_at == nil
    assert report.summary.warnings == []
    refute "Analytics event file was truncated to the latest window" in report.summary.data_quality.gaps
    assert report.history == %{per_day: [], north_star: []}
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
