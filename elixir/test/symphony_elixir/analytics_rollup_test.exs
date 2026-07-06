defmodule SymphonyElixir.AnalyticsRollupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Analytics.Rollup, as: RollupTask
  alias SymphonyElixir.AnalyticsRollup

  test "read_all_events streams the full file, counts unparseable lines, and dedups by event_id (first wins)" do
    dir = tmp_dir!()
    path = Path.join(dir, "analytics.ndjson")

    File.write!(path, """
    {"event_type":"run_started","event_id":"e1","n":1}
    not-json

    {"event_type":"run_started","event_id":"e1","n":2}
    {"event_type":"hook_failed","n":3}
    {"event_type":"hook_failed","n":3}
    42
    """)

    assert %{
             events: [
               %{"event_type" => "run_started", "event_id" => "e1", "n" => 1},
               %{"event_type" => "hook_failed", "n" => 3},
               %{"event_type" => "hook_failed", "n" => 3}
             ],
             skipped_lines: 2
           } = AnalyticsRollup.read_all_events(path)

    assert AnalyticsRollup.read_all_events(Path.join(dir, "missing.ndjson")) == %{events: [], skipped_lines: 0}
  end

  test "rollup aggregates per-day counters, tokens with cached input deltas, and per-issue stats" do
    rollup = AnalyticsRollup.rollup(fixture_events())

    assert [day1, day2, day3] = rollup.per_day

    assert day1 == %{
             date: "2026-06-01",
             runs_started: 1,
             runs_completed: 0,
             completed_by_state: %{},
             tokens: %{total: 280, input: 200, output: 80, cached_input: 90},
             phase_published: 1,
             phase_approved: 0,
             phase_auto_advanced: 0,
             phase_reworked: 0,
             phase_rollback: 0,
             maestro_reviews: 0,
             maestro_agreed: 0,
             maestro_overridden: 0,
             maestro_skipped: 1,
             hook_failed: 1,
             active_issues: 1,
             issues_first_published: 1
           }

    assert day2 == %{
             date: "2026-06-02",
             runs_started: 1,
             runs_completed: 2,
             completed_by_state: %{"Rework" => 1, "Done" => 1},
             tokens: %{total: 95, input: 70, output: 25, cached_input: 30},
             phase_published: 1,
             phase_approved: 1,
             phase_auto_advanced: 1,
             phase_reworked: 1,
             phase_rollback: 1,
             maestro_reviews: 0,
             maestro_agreed: 0,
             maestro_overridden: 0,
             maestro_skipped: 0,
             hook_failed: 0,
             active_issues: 2,
             issues_first_published: 1
           }

    assert day3 == %{
             date: "2026-06-03",
             runs_started: 0,
             runs_completed: 0,
             completed_by_state: %{},
             tokens: %{total: 7, input: 7, output: 0, cached_input: 0},
             phase_published: 1,
             phase_approved: 0,
             phase_auto_advanced: 0,
             phase_reworked: 0,
             phase_rollback: 0,
             maestro_reviews: 0,
             maestro_agreed: 0,
             maestro_overridden: 0,
             maestro_skipped: 0,
             hook_failed: 0,
             active_issues: 1,
             issues_first_published: 0
           }

    assert rollup.per_issue == %{
             "DEV-1" => %{
               first_seen: "2026-06-01T10:00:00Z",
               last_seen: "2026-06-03T09:00:00Z",
               runs: 1,
               tokens_total: 360,
               rework_rounds: 2,
               phases_published: 2
             },
             "DEV-2" => %{
               first_seen: "2026-06-02T09:50:00Z",
               last_seen: "2026-06-02T11:30:00Z",
               runs: 1,
               tokens_total: 15,
               rework_rounds: 0,
               phases_published: 1
             }
           }

    assert rollup.totals == %{
             events: 21,
             days: 3,
             issues: 2,
             runs_started: 2,
             runs_completed: 2,
             tokens: %{total: 382, input: 277, output: 105, cached_input: 120},
             phase_published: 3,
             phase_approved: 1,
             phase_auto_advanced: 1,
             phase_reworked: 1,
             phase_rollback: 1,
             maestro_reviews: 0,
             maestro_agreed: 0,
             maestro_overridden: 0,
             maestro_skipped: 1,
             hook_failed: 1
           }
  end

  test "rollup joins maestro reviews with the next run state via Analytics.maestro_verdict/2" do
    events = [
      event("maestro_review", "2026-06-01T10:00:30Z", %{
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "recommendation" => "request_changes",
        "phase" => "Implementation",
        "occurred_at" => "2026-06-01T10:00:00Z"
      }),
      event("run_started", "2026-06-01T11:00:00Z", %{"issue_id" => "issue-1", "issue_identifier" => "DEV-1", "state" => "Rework"}),
      event("maestro_review", "2026-06-01T10:00:00Z", %{"issue_id" => "issue-2", "recommendation" => "request_changes", "phase" => "Design"}),
      event("run_started", "2026-06-01T11:00:00Z", %{"issue_id" => "issue-2", "issue_identifier" => "DEV-2", "state" => "In Progress"}),
      event("maestro_review", "2026-06-01T10:00:00Z", %{"issue_id" => "issue-3", "recommendation" => "approve", "phase" => "Requirements"}),
      event("maestro_review", "2026-06-01T10:00:00Z", %{"recommendation" => "approve", "phase" => "Implementation"})
    ]

    rollup = AnalyticsRollup.rollup(events)

    assert [%{date: "2026-06-01", runs_started: 2, maestro_reviews: 4, maestro_agreed: 1, maestro_overridden: 1}] = rollup.per_day
    assert %{maestro_reviews: 4, maestro_agreed: 1, maestro_overridden: 1} = rollup.totals
  end

  test "north_star computes cycle, rework rate, and cost per issue with n/a safety" do
    rollup = AnalyticsRollup.rollup(fixture_events())

    assert AnalyticsRollup.north_star(rollup) == [
             %{date: "2026-06-01", cycle: %{issues_first_published: 1, runs_completed: 0}, rework_rate: "0.0%", cost_per_issue: 280},
             %{date: "2026-06-02", cycle: %{issues_first_published: 1, runs_completed: 2}, rework_rate: "200.0%", cost_per_issue: 48},
             %{date: "2026-06-03", cycle: %{issues_first_published: 0, runs_completed: 0}, rework_rate: "0.0%", cost_per_issue: 7}
           ]

    capacity_only = AnalyticsRollup.rollup([event("capacity_snapshot", "2026-06-05T08:00:00Z", %{"running_count" => 1})])

    assert AnalyticsRollup.north_star(capacity_only) == [
             %{date: "2026-06-05", cycle: %{issues_first_published: 0, runs_completed: 0}, rework_rate: "n/a", cost_per_issue: "n/a"}
           ]
  end

  test "rollup buckets days by occurred_at when present, falling back to recorded_at" do
    events = [
      event("phase_published", "2026-07-04T09:00:00Z", %{
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "occurred_at" => "2026-06-02T10:00:00Z"
      }),
      event("phase_published", "2026-07-04T09:01:00Z", %{"issue_id" => "issue-2", "issue_identifier" => "DEV-2"}),
      event("phase_published", "2026-07-04T09:02:00Z", %{
        "issue_id" => "issue-3",
        "issue_identifier" => "DEV-3",
        "occurred_at" => "not-a-date"
      })
    ]

    rollup = AnalyticsRollup.rollup(events)

    assert [
             %{date: "2026-06-02", phase_published: 1, issues_first_published: 1},
             %{date: "2026-07-04", phase_published: 2, issues_first_published: 2}
           ] = rollup.per_day
  end

  test "mix task writes rollup.json and report.md and prints a one-line summary" do
    dir = tmp_dir!()
    path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "out")
    write_ndjson!(path, fixture_events())
    File.write!(path, "garbage-line\n", [:append])

    output = capture_io(fn -> RollupTask.run(["--analytics", path, "--output", output_dir]) end)

    assert output =~ "rollup: 21 events (1 skipped), 3 days, 2 issues -> #{Path.join(output_dir, "rollup.json")} + report.md"
    refute output =~ "archived"

    json = output_dir |> Path.join("rollup.json") |> File.read!() |> Jason.decode!()
    assert json["skipped_lines"] == 1
    assert json["analytics_path"] == path
    assert json["totals"]["events"] == 21
    assert json["totals"]["tokens"] == %{"total" => 382, "input" => 277, "output" => 105, "cached_input" => 120}
    assert [%{"date" => "2026-06-01"}, %{"date" => "2026-06-02"}, %{"date" => "2026-06-03"}] = json["per_day"]
    assert json["per_issue"]["DEV-1"]["tokens_total"] == 360
    assert [%{"date" => "2026-06-01", "cycle" => %{"issues_first_published" => 1}} | _rest] = json["north_star"]

    report = output_dir |> Path.join("report.md") |> File.read!()
    assert report =~ "## 概览"
    assert report =~ "- 事件总数: 21（跳过无法解析的行: 1）"
    assert report =~ "- Token: 总计 382（输入 277 / 输出 105 / 缓存输入 120）"
    assert report =~ "### 周期代理"
    assert report =~ "| 2026-06-02 | 1 | 2 |"
    assert report =~ "### 返工率"
    assert report =~ "| 2026-06-02 | 1 | 2 | 200.0% |"
    assert report =~ "### 单 issue 成本"
    assert report =~ "| 2026-06-02 | 95 | 2 | 48 |"
    assert report =~ "## Token 消耗 Top 10 issues"
    assert report =~ ~r/\| DEV-1 \| 360 \| 1 \| 2 \| 2 \| 2026-06-01T10:00:00Z \| 2026-06-03T09:00:00Z \|\n\| DEV-2 \| 15 \|/
  end

  test "mix task report limits the north-star tables to the last 14 days" do
    dir = tmp_dir!()
    path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "out")

    events =
      for day <- 1..16 do
        date = "2026-06-#{String.pad_leading(Integer.to_string(day), 2, "0")}"
        event("phase_published", "#{date}T10:00:00Z", %{"issue_identifier" => "DEV-ALL", "issue_id" => "issue-all"})
      end

    write_ndjson!(path, events)
    capture_io(fn -> RollupTask.run(["--analytics", path, "--output", output_dir]) end)

    report = output_dir |> Path.join("report.md") |> File.read!()
    refute report =~ "| 2026-06-01 |"
    refute report =~ "| 2026-06-02 |"
    assert report =~ "| 2026-06-03 |"
    assert report =~ "| 2026-06-16 |"

    json = output_dir |> Path.join("rollup.json") |> File.read!() |> Jason.decode!()
    assert length(json["north_star"]) == 16
  end

  test "mix task defaults output to rollup/ next to the analytics file regardless of cwd" do
    dir = tmp_dir!()
    path = Path.join(dir, "analytics.ndjson")
    write_ndjson!(path, [event("run_started", "2026-06-01T10:00:00Z", %{"issue_identifier" => "DEV-1", "issue_id" => "issue-1"})])

    original_env = Application.fetch_env(:symphony_elixir, :analytics_file)
    Application.put_env(:symphony_elixir, :analytics_file, path)

    try do
      output = capture_io(fn -> RollupTask.run([]) end)
      assert output =~ "rollup: 1 events (0 skipped), 1 days, 1 issues"
    after
      restore_app_env(:analytics_file, original_env)
    end

    assert File.regular?(Path.join(dir, "rollup/rollup.json"))
    assert File.regular?(Path.join(dir, "rollup/report.md"))
  end

  test "mix task validates options and archive-before dates" do
    dir = tmp_dir!()

    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      RollupTask.run(["--bogus"])
    end

    assert_raise Mix.Error, ~r/archive-before/, fn ->
      RollupTask.run(["--analytics", Path.join(dir, "analytics.ndjson"), "--output", Path.join(dir, "out"), "--archive-before", "junk"])
    end

    output =
      capture_io(fn ->
        RollupTask.run(["--analytics", Path.join(dir, "missing.ndjson"), "--output", Path.join(dir, "out"), "--archive-before", "2026-06-01"])
      end)

    assert output =~ "rollup: 0 events (0 skipped), 0 days, 0 issues"
    assert output =~ "archived 0 event line(s)"
  end

  test "archive-before moves old lines verbatim, keeps newer bytes identical, and is idempotent" do
    dir = tmp_dir!()
    path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "out")
    archive = Path.join(dir, "archive-#{Date.to_iso8601(Date.utc_today())}.ndjson")

    new_line = ~s({"event_type":"phase_published","recorded_at":"2026-06-02T00:00:00Z"})
    garbage_line = "not json at all"
    old_line_one = ~s({"event_type":"run_started","recorded_at":"2026-05-30T10:00:00Z",  "weird":   "spacing"})
    boundary_line = ~s({"recorded_at":"2026-06-01T00:00:00Z"})
    old_line_two = ~s({"recorded_at":"2026-05-31T23:59:59Z"})

    content = new_line <> "\n" <> garbage_line <> "\n" <> old_line_one <> "\n" <> boundary_line <> "\n" <> old_line_two
    File.write!(path, content)
    File.write!(archive, "seed\n")

    output = capture_io(fn -> RollupTask.run(["--analytics", path, "--output", output_dir, "--archive-before", "2026-06-01"]) end)

    assert output =~ "archived 2 event line(s)"
    assert File.read!(path) == new_line <> "\n" <> garbage_line <> "\n" <> boundary_line <> "\n"
    assert File.read!(archive) == "seed\n" <> old_line_one <> "\n" <> old_line_two <> "\n"

    output = capture_io(fn -> RollupTask.run(["--analytics", path, "--output", output_dir, "--archive-before", "2026-06-01"]) end)

    assert output =~ "archived 0 event line(s)"
    assert File.read!(path) == new_line <> "\n" <> garbage_line <> "\n" <> boundary_line <> "\n"
    assert File.read!(archive) == "seed\n" <> old_line_one <> "\n" <> old_line_two <> "\n"
  end

  test "archive-before refuses without changes when the analytics lock stays held" do
    dir = tmp_dir!()
    path = Path.join(dir, "analytics.ndjson")
    output_dir = Path.join(dir, "out")
    content = ~s({"recorded_at":"2026-05-01T00:00:00Z"}) <> "\n"
    File.write!(path, content)
    File.mkdir_p!(path <> ".lock")

    assert_raise Mix.Error, ~r/lock still held .* refusing to archive/, fn ->
      RollupTask.run(["--analytics", path, "--output", output_dir, "--archive-before", "2026-06-01"])
    end

    assert File.read!(path) == content
    refute File.exists?(Path.join(output_dir, "rollup.json"))
    refute dir |> File.ls!() |> Enum.any?(&String.starts_with?(&1, "archive-"))
  end

  defp fixture_events do
    [
      event("run_started", "2026-06-01T10:00:00Z", %{"issue_id" => "issue-1", "issue_identifier" => "DEV-1", "state" => "In Progress", "run_id" => "r1"}),
      event("cost_snapshot", "2026-06-01T10:05:00Z", %{
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "run_id" => "r1",
        "tokens" => %{"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150, "cached_input_tokens" => 40}
      }),
      event("cost_snapshot", "2026-06-01T10:30:00Z", %{
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "run_id" => "r1",
        "tokens" => %{"input_tokens" => 200, "output_tokens" => 80, "total_tokens" => 280, "cached_input_tokens" => 90}
      }),
      event("phase_published", "2026-06-01T11:00:00Z", %{"issue_id" => "issue-1", "issue_identifier" => "DEV-1"}),
      event("maestro_skipped", "2026-06-01T11:05:00Z", %{"issue_identifier" => "DEV-1"}),
      event("hook_failed", "2026-06-01T11:06:00Z", %{"issue_identifier" => "DEV-1"}),
      event("run_completed", "2026-06-02T09:00:00Z", %{
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "run_id" => "r1",
        "state" => "Rework",
        "tokens" => %{"input_tokens" => 260, "output_tokens" => 100, "total_tokens" => 360, "cached_input_tokens" => 120}
      }),
      event("cost_snapshot", "2026-06-02T09:05:00Z", %{
        "issue_id" => "issue-1",
        "issue_identifier" => "DEV-1",
        "run_id" => "r1",
        "tokens" => %{"input_tokens" => 250, "output_tokens" => 90, "total_tokens" => 340, "cached_input_tokens" => 110}
      }),
      event("phase_reworked", "2026-06-02T09:10:00Z", %{"issue_id" => "issue-1", "issue_identifier" => "DEV-1"}),
      event("phase_rollback", "2026-06-02T09:15:00Z", %{"issue_identifier" => "DEV-1"}),
      event("run_started", "2026-06-02T09:50:00Z", %{"issue_id" => "issue-2", "issue_identifier" => "DEV-2", "state" => "In Progress"}),
      event("cost_snapshot", "2026-06-02T10:00:00Z", %{
        "issue_id" => "issue-2",
        "issue_identifier" => "DEV-2",
        "attempt" => 0,
        "tokens" => %{"input_tokens" => 10, "output_tokens" => 5.9, "total_tokens" => 15}
      }),
      event("phase_approved", "2026-06-02T10:30:00Z", %{"issue_identifier" => "DEV-2"}),
      event("phase_auto_advanced", "2026-06-02T10:45:00Z", %{"issue_identifier" => "DEV-2"}),
      event("phase_published", "2026-06-02T11:00:00Z", %{"issue_id" => "issue-2", "issue_identifier" => "DEV-2"}),
      event("run_completed", "2026-06-02T11:30:00Z", %{"issue_id" => "issue-2", "issue_identifier" => "DEV-2", "state" => "Done"}),
      event("capacity_snapshot", "2026-06-03T08:00:00Z", %{"running_count" => 1}),
      event("cost_snapshot", "2026-06-03T08:30:00Z", %{"run_id" => "r9", "tokens" => %{"input_tokens" => 7, "total_tokens" => 7}}),
      event("phase_published", "2026-06-03T09:00:00Z", %{"issue_id" => "issue-1", "issue_identifier" => "DEV-1"}),
      event("run_started", "not-a-date", %{"issue_id" => "issue-9", "issue_identifier" => "DEV-9"}),
      %{"event_type" => "hook_failed"}
    ]
  end

  defp event(event_type, recorded_at, extra) do
    Map.merge(%{"event_type" => event_type, "recorded_at" => recorded_at}, extra)
  end

  defp write_ndjson!(path, events) do
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "symphony-analytics-rollup-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:symphony_elixir, key)
end
