defmodule SymphonyElixir.AnalyticsRollup do
  @moduledoc """
  Full-history rollup over the analytics NDJSON event store.

  `SymphonyElixir.Analytics` reads only a bounded tail window (the dashboard
  sees the latest 500 events); this module streams the FULL file to build the
  historical per-day / per-issue view behind `mix symphony.analytics.rollup`.

  Maestro review verdicts reuse the public `Analytics.maestro_verdict/2`
  classifier; the review -> next `run_started` join it needs is private in
  `Analytics` via `Analytics.run_started_entries/1` + `Analytics.next_run_state/2`.
  """

  alias SymphonyElixir.Analytics

  @empty_tokens %{total: 0, input: 0, output: 0, cached_input: 0}

  @count_keys [
    :runs_started,
    :runs_completed,
    :phase_published,
    :phase_approved,
    :phase_auto_advanced,
    :phase_reworked,
    :phase_rollback,
    :maestro_reviews,
    :maestro_agreed,
    :maestro_overridden,
    :maestro_skipped,
    :hook_failed
  ]

  @empty_day %{
    runs_started: 0,
    runs_completed: 0,
    completed_by_state: %{},
    tokens: @empty_tokens,
    phase_published: 0,
    phase_approved: 0,
    phase_auto_advanced: 0,
    phase_reworked: 0,
    phase_rollback: 0,
    maestro_reviews: 0,
    maestro_agreed: 0,
    maestro_overridden: 0,
    maestro_skipped: 0,
    hook_failed: 0
  }

  @doc """
  Streams the FULL NDJSON file line by line.

  Unparseable lines are skipped and counted; events carrying an `event_id`
  are deduplicated (first occurrence wins).
  """
  @spec read_all_events(Path.t()) :: %{events: [map()], skipped_lines: non_neg_integer()}
  def read_all_events(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(%{events: [], skipped_lines: 0, seen_event_ids: MapSet.new()}, &accumulate_line/2)
      |> then(fn acc -> %{events: Enum.reverse(acc.events), skipped_lines: acc.skipped_lines} end)
    else
      %{events: [], skipped_lines: 0}
    end
  end

  @doc """
  Pure rollup of decoded events into per-day and per-issue aggregates.
  """
  @spec rollup([map()]) :: %{per_day: [map()], per_issue: %{optional(String.t()) => map()}, totals: map()}
  def rollup(events) do
    run_starts = Analytics.run_started_entries(events)
    initial = %{days: %{}, active: %{}, issues: %{}, snapshots: %{}, first_published: %{}}
    acc = Enum.reduce(events, initial, &accumulate_event(&1, &2, run_starts))

    per_day = finalize_days(acc)
    per_issue = finalize_issues(acc.issues)

    %{per_day: per_day, per_issue: per_issue, totals: totals(events, per_day, per_issue)}
  end

  @doc """
  Three north-star series per day: cycle proxy, rework rate, cost per issue.
  """
  @spec north_star(map()) :: [map()]
  def north_star(%{per_day: per_day}) do
    Enum.map(per_day, &day_north_star/1)
  end

  @doc """
  Splits raw NDJSON content at a cutoff date for archiving.

  Lines with a `recorded_at` strictly older than `cutoff_date` go into
  `:archive` (each guaranteed newline-terminated); everything else — newer
  lines and unparseable/undated lines — stays in `:keep` byte-identical.
  """
  @spec split_for_archive(binary(), Date.t()) :: %{archive: binary(), keep: binary(), archived_count: non_neg_integer()}
  def split_for_archive(content, cutoff_date) do
    {archive_lines, keep_lines} =
      content
      |> raw_lines()
      |> Enum.split_with(&archivable_line?(&1, cutoff_date))

    %{
      archive: archive_lines |> Enum.map(&ensure_trailing_newline/1) |> IO.iodata_to_binary(),
      keep: IO.iodata_to_binary(keep_lines),
      archived_count: length(archive_lines)
    }
  end

  defp accumulate_line(line, acc) do
    case String.trim(line) do
      "" -> acc
      trimmed -> decode_line(trimmed, acc)
    end
  end

  defp decode_line(line, acc) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> dedupe_event(event, acc)
      _error -> %{acc | skipped_lines: acc.skipped_lines + 1}
    end
  end

  defp dedupe_event(event, acc) do
    case Map.get(event, "event_id") do
      nil ->
        %{acc | events: [event | acc.events]}

      event_id ->
        if MapSet.member?(acc.seen_event_ids, event_id) do
          acc
        else
          %{acc | events: [event | acc.events], seen_event_ids: MapSet.put(acc.seen_event_ids, event_id)}
        end
    end
  end

  defp accumulate_event(event, acc, run_starts) do
    case event_datetime(event) do
      nil ->
        acc

      datetime ->
        date = datetime |> DateTime.to_date() |> Date.to_iso8601()

        acc
        |> bump_day_counters(event, date, run_starts)
        |> track_issue(event, date, datetime)
        |> track_tokens(event, date)
    end
  end

  defp bump_day_counters(acc, %{"event_type" => "maestro_review"} = event, date, run_starts) do
    verdict = Analytics.maestro_verdict(event, Analytics.next_run_state(event, run_starts))
    update_day(acc, date, fn day -> day |> Map.update!(:maestro_reviews, &(&1 + 1)) |> bump_maestro_verdict(verdict) end)
  end

  defp bump_day_counters(acc, event, date, _run_starts) do
    update_day(acc, date, &apply_event_to_day(&1, Map.get(event, "event_type"), event))
  end

  defp bump_maestro_verdict(day, :agreed), do: Map.update!(day, :maestro_agreed, &(&1 + 1))
  defp bump_maestro_verdict(day, :overridden), do: Map.update!(day, :maestro_overridden, &(&1 + 1))
  defp bump_maestro_verdict(day, _verdict), do: day

  defp apply_event_to_day(day, "run_started", _event), do: %{day | runs_started: day.runs_started + 1}

  defp apply_event_to_day(day, "run_completed", event) do
    state = Map.get(event, "state") || "unknown"
    %{day | runs_completed: day.runs_completed + 1, completed_by_state: Map.update(day.completed_by_state, state, 1, &(&1 + 1))}
  end

  defp apply_event_to_day(day, "phase_published", _event), do: %{day | phase_published: day.phase_published + 1}
  defp apply_event_to_day(day, "phase_approved", _event), do: %{day | phase_approved: day.phase_approved + 1}
  defp apply_event_to_day(day, "phase_auto_advanced", _event), do: %{day | phase_auto_advanced: day.phase_auto_advanced + 1}
  defp apply_event_to_day(day, "phase_reworked", _event), do: %{day | phase_reworked: day.phase_reworked + 1}
  defp apply_event_to_day(day, "phase_rollback", _event), do: %{day | phase_rollback: day.phase_rollback + 1}
  defp apply_event_to_day(day, "maestro_skipped", _event), do: %{day | maestro_skipped: day.maestro_skipped + 1}
  defp apply_event_to_day(day, "hook_failed", _event), do: %{day | hook_failed: day.hook_failed + 1}
  defp apply_event_to_day(day, _event_type, _event), do: day

  defp update_day(acc, date, fun) do
    %{acc | days: Map.update(acc.days, date, fun.(@empty_day), fun)}
  end

  defp track_issue(acc, event, date, datetime) do
    case Map.get(event, "issue_identifier") do
      identifier when is_binary(identifier) and identifier != "" ->
        event_type = Map.get(event, "event_type")

        acc
        |> mark_active(date, identifier)
        |> upsert_issue(identifier, datetime, event_type)
        |> track_first_published(identifier, date, event_type)

      _missing ->
        acc
    end
  end

  defp mark_active(acc, date, identifier) do
    %{acc | active: Map.update(acc.active, date, MapSet.new([identifier]), &MapSet.put(&1, identifier))}
  end

  defp upsert_issue(acc, identifier, datetime, event_type) do
    issue =
      acc.issues
      |> Map.get(identifier, new_issue(datetime))
      |> merge_seen(datetime)
      |> bump_issue(event_type)

    %{acc | issues: Map.put(acc.issues, identifier, issue)}
  end

  defp new_issue(datetime) do
    %{first_seen: datetime, last_seen: datetime, runs: 0, tokens_total: 0, rework_rounds: 0, phases_published: 0}
  end

  defp merge_seen(issue, datetime) do
    %{issue | first_seen: min_datetime(issue.first_seen, datetime), last_seen: max_datetime(issue.last_seen, datetime)}
  end

  defp bump_issue(issue, "run_started"), do: %{issue | runs: issue.runs + 1}
  defp bump_issue(issue, "phase_published"), do: %{issue | phases_published: issue.phases_published + 1}
  defp bump_issue(issue, event_type) when event_type in ["phase_reworked", "phase_rollback"], do: %{issue | rework_rounds: issue.rework_rounds + 1}
  defp bump_issue(issue, _event_type), do: issue

  defp track_first_published(acc, identifier, date, "phase_published") do
    %{acc | first_published: Map.update(acc.first_published, identifier, date, &min(&1, date))}
  end

  defp track_first_published(acc, _identifier, _date, _event_type), do: acc

  defp track_tokens(acc, %{"tokens" => tokens} = event, date) when is_map(tokens) do
    key = run_key(event)
    snapshot = token_snapshot(tokens)
    previous = Map.get(acc.snapshots, key, @empty_tokens)
    delta = Map.new(snapshot, fn {field, value} -> {field, max(value - Map.fetch!(previous, field), 0)} end)
    high_water = Map.new(snapshot, fn {field, value} -> {field, max(value, Map.fetch!(previous, field))} end)

    %{acc | snapshots: Map.put(acc.snapshots, key, high_water)}
    |> update_day(date, fn day -> %{day | tokens: add_tokens(day.tokens, delta)} end)
    |> add_issue_tokens(Map.get(event, "issue_identifier"), delta.total)
  end

  defp track_tokens(acc, _event, _date), do: acc

  defp add_issue_tokens(acc, identifier, delta_total) do
    case acc.issues do
      %{^identifier => issue} ->
        %{acc | issues: Map.put(acc.issues, identifier, %{issue | tokens_total: issue.tokens_total + delta_total})}

      _issues ->
        acc
    end
  end

  defp token_snapshot(tokens) do
    %{
      total: int_of(Map.get(tokens, "total_tokens")),
      input: int_of(Map.get(tokens, "input_tokens")),
      output: int_of(Map.get(tokens, "output_tokens")),
      cached_input: int_of(Map.get(tokens, "cached_input_tokens"))
    }
  end

  defp add_tokens(tokens, delta) do
    Map.new(tokens, fn {field, value} -> {field, value + Map.fetch!(delta, field)} end)
  end

  defp run_key(event) do
    Map.get(event, "run_id") || "#{Map.get(event, "issue_id", "unknown")}:#{Map.get(event, "attempt", 0)}"
  end

  defp finalize_days(acc) do
    acc.days
    |> Enum.map(fn {date, day} -> finalize_day(date, day, acc) end)
    |> Enum.sort_by(& &1.date)
  end

  defp finalize_day(date, day, acc) do
    day
    |> Map.put(:date, date)
    |> Map.put(:active_issues, acc.active |> Map.get(date, MapSet.new()) |> MapSet.size())
    |> Map.put(:issues_first_published, Enum.count(acc.first_published, fn {_identifier, first_date} -> first_date == date end))
  end

  defp finalize_issues(issues) do
    Map.new(issues, fn {identifier, issue} -> {identifier, finalize_issue(issue)} end)
  end

  defp finalize_issue(issue) do
    %{issue | first_seen: DateTime.to_iso8601(issue.first_seen), last_seen: DateTime.to_iso8601(issue.last_seen)}
  end

  defp totals(events, per_day, per_issue) do
    base = @empty_day |> Map.take(@count_keys) |> Map.put(:tokens, @empty_tokens)

    per_day
    |> Enum.reduce(base, &add_day_to_totals/2)
    |> Map.merge(%{events: length(events), days: length(per_day), issues: map_size(per_issue)})
  end

  defp add_day_to_totals(day, totals) do
    @count_keys
    |> Enum.reduce(totals, fn key, acc -> Map.update!(acc, key, &(&1 + Map.fetch!(day, key))) end)
    |> Map.update!(:tokens, &add_tokens(&1, day.tokens))
  end

  defp day_north_star(day) do
    %{
      date: day.date,
      cycle: %{issues_first_published: day.issues_first_published, runs_completed: day.runs_completed},
      rework_rate: percent_share(day.phase_reworked + day.phase_rollback, day.phase_published),
      cost_per_issue: cost_per_issue(day.tokens.total, day.active_issues)
    }
  end

  defp percent_share(_numerator, denominator) when denominator <= 0, do: "n/a"
  defp percent_share(numerator, denominator), do: "#{Float.round(numerator / denominator * 100, 1)}%"

  defp cost_per_issue(_tokens_total, 0), do: "n/a"
  defp cost_per_issue(tokens_total, active_issues), do: round(tokens_total / active_issues)

  # Backfilled events carry the REAL time in occurred_at and the backfill
  # time in recorded_at; day bucketing prefers the real time. This is the
  # single time axis for analytics — window filtering in Analytics reuses it.
  @doc false
  @spec event_datetime(map()) :: DateTime.t() | nil
  def event_datetime(event) do
    parse_datetime(Map.get(event, "occurred_at")) || parse_datetime(Map.get(event, "recorded_at"))
  end

  # The finalized per-day shape with every counter at zero — the canonical
  # source for densified gap days so the key set cannot drift.
  @doc false
  @spec empty_day() :: map()
  def empty_day do
    Map.merge(@empty_day, %{active_issues: 0, issues_first_published: 0})
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp min_datetime(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
  defp max_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp int_of(value) when is_integer(value), do: value
  defp int_of(value) when is_float(value), do: trunc(value)
  defp int_of(_value), do: 0

  defp raw_lines(content) do
    {complete, [last]} =
      content
      |> :binary.split("\n", [:global])
      |> Enum.split(-1)

    lines = Enum.map(complete, &(&1 <> "\n"))
    if last == "", do: lines, else: lines ++ [last]
  end

  defp archivable_line?(raw_line, cutoff_date) do
    with {:ok, event} when is_map(event) <- Jason.decode(raw_line),
         %DateTime{} = datetime <- parse_datetime(Map.get(event, "recorded_at")) do
      Date.compare(DateTime.to_date(datetime), cutoff_date) == :lt
    else
      _keep -> false
    end
  end

  defp ensure_trailing_newline(raw_line) do
    if String.ends_with?(raw_line, "\n"), do: raw_line, else: raw_line <> "\n"
  end
end
