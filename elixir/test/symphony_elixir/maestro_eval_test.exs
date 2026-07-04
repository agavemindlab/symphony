defmodule SymphonyElixir.MaestroEvalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Eval.Maestro, as: EvalTask
  alias SymphonyElixir.MaestroEval

  test "pairs classifies agreed, overridden, pending, and excluded reviews" do
    events = [
      review_event(%{"event_id" => "r1", "issue_id" => "agreed-1", "issue_identifier" => "DEV-1"}),
      run_started_event(%{"issue_id" => "agreed-1"}),
      review_event(%{
        "event_id" => "r2",
        "issue_id" => "overridden-1",
        "issue_identifier" => "DEV-2",
        "phase" => "Implementation",
        "recommendation" => "request_changes"
      }),
      run_started_event(%{"issue_id" => "overridden-1", "state" => "Merging", "recorded_at" => "2026-06-15T12:00:00Z"}),
      review_event(%{
        "event_id" => "r3",
        "issue_id" => "pending-1",
        "issue_identifier" => "DEV-3",
        "recommendation" => "request_changes"
      }),
      review_event(%{
        "event_id" => "r4",
        "issue_id" => "excluded-1",
        "issue_identifier" => "DEV-4",
        "recommendation" => "ask_clarification"
      })
    ]

    assert [agreed, overridden, pending, excluded] = MaestroEval.pairs(events)

    assert agreed == %{
             issue_identifier: "DEV-1",
             phase: "Design",
             recommendation: "approve",
             confidence: 8.5,
             auto: false,
             reviewed_at: "2026-06-15T10:00:00Z",
             verdict_state: "In Progress",
             verdict_at: "2026-06-15T11:00:00Z",
             verdict_source: "dispatch",
             signal_event_id: nil,
             agreement: :agreed
           }

    assert %{agreement: :overridden, verdict_state: "Merging", verdict_at: "2026-06-15T12:00:00Z"} = overridden
    assert %{agreement: :pending, verdict_state: nil, verdict_at: nil, verdict_source: nil} = pending
    assert %{agreement: :excluded, issue_identifier: "DEV-4", verdict_source: nil, signal_event_id: nil} = excluded
  end

  test "pairs derives thread verdicts for approve and request_changes recommendations" do
    events = [
      review_event(%{"event_id" => "t1", "issue_id" => "i1", "issue_identifier" => "DEV-11", "artifact_comment_id" => "a1"}),
      phase_event("phase_approved", %{"event_id" => "close-a1", "issue_id" => "i1", "artifact_comment_id" => "a1"}),
      review_event(%{"event_id" => "t2", "issue_id" => "i2", "issue_identifier" => "DEV-12", "artifact_comment_id" => "a2"}),
      phase_event("phase_reworked", %{"event_id" => "rework-a2", "issue_id" => "i2", "artifact_comment_id" => "a2"}),
      review_event(%{
        "event_id" => "t3",
        "issue_id" => "i3",
        "issue_identifier" => "DEV-13",
        "recommendation" => "request_changes",
        "artifact_comment_id" => "a3"
      }),
      # Different artifact, but the review phase of the same issue: still a rework signal.
      phase_event("phase_reworked", %{"event_id" => "rework-i3", "issue_id" => "i3", "artifact_comment_id" => "a3-other"}),
      review_event(%{
        "event_id" => "t4",
        "issue_id" => "i4",
        "issue_identifier" => "DEV-14",
        "recommendation" => "request_changes",
        "artifact_comment_id" => "a4"
      }),
      phase_event("phase_approved", %{"event_id" => "close-a4", "issue_id" => "i4", "artifact_comment_id" => "a4"})
    ]

    assert [approve_agreed, approve_overridden, changes_agreed, changes_overridden] = MaestroEval.pairs(events)

    assert %{agreement: :agreed, verdict_source: "thread", signal_event_id: "close-a1", verdict_state: nil} = approve_agreed
    assert %{agreement: :overridden, verdict_source: "thread", signal_event_id: "rework-a2"} = approve_overridden
    assert %{agreement: :agreed, verdict_source: "thread", signal_event_id: "rework-i3"} = changes_agreed
    assert %{agreement: :overridden, verdict_source: "thread", signal_event_id: "close-a4"} = changes_overridden
  end

  test "pairs derives merge_nudge thread verdicts, including rollback out of the review phase" do
    events = [
      review_event(%{
        "event_id" => "m1",
        "issue_id" => "i1",
        "recommendation" => "merge_nudge",
        "phase" => "Implementation",
        "artifact_comment_id" => "a1"
      }),
      phase_event("phase_approved", %{"event_id" => "close-a1", "issue_id" => "i1", "artifact_comment_id" => "a1"}),
      review_event(%{
        "event_id" => "m2",
        "issue_id" => "i2",
        "recommendation" => "merge_nudge",
        "phase" => "Implementation",
        "artifact_comment_id" => "a2"
      }),
      %{
        "event_type" => "phase_rollback",
        "event_id" => "rollback-i2",
        "issue_id" => "i2",
        "from_phase" => "Implementation",
        "target_phase" => "Design",
        "occurred_at" => "2026-06-15T10:30:00Z"
      }
    ]

    assert [nudge_agreed, nudge_overridden] = MaestroEval.pairs(events)
    assert %{agreement: :agreed, verdict_source: "thread", signal_event_id: "close-a1"} = nudge_agreed
    assert %{agreement: :overridden, verdict_source: "thread", signal_event_id: "rollback-i2"} = nudge_overridden
  end

  test "thread signals take precedence over the dispatch join" do
    events = [
      review_event(%{
        "event_id" => "p1",
        "issue_id" => "i1",
        "recommendation" => "request_changes",
        "artifact_comment_id" => "a1"
      }),
      # The dispatch join alone would classify request_changes -> Merging as overridden.
      run_started_event(%{"issue_id" => "i1", "state" => "Merging", "recorded_at" => "2026-06-15T12:00:00Z"}),
      phase_event("phase_reworked", %{"event_id" => "rework-a1", "issue_id" => "i1", "artifact_comment_id" => "a1"})
    ]

    assert [pair] = MaestroEval.pairs(events)
    assert pair.agreement == :agreed
    assert pair.verdict_source == "thread"
    assert pair.signal_event_id == "rework-a1"
    # Dispatch context stays on the pair for inspection.
    assert pair.verdict_state == "Merging"
  end

  test "pairs falls back to the dispatch join and stays pending without any signal" do
    events = [
      review_event(%{"event_id" => "d1", "issue_id" => "i1", "artifact_comment_id" => "a1"}),
      run_started_event(%{"issue_id" => "i1"}),
      review_event(%{"event_id" => "d2", "issue_id" => "i2", "artifact_comment_id" => "a2"}),
      # An approval BEFORE the review is not a subsequent signal.
      phase_event("phase_approved", %{
        "event_id" => "early-a2",
        "issue_id" => "i2",
        "artifact_comment_id" => "a2",
        "occurred_at" => "2026-06-15T09:00:00Z"
      })
    ]

    assert [dispatch_pair, pending_pair] = MaestroEval.pairs(events)
    assert %{agreement: :agreed, verdict_source: "dispatch", signal_event_id: nil} = dispatch_pair
    assert %{agreement: :pending, verdict_source: nil, signal_event_id: nil, verdict_state: nil} = pending_pair
  end

  test "pairs joins on parsed timestamps with recorded_at fallback and event_id dedup" do
    duplicated =
      review_event(%{
        "event_id" => "dup",
        "issue_id" => "issue-a",
        "occurred_at" => nil,
        "recorded_at" => "2026-06-15T08:30:00+02:00"
      })

    events = [
      duplicated,
      duplicated,
      run_started_event(%{"issue_id" => "issue-a", "state" => "Rework", "recorded_at" => "2026-06-15T06:00:00Z"}),
      run_started_event(%{"issue_id" => "issue-a", "state" => "Rework", "recorded_at" => "2026-06-15T06:30:00Z"}),
      run_started_event(%{"issue_id" => "issue-a", "state" => "In Progress", "recorded_at" => "2026-06-15T07:00:00Z"}),
      run_started_event(%{"issue_id" => "issue-a", "state" => "Rework", "recorded_at" => "2026-06-15T09:00:00Z"}),
      run_started_event(%{"issue_id" => "issue-other", "state" => "Rework", "recorded_at" => "2026-06-15T07:30:00Z"}),
      run_started_event(%{"issue_id" => "issue-a", "state" => "Rework", "recorded_at" => "not-a-timestamp"})
    ]

    # The review happened at 06:30Z (08:30+02:00). A lexical comparison of the
    # raw strings would consider every "2026-06-15T0..." dispatch earlier than
    # the review and pick the 09:00Z Rework dispatch instead.
    assert [pair] = MaestroEval.pairs(events)
    assert pair.reviewed_at == "2026-06-15T06:30:00Z"
    assert pair.verdict_state == "In Progress"
    assert pair.verdict_at == "2026-06-15T07:00:00Z"
    assert pair.agreement == :agreed
  end

  test "pairs leaves the verdict empty when the review lacks an issue id or parseable timestamp" do
    events = [
      review_event(%{"event_id" => "no-issue", "issue_id" => nil, "recommendation" => "merge_nudge"}),
      run_started_event(%{"issue_id" => nil, "state" => "Merging"}),
      review_event(%{"event_id" => "bad-ts", "issue_id" => "issue-b", "occurred_at" => "garbage"}),
      review_event(%{
        "event_id" => "no-ts",
        "issue_id" => "issue-c",
        "occurred_at" => nil,
        "recommendation" => "unknown"
      }),
      run_started_event(%{"issue_id" => "issue-b"}),
      run_started_event(%{"issue_id" => "issue-c"})
    ]

    assert [no_issue, bad_ts, no_ts] = MaestroEval.pairs(events)

    assert %{agreement: :pending, verdict_state: nil, verdict_at: nil} = no_issue
    assert %{agreement: :pending, reviewed_at: nil, verdict_state: nil, verdict_at: nil} = bad_ts
    assert %{agreement: :excluded, reviewed_at: nil, verdict_state: nil} = no_ts
  end

  test "summarize computes totals and agreement rates overall, by phase, and by recommendation" do
    pairs = [
      %{phase: "Design", recommendation: "approve", agreement: :agreed},
      %{phase: "Design", recommendation: "approve", agreement: :agreed},
      %{phase: "Design", recommendation: "request_changes", agreement: :overridden},
      %{phase: "Implementation", recommendation: "merge_nudge", agreement: :pending},
      %{phase: nil, recommendation: "unknown", agreement: :excluded}
    ]

    summary = MaestroEval.summarize(pairs)

    assert summary.overall == %{total: 5, agreed: 2, overridden: 1, pending: 1, excluded: 1, agreement_rate: 0.6667}

    assert summary.by_phase["Design"] ==
             %{total: 3, agreed: 2, overridden: 1, pending: 0, excluded: 0, agreement_rate: 0.6667}

    assert summary.by_phase["Implementation"] ==
             %{total: 1, agreed: 0, overridden: 0, pending: 1, excluded: 0, agreement_rate: nil}

    assert summary.by_phase["unknown"].total == 1

    assert summary.by_recommendation["approve"] ==
             %{total: 2, agreed: 2, overridden: 0, pending: 0, excluded: 0, agreement_rate: 1.0}

    assert summary.by_recommendation["request_changes"].agreement_rate == 0.0
  end

  test "mix symphony.eval.maestro writes corpus.jsonl and report.md" do
    dir = tmp_dir!()
    analytics_path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "eval")

    events = [
      review_event(%{"event_id" => "r1", "issue_id" => "agreed-1", "issue_identifier" => "DEV-1"}),
      run_started_event(%{"issue_id" => "agreed-1"}),
      review_event(%{
        "event_id" => "r2",
        "issue_id" => "overridden-1",
        "issue_identifier" => "DEV-2",
        "phase" => "Implementation",
        "auto" => true
      }),
      run_started_event(%{"issue_id" => "overridden-1", "state" => "Rework"})
    ]

    lines = Enum.map(events, &(Jason.encode!(&1) <> "\n"))
    File.write!(analytics_path, ["not-json\n", "\n" | lines])

    output = capture_io(fn -> EvalTask.run(["--analytics", analytics_path, "--output", output_dir]) end)
    assert output =~ "Wrote 2 maestro review pair(s)"

    corpus =
      output_dir
      |> Path.join("corpus.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [
             %{
               "issue_identifier" => "DEV-1",
               "phase" => "Design",
               "recommendation" => "approve",
               "confidence" => 8.5,
               "auto" => false,
               "reviewed_at" => "2026-06-15T10:00:00Z",
               "verdict_state" => "In Progress",
               "verdict_at" => "2026-06-15T11:00:00Z",
               "verdict_source" => "dispatch",
               "signal_event_id" => nil,
               "agreement" => "agreed"
             },
             %{"issue_identifier" => "DEV-2", "auto" => true, "verdict_state" => "Rework", "agreement" => "overridden"}
           ] = corpus

    report = File.read!(Path.join(output_dir, "report.md"))
    assert report =~ "# Maestro Verdict Eval Report"
    assert report =~ "| all reviews | 2 | 1 | 1 | 0 | 0 | 50.0% |"
    assert report =~ "Verdict sources: thread 0 / dispatch 2 / none 0."
    assert report =~ "## Agreement by phase"
    assert report =~ "| Phase | Total | Agreed | Overridden | Pending | Excluded | Agreement rate |"
    assert report =~ "| Design | 1 | 1 | 0 | 0 | 0 | 100.0% |"
    assert report =~ "| Implementation | 1 | 0 | 1 | 0 | 0 | 0.0% |"
    assert report =~ "## Agreement by recommendation"
    assert report =~ "| approve | 2 | 1 | 1 | 0 | 0 | 50.0% |"
    assert report =~ "## Overridden cases (prompt-improvement candidates)"

    assert report =~
             "- DEV-2 — Implementation/approve (reviewed 2026-06-15T10:00:00Z, " <>
               "next dispatch Rework at 2026-06-15T11:00:00Z)"
  end

  test "mix task reports n/a rates and no overridden cases for an empty corpus" do
    dir = tmp_dir!()
    analytics_path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "eval")
    File.write!(analytics_path, Jason.encode!(run_started_event(%{})) <> "\n")

    output = capture_io(fn -> EvalTask.run(["--analytics", analytics_path, "--output", output_dir]) end)
    assert output =~ "Wrote 0 maestro review pair(s)"

    assert File.read!(Path.join(output_dir, "corpus.jsonl")) == ""

    report = File.read!(Path.join(output_dir, "report.md"))
    assert report =~ "| all reviews | 0 | 0 | 0 | 0 | 0 | n/a |"
    assert report =~ "None."
  end

  test "mix task rejects invalid options and missing analytics files" do
    dir = tmp_dir!()

    assert_raise Mix.Error, ~r/Invalid option/, fn -> EvalTask.run(["--wat"]) end

    missing = Path.join(dir, "missing.ndjson")

    assert_raise Mix.Error, ~r/Unable to read analytics events/, fn ->
      EvalTask.run(["--analytics", missing, "--output", Path.join(dir, "eval")])
    end
  end

  defp review_event(overrides) do
    Map.merge(
      %{
        "event_type" => "maestro_review",
        "event_id" => "maestro_review:#{System.unique_integer([:positive])}",
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "phase" => "Design",
        "recommendation" => "approve",
        "confidence" => 8.5,
        "auto" => false,
        "occurred_at" => "2026-06-15T10:00:00Z"
      },
      overrides
    )
  end

  defp phase_event(event_type, overrides) do
    Map.merge(
      %{
        "event_type" => event_type,
        "event_id" => "#{event_type}:#{System.unique_integer([:positive])}",
        "issue_id" => "issue-1",
        "phase" => "Design",
        "artifact_comment_id" => "artifact-1",
        "occurred_at" => "2026-06-15T10:30:00Z"
      },
      overrides
    )
  end

  defp run_started_event(overrides) do
    Map.merge(
      %{
        "event_type" => "run_started",
        "issue_id" => "issue-1",
        "state" => "In Progress",
        "recorded_at" => "2026-06-15T11:00:00Z"
      },
      overrides
    )
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "maestro-eval-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
