defmodule SymphonyElixir.ReviewLabelsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Eval.Reviews, as: ReviewsTask
  alias SymphonyElixir.ReviewLabels

  test "cases labels approve, auto_advanced, superseding rework, rollback, and pending" do
    events = [
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "a1"}),
      approved(%{"issue_id" => "i1", "artifact_comment_id" => "a1", "occurred_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i2", "issue_identifier" => "DEV-2", "comment_id" => "a2"}),
      auto_advanced(%{"issue_id" => "i2", "artifact_comment_id" => "a2", "occurred_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i3", "issue_identifier" => "DEV-3", "comment_id" => "a3"}),
      published(%{"issue_id" => "i3", "issue_identifier" => "DEV-3", "comment_id" => "a3-round2", "occurred_at" => "2026-06-15T12:00:00Z"}),
      published(%{"issue_id" => "i4", "issue_identifier" => "DEV-4", "comment_id" => "a4", "phase" => "Implementation"}),
      rollback(%{"issue_id" => "i4", "from_phase" => "Implementation", "occurred_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i5", "issue_identifier" => "DEV-5", "comment_id" => "a5"})
    ]

    assert [approve, auto, superseded, round2, rolled_back, pending] = ReviewLabels.cases(events)

    assert approve == %{
             issue_identifier: "DEV-1",
             issue_url: "https://linear.app/grandline/issue/DEV-1",
             phase: "Design",
             artifact_comment_id: "a1",
             published_at: "2026-06-15T10:00:00Z",
             label: "approve",
             disposition_event_id: "phase_approved:close-a1",
             disposition_at: "2026-06-15T11:00:00Z",
             needs_clarification: false
           }

    assert %{label: "auto_advanced", artifact_comment_id: "a2", disposition_event_id: "phase_auto_advanced:close-a2"} = auto
    assert %{label: "request_changes", artifact_comment_id: "a3", disposition_event_id: "phase_published:a3-round2", disposition_at: "2026-06-15T12:00:00Z"} = superseded
    assert %{label: "pending", artifact_comment_id: "a3-round2", disposition_event_id: nil, disposition_at: nil} = round2
    assert %{label: "request_changes", artifact_comment_id: "a4", disposition_event_id: "phase_rollback:rollback-i4"} = rolled_back
    assert %{label: "pending", artifact_comment_id: "a5", disposition_event_id: nil, disposition_at: nil} = pending
  end

  test "first disposition wins: an approved artifact later superseded stays approve" do
    events = [
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "a1"}),
      approved(%{"issue_id" => "i1", "artifact_comment_id" => "a1", "occurred_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "a1-later", "occurred_at" => "2026-06-15T12:00:00Z"}),
      rollback(%{"issue_id" => "i1", "from_phase" => "Design", "occurred_at" => "2026-06-15T13:00:00Z"})
    ]

    assert [first, later] = ReviewLabels.cases(events)
    assert %{artifact_comment_id: "a1", label: "approve", disposition_event_id: "phase_approved:close-a1"} = first
    # The later round is itself rolled back out of Design.
    assert %{artifact_comment_id: "a1-later", label: "request_changes", disposition_event_id: "phase_rollback:rollback-i1"} = later
  end

  test "rollback labels only the from_phase artifact of the same issue" do
    events = [
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "req-1", "phase" => "Requirements", "occurred_at" => "2026-06-15T08:00:00Z"}),
      approved(%{"issue_id" => "i1", "artifact_comment_id" => "req-1", "occurred_at" => "2026-06-15T09:00:00Z"}),
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "impl-1", "phase" => "Implementation"}),
      # Rollback out of Implementation back to Requirements: hits impl-1, not req-1
      # (already approved first) and not the other issue's Implementation artifact.
      rollback(%{"issue_id" => "i1", "from_phase" => "Implementation", "target_phase" => "Requirements", "occurred_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i2", "issue_identifier" => "DEV-2", "comment_id" => "impl-2", "phase" => "Implementation"})
    ]

    assert [req, impl, other_impl] = ReviewLabels.cases(events)
    assert %{artifact_comment_id: "req-1", label: "approve"} = req
    assert %{artifact_comment_id: "impl-1", label: "request_changes", disposition_event_id: "phase_rollback:rollback-i1"} = impl
    assert %{artifact_comment_id: "impl-2", label: "pending"} = other_impl
  end

  test "cases dedups by event_id, requires strictly-later dispositions, and parses recorded_at fallback" do
    duplicated = published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "a1", "occurred_at" => nil, "recorded_at" => "2026-06-15T12:00:00+02:00"})

    events = [
      duplicated,
      duplicated,
      # Approval BEFORE the publication (10:00Z = 12:00+02:00) is not a disposition.
      approved(%{"issue_id" => "i1", "artifact_comment_id" => "a1", "occurred_at" => "2026-06-15T09:59:00Z"}),
      # A lexically-later but chronologically-earlier same-phase publish must not supersede.
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "a0", "occurred_at" => "2026-06-15T09:00:00Z"})
    ]

    assert [earlier, deduped] = ReviewLabels.cases(events)
    assert %{artifact_comment_id: "a0", label: "request_changes", disposition_event_id: "phase_published:a1"} = earlier
    assert %{artifact_comment_id: "a1", label: "pending", published_at: "2026-06-15T10:00:00Z"} = deduped
  end

  test "cases without a parseable publication timestamp stay pending" do
    events = [
      published(%{"issue_id" => "i1", "comment_id" => "a1", "occurred_at" => "garbage", "recorded_at" => nil}),
      published(%{"issue_id" => "i2", "comment_id" => "a2", "event_id" => nil, "occurred_at" => nil, "recorded_at" => 123}),
      approved(%{"issue_id" => "i1", "artifact_comment_id" => "a1", "occurred_at" => "2026-06-15T11:00:00Z"})
    ]

    assert [first, second] = ReviewLabels.cases(events)
    assert %{artifact_comment_id: "a1", published_at: nil, label: "pending"} = first
    assert %{artifact_comment_id: "a2", published_at: nil, label: "pending"} = second
  end

  test "report counts labels by phase and the scoreable total" do
    cases = [
      %{phase: "Design", label: "approve"},
      %{phase: "Design", label: "request_changes"},
      %{phase: "Design", label: "pending"},
      %{phase: "Implementation", label: "auto_advanced"},
      %{phase: nil, label: "approve"}
    ]

    report = ReviewLabels.report(cases)

    assert report =~ "# Review Label Corpus Report"
    assert report =~ "| Phase | approve | request_changes | auto_advanced | pending | Total |"
    assert report =~ "| Design | 1 | 1 | 0 | 1 | 3 |"
    assert report =~ "| Implementation | 0 | 0 | 1 | 0 | 1 |"
    assert report =~ "| unknown | 1 | 0 | 0 | 0 | 1 |"
    assert report =~ "| Total | 2 | 1 | 1 | 1 | 5 |"
    assert report =~ "Total scoreable (approve + request_changes): 3"
    assert report =~ "excluded from scoring"
    assert report =~ "what should a reviewer have recommended at that handoff"
  end

  test "mix symphony.eval.reviews writes cases.jsonl and labels-report.md" do
    dir = tmp_dir!()
    analytics_path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "eval")

    events = [
      published(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "comment_id" => "a1", "needs_clarification" => true}),
      approved(%{"issue_id" => "i1", "artifact_comment_id" => "a1", "occurred_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i2", "issue_identifier" => "DEV-2", "comment_id" => "a2"})
    ]

    lines = Enum.map(events, &(Jason.encode!(&1) <> "\n"))
    File.write!(analytics_path, ["not-json\n", "\n" | lines])

    output = capture_io(fn -> ReviewsTask.run(["--analytics", analytics_path, "--output", output_dir]) end)
    assert output =~ "Wrote 2 labeled review case(s) (1 scoreable)"

    cases =
      output_dir
      |> Path.join("cases.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [
             %{
               "issue_identifier" => "DEV-1",
               "issue_url" => "https://linear.app/grandline/issue/DEV-1",
               "phase" => "Design",
               "artifact_comment_id" => "a1",
               "published_at" => "2026-06-15T10:00:00Z",
               "label" => "approve",
               "disposition_event_id" => "phase_approved:close-a1",
               "disposition_at" => "2026-06-15T11:00:00Z",
               "needs_clarification" => true
             },
             %{"issue_identifier" => "DEV-2", "label" => "pending", "disposition_event_id" => nil}
           ] = cases

    report = File.read!(Path.join(output_dir, "labels-report.md"))
    assert report =~ "# Review Label Corpus Report"
    assert report =~ "| Design | 1 | 0 | 0 | 1 | 2 |"
    assert report =~ "Total scoreable (approve + request_changes): 1"
  end

  test "mix task rejects invalid options and missing analytics files" do
    dir = tmp_dir!()

    assert_raise Mix.Error, ~r/Invalid option/, fn -> ReviewsTask.run(["--wat"]) end

    missing = Path.join(dir, "missing.ndjson")

    assert_raise Mix.Error, ~r/Unable to read analytics events/, fn ->
      ReviewsTask.run(["--analytics", missing, "--output", Path.join(dir, "eval")])
    end
  end

  defp published(overrides) do
    comment_id = Map.get(overrides, "comment_id", "artifact-#{System.unique_integer([:positive])}")

    Map.merge(
      %{
        "event_type" => "phase_published",
        "event_id" => "phase_published:#{comment_id}",
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "issue_url" => "https://linear.app/grandline/issue/#{Map.get(overrides, "issue_identifier", "DEV-1")}",
        "phase" => "Design",
        "comment_id" => comment_id,
        "occurred_at" => "2026-06-15T10:00:00Z",
        "needs_clarification" => false
      },
      overrides
    )
  end

  defp approved(overrides), do: closing("phase_approved", overrides)
  defp auto_advanced(overrides), do: closing("phase_auto_advanced", overrides)

  defp closing(event_type, overrides) do
    artifact_id = Map.get(overrides, "artifact_comment_id", "artifact-1")

    Map.merge(
      %{
        "event_type" => event_type,
        "event_id" => "#{event_type}:close-#{artifact_id}",
        "issue_id" => "issue-1",
        "phase" => "Design",
        "artifact_comment_id" => artifact_id,
        "occurred_at" => "2026-06-15T10:30:00Z"
      },
      overrides
    )
  end

  defp rollback(overrides) do
    issue_id = Map.get(overrides, "issue_id", "issue-1")

    Map.merge(
      %{
        "event_type" => "phase_rollback",
        "event_id" => "phase_rollback:rollback-#{issue_id}",
        "issue_id" => issue_id,
        "from_phase" => "Implementation",
        "target_phase" => "Requirements",
        "occurred_at" => "2026-06-15T10:30:00Z"
      },
      overrides
    )
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "review-labels-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
