defmodule SymphonyElixir.AnalyticsCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Analytics
  alias SymphonyElixir.AnalyticsCache

  test "runs in the application supervision tree and serves reports by window" do
    assert is_pid(Process.whereis(AnalyticsCache))

    report = AnalyticsCache.report(:d7)
    assert report.window == :d7
    assert %{summary: %{panels: panels}, history: %{per_day: _, north_star: _}} = report
    assert Enum.map(panels, & &1.id) |> Enum.member?("cost_per_accepted_issue")
  end

  test "serves an empty report when the analytics store does not exist yet" do
    cache = start_cache!(0)

    report = AnalyticsCache.report(:all, cache)
    assert report.window == :all
    assert report.summary.event_sample_count == 0
    assert report.summary.window_started_at == nil
    assert report.history == %{per_day: [], north_star: []}
    refute "Analytics event file was truncated to the latest window" in report.summary.data_quality.gaps

    # Second call hits the unchanged-fingerprint branch.
    assert AnalyticsCache.report(:h24, cache).summary.event_sample_count == 0
  end

  test "recomputes when the live-file fingerprint changes" do
    cache = start_cache!(0)

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-1"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-2"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 2
  end

  test "serves the stale report inside the minimum recompute interval" do
    cache = start_cache!(60_000)

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-1"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-2"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1
  end

  test "a changed analytics path invalidates cached reports even inside the debounce interval" do
    cache = start_cache!(600_000)

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-1"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1

    fresh_path = Path.join(Path.dirname(Analytics.file_path()), "fresh-analytics.ndjson")
    Application.put_env(:symphony_elixir, :analytics_file, fresh_path)

    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 0
  end

  test "merges archives through the cache and reuses immutable archive parses" do
    cache = start_cache!(0)
    archive = Path.join(Path.dirname(Analytics.file_path()), "archive-2026-06-01.ndjson")

    Analytics.record_event(
      %{event_type: :run_started, event_id: "arch-1", issue_id: "issue-arch"},
      path: archive,
      recorded_at: "2026-06-01T10:00:00Z"
    )

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-live"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 2

    # Rewrite the archive with same-size junk at the same mtime: a re-parse
    # would drop the archived run and warn, the cached parse keeps it.
    stat = File.stat!(archive, time: :posix)
    File.write!(archive, String.duplicate("x", stat.size))
    File.touch!(archive, stat.mtime)
    rewritten = File.stat!(archive, time: :posix)
    assert {rewritten.size, rewritten.mtime} == {stat.size, stat.mtime}

    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-live-2"})

    report = AnalyticsCache.report(:all, cache)
    assert report.summary.event_sample_count == 3
    assert report.summary.warnings == []
  end

  test "a run alive at the cutoff books only its in-window token delta" do
    cache = start_cache!(0)
    five_days_ago = DateTime.utc_now() |> DateTime.add(-5, :day) |> DateTime.to_iso8601()

    Analytics.record_event(
      %{
        event_type: :cost_snapshot,
        issue_id: "issue-1",
        run_id: "run-1",
        tokens: %{input_tokens: 800, output_tokens: 200, total_tokens: 1000, cached_input_tokens: 400}
      },
      recorded_at: five_days_ago
    )

    Analytics.record_event(%{
      event_type: :cost_snapshot,
      issue_id: "issue-1",
      run_id: "run-1",
      tokens: %{input_tokens: 840, output_tokens: 210, total_tokens: 1050, cached_input_tokens: 420}
    })

    h24_metrics = cost_metrics(AnalyticsCache.report(:h24, cache))
    assert %{label: "Total tokens", value: 50, status: "partial"} in h24_metrics
    assert %{label: "Input tokens", value: 40, status: "partial"} in h24_metrics
    assert %{label: "Cached input tokens", value: 20, status: "partial"} in h24_metrics

    all_metrics = cost_metrics(AnalyticsCache.report(:all, cache))
    assert %{label: "Total tokens", value: 1050, status: "partial"} in all_metrics
  end

  test "an unreadable live file yields an empty report and heals on the next refresh" do
    cache = start_cache!(0)
    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-1"})
    File.chmod!(Analytics.file_path(), 0)

    try do
      assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 0
    after
      File.chmod!(Analytics.file_path(), 0o600)
    end

    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1
  end

  test "a failed refresh serves the last-known-good report instead of blanking a warm cache" do
    cache = start_cache!(0)
    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-1"})
    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1

    # Change the fingerprint, then make the read fail: the stale-but-correct
    # cached report must win over an empty one.
    Analytics.record_event(%{event_type: :run_started, issue_id: "issue-2"})
    File.chmod!(Analytics.file_path(), 0)

    try do
      assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 1
    after
      File.chmod!(Analytics.file_path(), 0o600)
    end

    assert AnalyticsCache.report(:all, cache).summary.event_sample_count == 2
  end

  defp cost_metrics(report) do
    report.summary.panels |> Enum.find(&(&1.id == "cost_per_accepted_issue")) |> Map.fetch!(:metrics)
  end

  defp start_cache!(min_recompute_ms) do
    previous = Application.get_env(:symphony_elixir, :analytics_cache_min_recompute_ms)
    Application.put_env(:symphony_elixir, :analytics_cache_min_recompute_ms, min_recompute_ms)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :analytics_cache_min_recompute_ms)
      else
        Application.put_env(:symphony_elixir, :analytics_cache_min_recompute_ms, previous)
      end
    end)

    name = :"analytics_cache_#{System.unique_integer([:positive])}"
    {:ok, pid} = AnalyticsCache.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end
end
