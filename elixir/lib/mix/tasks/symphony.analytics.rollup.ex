defmodule Mix.Tasks.Symphony.Analytics.Rollup do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Roll up the full analytics NDJSON into rollup.json and a north-star report"

  @moduledoc """
  Reads the FULL analytics NDJSON event file (the dashboard only sees the
  latest 500 events) and writes an operator-facing historical view:

      mix symphony.analytics.rollup [--analytics PATH] [--output DIR] [--archive-before YYYY-MM-DD]

  Writes `rollup.json` (full per-day / per-issue / north-star structure) and
  `report.md` (compact Chinese markdown report) into `--output`
  (default `rollup/` next to the analytics file, so the dashboard reader
  finds it regardless of cwd). `--analytics` defaults to the configured
  analytics file path.

  `--archive-before YYYY-MM-DD` additionally moves event lines strictly older
  than the date into `archive-<today>.ndjson` next to the analytics file
  (append) and atomically rewrites the live file, keeping newer lines
  byte-identical. It refuses (without changes) when the analytics `.lock`
  directory is still present after a 5s wait.
  """

  alias SymphonyElixir.{Analytics, AnalyticsRollup}

  @lock_timeout_ms 5_000
  @lock_retry_ms 50

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [analytics: :string, output: :string, archive_before: :string])
    if invalid != [], do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

    analytics_path = opts[:analytics] || Analytics.file_path()
    output_dir = opts[:output] || Path.join(Path.dirname(analytics_path), "rollup")
    cutoff_date = parse_archive_before(opts[:archive_before])

    %{events: events, skipped_lines: skipped_lines} = AnalyticsRollup.read_all_events(analytics_path)
    archived_count = archive_before(analytics_path, cutoff_date)

    rollup = AnalyticsRollup.rollup(events)
    north_star = AnalyticsRollup.north_star(rollup)

    File.mkdir_p!(output_dir)
    File.write!(Path.join(output_dir, "rollup.json"), rollup_json(analytics_path, skipped_lines, rollup, north_star))
    File.write!(Path.join(output_dir, "report.md"), report_markdown(analytics_path, skipped_lines, rollup, north_star))

    Mix.shell().info(summary_line(length(events), skipped_lines, rollup, output_dir, archived_count))
  end

  defp parse_archive_before(nil), do: nil

  defp parse_archive_before(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> Mix.raise("Invalid --archive-before date (expected YYYY-MM-DD): #{inspect(value)}")
    end
  end

  defp archive_before(_path, nil), do: nil

  defp archive_before(path, %Date{} = cutoff_date) do
    if File.regular?(path) do
      with_analytics_lock(path, fn -> split_and_rewrite(path, cutoff_date) end)
    else
      0
    end
  end

  defp split_and_rewrite(path, cutoff_date) do
    split = path |> File.read!() |> AnalyticsRollup.split_for_archive(cutoff_date)

    if split.archived_count > 0 do
      File.write!(archive_path(path), split.archive, [:append])
      tmp_path = path <> ".rollup-rewrite.tmp"
      File.write!(tmp_path, split.keep)
      File.rename!(tmp_path, path)
    end

    split.archived_count
  end

  defp archive_path(path) do
    Path.join(Path.dirname(path), "archive-#{Date.to_iso8601(Date.utc_today())}.ndjson")
  end

  defp with_analytics_lock(path, fun) do
    lock_path = path <> ".lock"
    deadline_ms = System.monotonic_time(:millisecond) + @lock_timeout_ms
    acquire_lock(lock_path, deadline_ms, fun)
  end

  defp acquire_lock(lock_path, deadline_ms, fun) do
    case File.mkdir(lock_path) do
      :ok ->
        try do
          fun.()
        after
          File.rmdir(lock_path)
        end

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          Mix.raise("Analytics event file lock still held after #{@lock_timeout_ms}ms (#{lock_path}); refusing to archive, no changes made")
        else
          Process.sleep(@lock_retry_ms)
          acquire_lock(lock_path, deadline_ms, fun)
        end
    end
  end

  defp rollup_json(analytics_path, skipped_lines, rollup, north_star) do
    Jason.encode!(
      %{
        generated_at: generated_at(),
        analytics_path: analytics_path,
        skipped_lines: skipped_lines,
        totals: rollup.totals,
        per_day: rollup.per_day,
        per_issue: rollup.per_issue,
        north_star: north_star
      },
      pretty: true
    )
  end

  defp report_markdown(analytics_path, skipped_lines, rollup, north_star) do
    totals = rollup.totals
    rows = Enum.zip(Enum.take(rollup.per_day, -14), Enum.take(north_star, -14))

    """
    # Symphony 分析汇总报告

    - 生成时间: #{generated_at()}
    - 事件文件: `#{analytics_path}`

    ## 概览

    - 事件总数: #{totals.events}（跳过无法解析的行: #{skipped_lines}）
    - 覆盖天数: #{totals.days}；涉及 issue 数: #{totals.issues}
    - 运行: 启动 #{totals.runs_started} / 完成 #{totals.runs_completed}
    - Token: 总计 #{totals.tokens.total}（输入 #{totals.tokens.input} / 输出 #{totals.tokens.output} / 缓存输入 #{totals.tokens.cached_input}）
    - 阶段: 发布 #{totals.phase_published} / 批准 #{totals.phase_approved} / 自动推进 #{totals.phase_auto_advanced} / 返工 #{totals.phase_reworked} / 回滚 #{totals.phase_rollback}
    - Maestro: 评审 #{totals.maestro_reviews} / 一致 #{totals.maestro_agreed} / 被推翻 #{totals.maestro_overridden} / 跳过 #{totals.maestro_skipped}；Hook 失败: #{totals.hook_failed}

    ## 北极星（最近 14 天）

    ### 周期代理

    | 日期 | 首次发布 issue 数 | 完成运行数 |
    | --- | --- | --- |
    #{cycle_rows(rows)}

    ### 返工率

    | 日期 | 发布 | 返工+回滚 | 返工率 |
    | --- | --- | --- | --- |
    #{rework_rows(rows)}

    ### 单 issue 成本

    | 日期 | Token 总量 | 活跃 issue 数 | 每 issue Token |
    | --- | --- | --- | --- |
    #{cost_rows(rows)}

    ## Token 消耗 Top 10 issues

    | Issue | Token 总量 | 运行数 | 返工轮次 | 发布阶段数 | 首次活动 | 最近活动 |
    | --- | --- | --- | --- | --- | --- | --- |
    #{issue_rows(rollup.per_issue)}
    """
  end

  defp cycle_rows(rows) do
    Enum.map_join(rows, "\n", fn {_day, star} ->
      "| #{star.date} | #{star.cycle.issues_first_published} | #{star.cycle.runs_completed} |"
    end)
  end

  defp rework_rows(rows) do
    Enum.map_join(rows, "\n", fn {day, star} ->
      "| #{day.date} | #{day.phase_published} | #{day.phase_reworked + day.phase_rollback} | #{star.rework_rate} |"
    end)
  end

  defp cost_rows(rows) do
    Enum.map_join(rows, "\n", fn {day, star} ->
      "| #{day.date} | #{day.tokens.total} | #{day.active_issues} | #{star.cost_per_issue} |"
    end)
  end

  defp issue_rows(per_issue) do
    per_issue
    |> Enum.sort_by(fn {_identifier, issue} -> -issue.tokens_total end)
    |> Enum.take(10)
    |> Enum.map_join("\n", fn {identifier, issue} ->
      "| #{identifier} | #{issue.tokens_total} | #{issue.runs} | #{issue.rework_rounds} | #{issue.phases_published} | #{issue.first_seen} | #{issue.last_seen} |"
    end)
  end

  defp summary_line(event_count, skipped_lines, rollup, output_dir, archived_count) do
    base =
      "rollup: #{event_count} events (#{skipped_lines} skipped), #{rollup.totals.days} days, #{rollup.totals.issues} issues -> #{Path.join(output_dir, "rollup.json")} + report.md"

    case archived_count do
      nil -> base
      count -> base <> "; archived #{count} event line(s)"
    end
  end

  defp generated_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
