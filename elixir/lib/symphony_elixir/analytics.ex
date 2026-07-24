defmodule SymphonyElixir.Analytics do
  @moduledoc """
  Durable, best-effort analytics event storage and v1 dashboard summaries.
  """

  require Logger

  alias SymphonyElixir.{AnalyticsRollup, Config, LogFile}

  @default_max_events 500
  @read_chunk_bytes 65_536
  @lock_retry_ms 10
  @lock_timeout_ms 5_000

  @windows [:h24, :d7, :d30, :all]
  @convergence_recommendations ["continue_implementation", "rework_design"]
  @valid_phases ["Requirements", "Design", "Implementation", "Deployment"]

  @type event :: map()
  @type window :: :h24 | :d7 | :d30 | :all
  @type history :: %{events: [map()], skipped_lines: non_neg_integer()}
  @type read_result :: %{
          events: [map()],
          warnings: [String.t()],
          truncated?: boolean()
        }

  @spec record_event(event(), keyword()) :: :ok
  def record_event(event, opts \\ []) when is_map(event) do
    path = Keyword.get(opts, :path, file_path())
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now())
    lock_timeout_ms = Keyword.get(opts, :lock_timeout_ms, @lock_timeout_ms)
    normalized = normalize_event(event, recorded_at)

    if before_analytics_epoch?(normalized) do
      :ok
    else
      case Jason.encode(normalized) do
        {:ok, json} ->
          write_event_line(path, json, lock_timeout_ms)

        {:error, reason} ->
          Logger.warning("Skipping analytics event that cannot be encoded: #{inspect(reason)}")
          :ok
      end
    end
  end

  # Write-time floor: backfill and the comment scanner sweep FULL comment/PR
  # histories, so a one-time store cleanup would not stick — pre-era events
  # would be re-appended on the next sweep. Dropping them at the single write
  # choke point keeps the store's time axis anchored at the configured epoch.
  defp before_analytics_epoch?(event) do
    with %Date{} = epoch <- Config.analytics_epoch(),
         %DateTime{} = at <- event_time_axis(event) do
      Date.compare(DateTime.to_date(at), epoch) == :lt
    else
      _no_epoch_or_undatable -> false
    end
  end

  defp event_time_axis(event) do
    [:occurred_at, "occurred_at", :recorded_at, "recorded_at"]
    |> Enum.find_value(fn key ->
      case Map.get(event, key) do
        %DateTime{} = at -> at
        value when is_binary(value) -> parse_datetime(value)
        _other -> nil
      end
    end)
  end

  @spec read_events(keyword()) :: read_result()
  def read_events(opts \\ []) do
    path = Keyword.get(opts, :path, file_path())
    max_events = Keyword.get(opts, :max_events, @default_max_events)

    with true <- File.regular?(path),
         {:ok, indexed_lines} <- read_event_lines(path, max_events) do
      decode_event_lines(indexed_lines)
    else
      false ->
        %{events: [], warnings: [], truncated?: false}

      {:error, reason} ->
        %{
          events: [],
          warnings: ["analytics event file unavailable: #{inspect(reason)}"],
          truncated?: false
        }
    end
  end

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    %{events: events, warnings: warnings, truncated?: truncated?} = read_events(opts)
    build_summary(events, warnings, truncated?, nil, store_presence(events))
  end

  @doc """
  Full-history dashboard report for one time window.

  Merges every archive plus the live file (`read_full_history/1`), rolls the
  FULL deduplicated event list up ONCE via `AnalyticsRollup.rollup/1`, then
  slices per-day history and derives the windowed summary from the slice.
  Callers that already hold a pre-read history and rollup (see
  `SymphonyElixir.AnalyticsCache`) can inject them via `:history` / `:rollup`;
  `:now` overrides the cutoff clock and `:path` the live-file location.
  """
  @spec window_report(window(), keyword()) :: map()
  def window_report(window, opts \\ []) when window in @windows do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    history = Keyword.get_lazy(opts, :history, fn -> read_full_history(opts) end)
    rollup = Keyword.get_lazy(opts, :rollup, fn -> AnalyticsRollup.rollup(history.events) end)

    cutoff = window_cutoff(window, now)
    events = filter_window_events(history.events, cutoff)
    per_day = rollup.per_day |> slice_per_day(cutoff) |> densify_per_day()
    warnings = skipped_line_warnings(history.skipped_lines)

    %{
      window: window,
      summary: build_summary(events, warnings, false, window_token_totals(per_day), store_presence(history.events)),
      history: %{per_day: per_day, north_star: AnalyticsRollup.north_star(%{per_day: per_day})}
    }
  end

  @doc """
  Reads the full event history: every sibling `archive-*.ndjson` file
  (lexicographic order = chronological) followed by the live file, with
  events deduplicated by `event_id` across files (first occurrence wins).
  """
  @spec read_full_history(keyword()) :: history()
  def read_full_history(opts \\ []) do
    path = Keyword.get(opts, :path, file_path())
    merge_history(Enum.map(archive_paths(path) ++ [path], &AnalyticsRollup.read_all_events/1))
  end

  @doc false
  @spec archive_paths(Path.t()) :: [Path.t()]
  def archive_paths(live_path) do
    live_path |> Path.dirname() |> Path.join("archive-*.ndjson") |> Path.wildcard() |> Enum.sort()
  end

  @doc false
  @spec merge_history([history()]) :: history()
  def merge_history(reads) do
    %{
      events: reads |> Enum.flat_map(& &1.events) |> dedupe_events_by_event_id(),
      skipped_lines: reads |> Enum.map(& &1.skipped_lines) |> Enum.sum()
    }
  end

  # `presence` reflects the FULL store (window_report threads the complete
  # history through), so gap rows only appear when a collector never ran —
  # a zero inside one window still renders as a real 0.
  defp build_summary(events, warnings, truncated?, token_totals_override, presence) do
    metrics = runtime_metrics(events, token_totals_override)

    %{
      event_sample_count: length(events),
      window_started_at: window_timestamp(List.first(events)),
      window_ended_at: window_timestamp(List.last(events)),
      panels: panels(metrics, presence),
      data_quality: data_quality(warnings, truncated?, presence),
      warnings: warnings,
      truncated?: truncated?
    }
  end

  defp store_presence(events) do
    %{
      human_comment?: Enum.any?(events, &(Map.get(&1, "event_type") == "human_comment")),
      pr_merged?: Enum.any?(events, &(Map.get(&1, "event_type") == "pr_merged"))
    }
  end

  defp window_cutoff(:all, _now), do: nil
  defp window_cutoff(:h24, now), do: DateTime.add(now, -24, :hour)
  defp window_cutoff(:d7, now), do: DateTime.add(now, -7, :day)
  defp window_cutoff(:d30, now), do: DateTime.add(now, -30, :day)

  # :all keeps events with missing/garbage timestamps (they count toward the
  # full-history totals); bounded windows drop them — they cannot be placed.
  # Filtering MUST use the same time axis as AnalyticsRollup's day bucketing
  # (occurred_at || recorded_at), or backfilled events land in the summary of
  # a window whose history excludes them.
  defp filter_window_events(events, nil), do: events

  defp filter_window_events(events, cutoff) do
    Enum.filter(events, fn event ->
      case AnalyticsRollup.event_datetime(event) do
        nil -> false
        at -> DateTime.compare(at, cutoff) != :lt
      end
    end)
  end

  defp slice_per_day(per_day, nil), do: per_day

  defp slice_per_day(per_day, cutoff) do
    cutoff_date = DateTime.to_date(cutoff)
    Enum.filter(per_day, &(Date.compare(Date.from_iso8601!(&1.date), cutoff_date) != :lt))
  end

  defp densify_per_day([]), do: []

  defp densify_per_day(per_day) do
    by_date = Map.new(per_day, &{&1.date, &1})
    first = Date.from_iso8601!(hd(per_day).date)
    last = Date.from_iso8601!(List.last(per_day).date)

    Enum.map(Date.range(first, last), fn date ->
      iso = Date.to_iso8601(date)
      Map.get(by_date, iso, Map.put(AnalyticsRollup.empty_day(), :date, iso))
    end)
  end

  # Windowed token metrics MUST be the sum of the sliced per-day deltas.
  # Re-running the last-snapshot-per-run accounting over cutoff-filtered
  # events would lose the per-run baseline that AnalyticsRollup.rollup/1
  # keeps and book a run's full cumulative tokens into the window whenever
  # the run was already alive at the cutoff. Consequence: bounded windows are
  # UTC-calendar-day granular for token metrics — the whole cutoff day is
  # included, up to ~24h before the exact cutoff instant.
  defp window_token_totals(per_day) do
    Enum.reduce(
      per_day,
      %{total_tokens: 0, input_tokens: 0, output_tokens: 0, cached_input_tokens: 0},
      fn day, totals ->
        %{
          total_tokens: totals.total_tokens + day.tokens.total,
          input_tokens: totals.input_tokens + day.tokens.input,
          output_tokens: totals.output_tokens + day.tokens.output,
          cached_input_tokens: totals.cached_input_tokens + day.tokens.cached_input
        }
      end
    )
  end

  defp skipped_line_warnings(0), do: []
  defp skipped_line_warnings(count), do: ["skipped #{count} malformed analytics event line(s)"]

  defp window_timestamp(nil), do: nil

  defp window_timestamp(event) do
    case AnalyticsRollup.event_datetime(event) do
      nil -> nil
      datetime -> datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  @spec file_path() :: Path.t()
  def file_path do
    Application.get_env(:symphony_elixir, :analytics_file) ||
      configured_file_path() ||
      default_file_path()
  end

  defp configured_file_path do
    with {:ok, settings} <- Config.settings(),
         path when is_binary(path) and path != "" <- settings.observability.analytics_path do
      path
    else
      _ -> nil
    end
  end

  defp default_file_path do
    Path.join(
      Path.dirname(Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())),
      "symphony-analytics.ndjson"
    )
  end

  defp normalize_event(event, recorded_at) do
    event
    |> Map.put_new(:recorded_at, iso8601(recorded_at))
    |> stringify_event_type()
  end

  defp stringify_event_type(%{event_type: event_type} = event) when is_atom(event_type) do
    %{event | event_type: Atom.to_string(event_type)}
  end

  defp stringify_event_type(event), do: event

  defp write_event_line(path, json, lock_timeout_ms) when is_binary(path) and is_binary(json) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok ->
        with_event_file_lock(path, lock_timeout_ms, fn -> append_event_line(path, json) end)

      {:error, reason} ->
        Logger.warning("Failed to create analytics directory: #{inspect(reason)}")
        :ok
    end
  end

  defp append_event_line(path, json) do
    case File.write(path, json <> "\n", [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write analytics event: #{inspect(reason)}")
        :ok
    end
  end

  defp with_event_file_lock(path, lock_timeout_ms, fun) do
    lock_path = path <> ".lock"
    deadline_ms = System.monotonic_time(:millisecond) + normalize_lock_timeout_ms(lock_timeout_ms)
    acquire_event_file_lock(lock_path, deadline_ms, fun)
  end

  defp normalize_lock_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0, do: timeout_ms
  defp normalize_lock_timeout_ms(_timeout_ms), do: @lock_timeout_ms

  defp acquire_event_file_lock(lock_path, deadline_ms, fun) do
    case File.mkdir(lock_path) do
      :ok ->
        try do
          fun.()
        after
          release_event_file_lock(lock_path)
        end

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          Logger.warning("Failed to acquire analytics event file lock: timed out")
          :ok
        else
          Process.sleep(@lock_retry_ms)
          acquire_event_file_lock(lock_path, deadline_ms, fun)
        end
    end
  end

  defp release_event_file_lock(lock_path) do
    File.rmdir(lock_path)
    :ok
  end

  defp read_event_lines(path, max_events) when is_integer(max_events) and max_events > 0 do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        read_latest_event_lines(file, max_events)
      after
        :file.close(file)
      end
    end
  end

  defp read_event_lines(path, _max_events) do
    with {:ok, content} <- File.read(path) do
      content
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> then(&{:ok, {&1, false}})
    end
  end

  defp read_latest_event_lines(file, max_events) do
    with {:ok, size} <- :file.position(file, :eof) do
      read_latest_event_lines(file, size, "", max_events)
    end
  end

  defp read_latest_event_lines(_file, 0, content, _max_events) do
    content
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> then(&{:ok, {&1, false}})
  end

  defp read_latest_event_lines(file, offset, content, max_events) do
    chunk_size = min(@read_chunk_bytes, offset)
    next_offset = offset - chunk_size

    with {:ok, chunk} <- :file.pread(file, next_offset, chunk_size) do
      content = chunk <> content
      lines = String.split(content, "\n", trim: true)

      if length(lines) > max_events do
        lines
        |> Enum.take(-max_events)
        |> Enum.with_index(1)
        |> then(&{:ok, {&1, true}})
      else
        read_latest_event_lines(file, next_offset, content, max_events)
      end
    end
  end

  defp decode_event_lines({indexed_lines, truncated?}) do
    {events, warnings} =
      Enum.reduce(indexed_lines, {[], []}, fn {line, line_number}, {events, warnings} ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) ->
            {[event | events], warnings}

          _ ->
            {events, ["skipped malformed analytics event line #{line_number}" | warnings]}
        end
      end)

    %{
      events: Enum.reverse(events),
      warnings: Enum.reverse(warnings),
      truncated?: truncated?
    }
  end

  defp runtime_metrics(events, token_totals_override) do
    events = dedupe_events_by_event_id(events)
    token_totals = token_totals_override || token_totals(events)
    maestro_metrics = maestro_metrics(events)
    merged_prs = Enum.filter(events, &(Map.get(&1, "event_type") == "pr_merged"))

    %{
      human_comment_count: count_events(events, "human_comment"),
      pr_merged_count: length(merged_prs),
      pr_changes_requested_count: Enum.count(merged_prs, &(Map.get(&1, "changes_requested") == true)),
      pr_unreviewed_count: Enum.count(merged_prs, &(integer_value(Map.get(&1, "reviews_count")) == 0)),
      run_count: count_events(events, "run_started"),
      phase_published_count: count_events(events, "phase_published"),
      phase_approved_count: count_events(events, "phase_approved"),
      phase_auto_advanced_count: count_events(events, "phase_auto_advanced"),
      phase_reworked_count: count_events(events, "phase_reworked"),
      phase_rollback_count: count_events(events, "phase_rollback"),
      maestro_review_count: maestro_metrics.review_count,
      maestro_agreed: maestro_metrics.agreed,
      maestro_overridden: maestro_metrics.overridden,
      maestro_pending: maestro_metrics.pending,
      hook_failed_count: count_events(events, "hook_failed"),
      completed_count: count_events(events, "run_completed"),
      retry_count: count_events(events, "retry_scheduled"),
      blocked_count: count_events(events, "blocked"),
      total_tokens: token_totals.total_tokens,
      input_tokens: token_totals.input_tokens,
      output_tokens: token_totals.output_tokens,
      cached_input_tokens: token_totals.cached_input_tokens,
      runtime_seconds: sum_integer(events, "runtime_seconds"),
      latest_capacity: latest_event(events, "capacity_snapshot")
    }
  end

  defp panels(metrics, presence) do
    [
      panel(
        "delivery_cycle",
        "Delivery Cycle",
        "Can accepted issues move faster with the current persisted signals?",
        [
          metric("Runtime-backed runs", metrics.run_count, "partial"),
          metric("Completed runs", metrics.completed_count, "partial")
        ]
      ),
      panel(
        "autonomy_funnel",
        "Autonomy Funnel",
        "How often does Symphony advance without human intervention?",
        [
          metric("Phases published", metrics.phase_published_count, "direct"),
          metric("Human approvals", metrics.phase_approved_count, "direct"),
          metric("Auto-advances", metrics.phase_auto_advanced_count, "direct"),
          metric("Auto-advance rate", auto_advance_rate(metrics), "direct"),
          metric("Rework rounds", rework_rounds(metrics), "direct"),
          human_touch_metric(metrics, presence)
        ]
      ),
      panel(
        "quality_rework",
        "Quality / Rework",
        "How much accepted work comes back as rework or PR/CI failure?",
        [
          metric("Rework rate", rework_rate(metrics), "partial"),
          metric("Maestro reviews", metrics.maestro_review_count, "direct"),
          metric("Maestro agreement rate", maestro_agreement_rate(metrics), "direct"),
          metric("Maestro overridden", metrics.maestro_overridden, "direct")
        ] ++ pr_review_metrics(metrics, presence)
      ),
      panel(
        "cost_per_accepted_issue",
        "Cost Per Accepted Issue",
        "What token and runtime cost is attached to accepted issues?",
        [
          metric("Runtime seconds", metrics.runtime_seconds, "partial"),
          metric("Total tokens", metrics.total_tokens, "partial"),
          metric("Input tokens", metrics.input_tokens, "partial"),
          metric("Output tokens", metrics.output_tokens, "partial"),
          metric("Cached input tokens", metrics.cached_input_tokens, "partial"),
          metric("Cache hit share", cache_hit_share(metrics.cached_input_tokens, metrics.input_tokens), "partial")
        ]
      ),
      panel(
        "capacity_reliability",
        "Capacity / Reliability",
        "Where do retries, blockers, or capacity pressure stall throughput?",
        capacity_metrics(metrics)
      )
    ]
  end

  defp panel(id, title, question, metrics) do
    %{id: id, title: title, question: question, status: panel_status(metrics), metrics: metrics}
  end

  # Panel status is the most common status among its metrics; ties break
  # toward the weakest signal (gap < partial < direct).
  @status_strength %{"gap" => 0, "partial" => 1, "direct" => 2}

  defp panel_status(metrics) do
    metrics
    |> Enum.frequencies_by(& &1.status)
    |> Enum.max_by(fn {status, count} -> {count, -Map.fetch!(@status_strength, status)} end)
    |> elem(0)
  end

  defp human_touch_metric(metrics, %{human_comment?: true}) do
    metric("Human touch count", metrics.human_comment_count, "partial")
  end

  defp human_touch_metric(_metrics, _presence) do
    metric("Human touch count", "run mix symphony.events.backfill", "gap")
  end

  defp pr_review_metrics(metrics, %{pr_merged?: true}) do
    [
      metric("Merged PRs", metrics.pr_merged_count, "partial"),
      metric("Changes-requested rate", percent_share(metrics.pr_changes_requested_count, metrics.pr_merged_count), "partial"),
      metric("Unreviewed merge share", percent_share(metrics.pr_unreviewed_count, metrics.pr_merged_count), "partial")
    ]
  end

  defp pr_review_metrics(_metrics, _presence) do
    [metric("PR review quality", "run mix symphony.events.github", "gap")]
  end

  defp metric(label, value, status), do: %{label: label, value: value, status: status}

  defp cache_hit_share(_cached_input_tokens, input_tokens) when input_tokens <= 0, do: "n/a"

  defp cache_hit_share(cached_input_tokens, input_tokens) do
    "#{Float.round(cached_input_tokens / input_tokens * 100, 1)}%"
  end

  defp auto_advance_rate(metrics) do
    percent_share(metrics.phase_auto_advanced_count, metrics.phase_approved_count + metrics.phase_auto_advanced_count)
  end

  defp rework_rounds(metrics) do
    metrics.phase_reworked_count + metrics.phase_rollback_count
  end

  defp rework_rate(metrics) do
    percent_share(rework_rounds(metrics), metrics.phase_published_count)
  end

  defp maestro_agreement_rate(metrics) do
    percent_share(metrics.maestro_agreed, metrics.maestro_agreed + metrics.maestro_overridden)
  end

  defp maestro_metrics(events) do
    run_starts = run_started_entries(events)
    reviews = Enum.filter(events, &(Map.get(&1, "event_type") == "maestro_review"))

    phase_outcomes =
      if Enum.any?(reviews, &convergence_review?/1), do: phase_outcome_entries(events), else: []

    Enum.reduce(reviews, %{review_count: 0, agreed: 0, overridden: 0, pending: 0}, fn review, acc ->
      outcome = if convergence_review?(review), do: next_phase_outcome(review, phase_outcomes, reviews)
      verdict = maestro_verdict(review, next_run_state(review, run_starts), outcome)

      acc
      |> Map.update!(:review_count, &(&1 + 1))
      |> tally_maestro_verdict(verdict)
    end)
  end

  defp tally_maestro_verdict(acc, :excluded), do: acc
  defp tally_maestro_verdict(acc, verdict), do: Map.update!(acc, verdict, &(&1 + 1))

  @doc """
  Classifies whether the next observed human route agreed with a
  `maestro_review` event's recommendation. Ordinary recommendations use the
  next dispatch state; convergence recommendations require a phase outcome.
  """
  @spec maestro_verdict(map(), String.t() | nil) :: :agreed | :overridden | :pending | :excluded
  def maestro_verdict(review, next_state) when is_map(review) do
    maestro_verdict(review, next_state, nil)
  end

  @doc false
  @spec maestro_verdict(map(), String.t() | nil, map() | nil) :: :agreed | :overridden | :pending | :excluded
  def maestro_verdict(review, next_state, phase_outcome) when is_map(review) do
    classify_maestro_verdict(
      Map.get(review, "recommendation"),
      Map.get(review, "phase"),
      next_state,
      phase_outcome
    )
  end

  defp classify_maestro_verdict("continue_implementation", _phase, next_state, outcome),
    do: convergence_verdict("Implementation", next_state, outcome)

  defp classify_maestro_verdict("rework_design", _phase, next_state, outcome),
    do: convergence_verdict("Design", next_state, outcome)

  defp classify_maestro_verdict("request_changes", _phase, "Rework", _outcome), do: :agreed

  defp classify_maestro_verdict("request_changes", _phase, next_state, _outcome)
       when next_state in ["In Progress", "Merging"],
       do: :overridden

  defp classify_maestro_verdict("request_changes", _phase, _next_state, _outcome), do: :pending

  defp classify_maestro_verdict("approve", phase, next_state, _outcome) when phase in ["Requirements", "Design"] do
    case next_state do
      "In Progress" -> :agreed
      "Rework" -> :overridden
      _next_state -> :pending
    end
  end

  defp classify_maestro_verdict("approve", "Implementation", next_state, _outcome),
    do: merge_expectation_verdict(next_state)

  defp classify_maestro_verdict("merge_nudge", _phase, next_state, _outcome), do: merge_expectation_verdict(next_state)
  defp classify_maestro_verdict(_recommendation, _phase, _next_state, _outcome), do: :excluded

  defp convergence_verdict(_expected_phase, "Merging", _outcome), do: :overridden
  defp convergence_verdict(expected_phase, _next_state, %{target_phase: expected_phase}), do: :agreed

  defp convergence_verdict(_expected_phase, _next_state, %{target_phase: other_phase})
       when other_phase in @valid_phases,
       do: :overridden

  defp convergence_verdict(_expected_phase, _next_state, _outcome), do: :pending

  defp merge_expectation_verdict("Merging"), do: :agreed
  defp merge_expectation_verdict("Rework"), do: :overridden
  # "In Progress" is ambiguous: the issue may still be awaiting the Merging flip.
  defp merge_expectation_verdict(_next_state), do: :pending

  @doc false
  @spec run_started_entries([map()]) :: [map()]
  def run_started_entries(events) do
    events
    |> Enum.filter(&(Map.get(&1, "event_type") == "run_started"))
    # A dispatch in "Human Review" is the Maestro reviewer instance picking the
    # issue up, not a human verdict — it must not shadow the real next state.
    |> Enum.reject(&(Map.get(&1, "state") == "Human Review"))
    |> Enum.flat_map(fn event ->
      case parse_datetime(Map.get(event, "recorded_at")) do
        nil -> []
        recorded_at -> [%{issue_id: Map.get(event, "issue_id"), recorded_at: recorded_at, state: Map.get(event, "state")}]
      end
    end)
  end

  @doc false
  @spec next_run_state(map(), [map()]) :: String.t() | nil
  def next_run_state(review, run_starts) do
    with issue_id when not is_nil(issue_id) <- Map.get(review, "issue_id"),
         %DateTime{} = reviewed_at <- maestro_reviewed_at(review),
         %{state: state} <-
           run_starts
           |> Enum.filter(&(&1.issue_id == issue_id and DateTime.compare(&1.recorded_at, reviewed_at) == :gt))
           |> Enum.min_by(& &1.recorded_at, DateTime, fn -> nil end) do
      state
    else
      _ -> nil
    end
  end

  @doc false
  @spec convergence_review?(map()) :: boolean()
  def convergence_review?(review), do: Map.get(review, "recommendation") in @convergence_recommendations

  @doc false
  @spec phase_outcome_entries([map()]) :: [map()]
  def phase_outcome_entries(events) do
    events
    |> Enum.filter(&(Map.get(&1, "event_type") in ["phase_published", "phase_rollback"]))
    |> Enum.flat_map(fn event ->
      with target_phase when target_phase in @valid_phases <- outcome_phase(event),
           %DateTime{} = occurred_at <- parse_datetime(Map.get(event, "occurred_at") || Map.get(event, "recorded_at")) do
        [
          %{
            issue_id: Map.get(event, "issue_id"),
            occurred_at: occurred_at,
            target_phase: target_phase,
            event_id: Map.get(event, "event_id")
          }
        ]
      else
        _invalid -> []
      end
    end)
  end

  defp outcome_phase(%{"event_type" => "phase_published"} = event), do: Map.get(event, "phase")
  defp outcome_phase(event), do: Map.get(event, "target_phase")

  @doc false
  @spec next_phase_outcome(map(), [map()], [map()]) :: map() | nil
  def next_phase_outcome(review, phase_outcomes, reviews) do
    with issue_id when not is_nil(issue_id) <- Map.get(review, "issue_id"),
         %DateTime{} = reviewed_at <- maestro_reviewed_at(review) do
      next_reviewed_at =
        reviews
        |> Enum.filter(fn candidate ->
          Map.get(candidate, "issue_id") == issue_id and
            match?(%DateTime{}, maestro_reviewed_at(candidate)) and
            DateTime.compare(maestro_reviewed_at(candidate), reviewed_at) == :gt
        end)
        |> Enum.map(&maestro_reviewed_at/1)
        |> Enum.min(DateTime, fn -> nil end)

      phase_outcomes
      |> Enum.filter(fn outcome ->
        outcome.issue_id == issue_id and DateTime.compare(outcome.occurred_at, reviewed_at) == :gt and
          (is_nil(next_reviewed_at) or DateTime.compare(outcome.occurred_at, next_reviewed_at) == :lt)
      end)
      |> Enum.min_by(& &1.occurred_at, DateTime, fn -> nil end)
    else
      _ -> nil
    end
  end

  defp maestro_reviewed_at(review) do
    parse_datetime(Map.get(review, "occurred_at") || Map.get(review, "recorded_at"))
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp percent_share(_numerator, denominator) when denominator <= 0, do: "n/a"

  defp percent_share(numerator, denominator) do
    "#{Float.round(numerator / denominator * 100, 1)}%"
  end

  defp capacity_metrics(%{latest_capacity: latest_capacity} = metrics) do
    latest_capacity = latest_capacity || %{}

    [
      metric("Retry events", metrics.retry_count, "partial"),
      metric("Blocked events", metrics.blocked_count, "partial"),
      metric("Hook failures", metrics.hook_failed_count, "direct"),
      metric("Running count", Map.get(latest_capacity, "running_count", 0), "partial"),
      %{
        label: "Effective capacity",
        value: Map.get(latest_capacity, "effective_capacity", Map.get(latest_capacity, "configured_capacity", 0)),
        status: "partial"
      }
    ]
  end

  defp data_quality(warnings, truncated?, presence) do
    gaps =
      if(presence.pr_merged?, do: [], else: ["GitHub PR review data not collected yet (run mix symphony.events.github)"]) ++
        if(presence.human_comment?,
          do: [],
          else: ["Linear human comment data not collected yet (run mix symphony.events.backfill)"]
        ) ++
        if(truncated?, do: ["Analytics event file was truncated to the latest window"], else: [])

    %{
      direct: ["Symphony runtime event store"],
      partial: ["Linear issue lifecycle and phase comments"],
      gaps: gaps,
      warnings: warnings
    }
  end

  defp count_events(events, event_type) do
    Enum.count(events, &(Map.get(&1, "event_type") == event_type))
  end

  defp dedupe_events_by_event_id(events) do
    {deduped, _seen} = Enum.reduce(events, {[], MapSet.new()}, &dedupe_event_by_event_id/2)
    Enum.reverse(deduped)
  end

  defp dedupe_event_by_event_id(event, {events, seen_event_ids}) do
    case Map.get(event, "event_id") do
      nil ->
        {[event | events], seen_event_ids}

      event_id ->
        if MapSet.member?(seen_event_ids, event_id) do
          {events, seen_event_ids}
        else
          {[event | events], MapSet.put(seen_event_ids, event_id)}
        end
    end
  end

  defp latest_event(events, event_type) do
    events
    |> Enum.reverse()
    |> Enum.find(&(Map.get(&1, "event_type") == event_type))
  end

  defp token_totals(events) do
    events
    |> Enum.reduce(%{}, fn event, totals_by_run ->
      case token_snapshot(event) do
        nil -> totals_by_run
        snapshot -> Map.put(totals_by_run, token_run_key(event), snapshot)
      end
    end)
    |> Map.values()
    |> Enum.reduce(%{input_tokens: 0, output_tokens: 0, total_tokens: 0, cached_input_tokens: 0}, fn snapshot, totals ->
      %{
        input_tokens: totals.input_tokens + snapshot.input_tokens,
        output_tokens: totals.output_tokens + snapshot.output_tokens,
        total_tokens: totals.total_tokens + snapshot.total_tokens,
        cached_input_tokens: totals.cached_input_tokens + snapshot.cached_input_tokens
      }
    end)
  end

  defp token_snapshot(%{"tokens" => tokens}) when is_map(tokens) do
    %{
      input_tokens: integer_value(Map.get(tokens, "input_tokens")),
      output_tokens: integer_value(Map.get(tokens, "output_tokens")),
      total_tokens: integer_value(Map.get(tokens, "total_tokens")),
      cached_input_tokens: integer_value(Map.get(tokens, "cached_input_tokens"))
    }
  end

  defp token_snapshot(_event), do: nil

  defp token_run_key(event) do
    Map.get(event, "run_id") ||
      "#{Map.get(event, "issue_id", "unknown")}:#{Map.get(event, "attempt", 0)}"
  end

  defp sum_integer(events, key) do
    Enum.reduce(events, 0, fn event, acc ->
      acc + integer_value(Map.get(event, key))
    end)
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)
  defp integer_value(_value), do: 0

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
