defmodule SymphonyElixir.RoutingLabelsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Eval.Routing, as: RoutingTask
  alias SymphonyElixir.RoutingLabels

  test "cases labels each active dispatch with the first publication before the issue's next dispatch" do
    events = [
      # DEV-1: In Progress dispatch publishes Design, reviewer dispatch bounds the window,
      # then a second In Progress dispatch publishes Implementation.
      run_started(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "recorded_at" => "2026-06-15T10:00:00Z"}),
      published(%{"issue_id" => "i1", "comment_id" => "a1", "phase" => "Design", "occurred_at" => "2026-06-15T10:20:00Z"}),
      run_started(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "state" => "Human Review", "recorded_at" => "2026-06-15T10:30:00Z"}),
      run_started(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "recorded_at" => "2026-06-15T12:00:00Z"}),
      published(%{"issue_id" => "i1", "comment_id" => "b1", "phase" => "Implementation", "occurred_at" => "2026-06-15T12:20:00Z"}),
      # DEV-2: Merging dispatch publishes Deployment.
      run_started(%{"issue_id" => "i2", "issue_identifier" => "DEV-2", "issue_url" => "https://linear.app/grandline/issue/DEV-2", "state" => "Merging", "recorded_at" => "2026-06-15T10:00:00Z"}),
      published(%{"issue_id" => "i2", "comment_id" => "c1", "phase" => "Deployment", "occurred_at" => "2026-06-15T10:10:00Z"}),
      # DEV-3: Rework dispatch publishes nothing -> unlabeled.
      run_started(%{"issue_id" => "i3", "issue_identifier" => "DEV-3", "state" => "Rework", "recorded_at" => "2026-06-15T10:00:00Z"}),
      # DEV-4: only a Human Review dispatch -> never a case, its publication stays unclaimed.
      run_started(%{"issue_id" => "i4", "issue_identifier" => "DEV-4", "state" => "Human Review", "recorded_at" => "2026-06-15T10:00:00Z"}),
      published(%{"issue_id" => "i4", "comment_id" => "d1", "phase" => "Design", "occurred_at" => "2026-06-15T10:20:00Z"})
    ]

    assert %{cases: [first, second, merging], unlabeled: 1} = RoutingLabels.cases(events)

    assert first == %{
             issue_identifier: "DEV-1",
             issue_url: "https://linear.app/grandline/issue/DEV-1",
             dispatch_at: "2026-06-15T10:00:00Z",
             state: "In Progress",
             expected_phase: "Design",
             published_event_id: "phase_published:a1"
           }

    assert %{issue_identifier: "DEV-1", dispatch_at: "2026-06-15T12:00:00Z", expected_phase: "Implementation", published_event_id: "phase_published:b1"} = second
    assert %{issue_identifier: "DEV-2", state: "Merging", expected_phase: "Deployment", published_event_id: "phase_published:c1"} = merging
  end

  test "a publication after the issue's next dispatch belongs to that next dispatch" do
    events = [
      run_started(%{"issue_id" => "i1", "recorded_at" => "2026-06-15T10:00:00Z"}),
      run_started(%{"issue_id" => "i1", "state" => "Rework", "recorded_at" => "2026-06-15T11:00:00Z"}),
      published(%{"issue_id" => "i1", "comment_id" => "a1", "occurred_at" => "2026-06-15T11:20:00Z"})
    ]

    assert %{cases: [only], unlabeled: 1} = RoutingLabels.cases(events)
    assert %{dispatch_at: "2026-06-15T11:00:00Z", state: "Rework", expected_phase: "Design"} = only
  end

  test "a Human Review dispatch is never a case but still bounds the previous window" do
    events = [
      run_started(%{"issue_id" => "i1", "recorded_at" => "2026-06-15T10:00:00Z"}),
      run_started(%{"issue_id" => "i1", "state" => "Human Review", "recorded_at" => "2026-06-15T10:30:00Z"}),
      published(%{"issue_id" => "i1", "comment_id" => "a1", "occurred_at" => "2026-06-15T10:45:00Z"})
    ]

    assert %{cases: [], unlabeled: 1} = RoutingLabels.cases(events)
  end

  test "cases dedup dispatches and publications, require strictly-later publications, and parse recorded_at fallback" do
    duplicated_dispatch = run_started(%{"issue_id" => "i1", "recorded_at" => "2026-06-15T09:30:00Z"})
    duplicated_publish = published(%{"issue_id" => "i1", "comment_id" => "a1", "occurred_at" => nil, "recorded_at" => "2026-06-15T12:00:00+02:00"})

    events = [
      duplicated_dispatch,
      duplicated_dispatch,
      duplicated_publish,
      duplicated_publish,
      # Publication exactly at the dispatch time is not strictly later.
      run_started(%{"issue_id" => "i2", "issue_identifier" => "DEV-2", "recorded_at" => "2026-06-15T10:00:00Z"}),
      published(%{"issue_id" => "i2", "comment_id" => "b1", "occurred_at" => "2026-06-15T10:00:00Z"}),
      # A dispatch without a parseable timestamp is dropped entirely.
      run_started(%{"issue_id" => "i3", "recorded_at" => "garbage"})
    ]

    # The 12:00+02:00 publication is 10:00Z, after the deduped 09:30Z dispatch.
    assert %{cases: [only], unlabeled: 1} = RoutingLabels.cases(events)
    assert %{dispatch_at: "2026-06-15T09:30:00Z", expected_phase: "Design", published_event_id: "phase_published:a1"} = only
  end

  test "report counts cases by state and expected phase plus the unlabeled total" do
    cases = [
      %{state: "In Progress", expected_phase: "Design"},
      %{state: "In Progress", expected_phase: "Requirements"},
      %{state: "Merging", expected_phase: "Deployment"},
      %{state: "Rework", expected_phase: "Design"}
    ]

    report = RoutingLabels.report(%{cases: cases, unlabeled: 3})

    assert report =~ "# Routing Label Corpus Report"
    assert report =~ "| State | Requirements | Design | Implementation | Deployment | Total |"
    assert report =~ "| In Progress | 1 | 1 | 0 | 0 | 2 |"
    assert report =~ "| Merging | 0 | 0 | 0 | 1 | 1 |"
    assert report =~ "| Rework | 0 | 1 | 0 | 0 | 1 |"
    assert report =~ "| Total | 1 | 2 | 0 | 1 | 4 |"
    assert report =~ "published nothing (unlabeled, excluded): 3"
    assert report =~ "never cases"
  end

  test "mix symphony.eval.routing writes cases.jsonl and labels-report.md" do
    dir = tmp_dir!()
    analytics_path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "eval")

    events = [
      run_started(%{"issue_id" => "i1", "issue_identifier" => "DEV-1", "recorded_at" => "2026-06-15T10:00:00Z"}),
      published(%{"issue_id" => "i1", "comment_id" => "a1", "phase" => "Requirements", "occurred_at" => "2026-06-15T10:20:00Z"}),
      run_started(%{"issue_id" => "i2", "issue_identifier" => "DEV-2", "state" => "Rework", "recorded_at" => "2026-06-15T10:00:00Z"})
    ]

    lines = Enum.map(events, &(Jason.encode!(&1) <> "\n"))
    File.write!(analytics_path, ["not-json\n", "\n" | lines])

    output = capture_io(fn -> RoutingTask.run(["--analytics", analytics_path, "--output", output_dir]) end)
    assert output =~ "Wrote 1 labeled routing case(s) (1 unlabeled dispatch(es) excluded)"

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
               "dispatch_at" => "2026-06-15T10:00:00Z",
               "state" => "In Progress",
               "expected_phase" => "Requirements",
               "published_event_id" => "phase_published:a1"
             }
           ] = cases

    report = File.read!(Path.join(output_dir, "labels-report.md"))
    assert report =~ "# Routing Label Corpus Report"
    assert report =~ "| In Progress | 1 | 0 | 0 | 0 | 1 |"
    assert report =~ "published nothing (unlabeled, excluded): 1"
  end

  test "mix task rejects invalid options and missing analytics files" do
    dir = tmp_dir!()

    assert_raise Mix.Error, ~r/Invalid option/, fn -> RoutingTask.run(["--wat"]) end

    missing = Path.join(dir, "missing.ndjson")

    assert_raise Mix.Error, ~r/Unable to read analytics events/, fn ->
      RoutingTask.run(["--analytics", missing, "--output", Path.join(dir, "eval")])
    end
  end

  defp run_started(overrides) do
    identifier = Map.get(overrides, "issue_identifier", "DEV-1")

    Map.merge(
      %{
        "event_type" => "run_started",
        "issue_id" => "issue-1",
        "issue_identifier" => identifier,
        "issue_url" => "https://linear.app/grandline/issue/#{identifier}",
        "state" => "In Progress",
        "recorded_at" => "2026-06-15T10:00:00Z"
      },
      overrides
    )
  end

  defp published(overrides) do
    comment_id = Map.get(overrides, "comment_id", "artifact-#{System.unique_integer([:positive])}")

    Map.merge(
      %{
        "event_type" => "phase_published",
        "event_id" => "phase_published:#{comment_id}",
        "issue_id" => "issue-1",
        "phase" => "Design",
        "comment_id" => comment_id,
        "occurred_at" => "2026-06-15T10:20:00Z"
      },
      overrides
    )
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "routing-labels-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
