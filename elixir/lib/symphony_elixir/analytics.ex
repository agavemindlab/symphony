defmodule SymphonyElixir.Analytics do
  @moduledoc """
  Durable, best-effort analytics event storage and v1 dashboard summaries.
  """

  require Logger

  alias SymphonyElixir.{Config, LogFile}

  @default_max_events 500
  @read_chunk_bytes 65_536
  @lock_retry_ms 10
  @lock_timeout_ms 5_000

  @type event :: map()
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

    event
    |> normalize_event(recorded_at)
    |> Jason.encode()
    |> case do
      {:ok, json} ->
        write_event_line(path, json, lock_timeout_ms)

      {:error, reason} ->
        Logger.warning("Skipping analytics event that cannot be encoded: #{inspect(reason)}")
        :ok
    end
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
    metrics = runtime_metrics(events)

    %{
      event_sample_count: length(events),
      panels: panels(metrics),
      data_quality: data_quality(warnings, truncated?),
      warnings: warnings,
      truncated?: truncated?
    }
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

  defp runtime_metrics(events) do
    events = dedupe_events_by_event_id(events)
    token_totals = token_totals(events)
    maestro_metrics = maestro_metrics(events)

    %{
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
      maestro_skipped_count: count_events(events, "maestro_skipped"),
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

  defp panels(metrics) do
    [
      %{
        id: "delivery_cycle",
        title: "Delivery Cycle",
        question: "Can accepted issues move faster with the current persisted signals?",
        status: "partial",
        metrics: [
          metric("Runtime-backed runs", metrics.run_count, "partial"),
          metric("Completed runs", metrics.completed_count, "partial")
        ]
      },
      %{
        id: "autonomy_funnel",
        title: "Autonomy Funnel",
        question: "How often does Symphony advance without human intervention?",
        status: "partial",
        metrics: [
          metric("Phases published", metrics.phase_published_count, "direct"),
          metric("Human approvals", metrics.phase_approved_count, "direct"),
          metric("Auto-advances", metrics.phase_auto_advanced_count, "direct"),
          metric("Auto-advance rate", auto_advance_rate(metrics), "direct"),
          metric("Rework rounds", rework_rounds(metrics), "direct"),
          metric("Human touch count", "Linear comments required", "gap")
        ]
      },
      %{
        id: "quality_rework",
        title: "Quality / Rework",
        question: "How much accepted work comes back as rework or PR/CI failure?",
        status: "partial",
        metrics: [
          metric("Rework rate", rework_rate(metrics), "partial"),
          metric("Maestro reviews", metrics.maestro_review_count, "direct"),
          metric("Maestro agreement rate", maestro_agreement_rate(metrics), "direct"),
          metric("Maestro overridden", metrics.maestro_overridden, "direct"),
          metric("PR review quality", "GitHub review/CI data gap", "gap")
        ]
      },
      %{
        id: "cost_per_accepted_issue",
        title: "Cost Per Accepted Issue",
        question: "What token and runtime cost is attached to accepted issues?",
        status: "direct",
        metrics: [
          metric("Runtime seconds", metrics.runtime_seconds, "partial"),
          metric("Total tokens", metrics.total_tokens, "partial"),
          metric("Input tokens", metrics.input_tokens, "partial"),
          metric("Output tokens", metrics.output_tokens, "partial"),
          metric("Cached input tokens", metrics.cached_input_tokens, "partial"),
          metric("Cache hit share", cache_hit_share(metrics.cached_input_tokens, metrics.input_tokens), "partial")
        ]
      },
      %{
        id: "capacity_reliability",
        title: "Capacity / Reliability",
        question: "Where do retries, blockers, or capacity pressure stall throughput?",
        status: "direct",
        metrics: capacity_metrics(metrics)
      },
      %{
        id: "data_quality_exclusions",
        title: "Data Quality / Exclusions",
        question: "Which signals are safe to use, and which are only gaps?",
        status: "direct",
        metrics: [
          metric("Direct sources", 1, "direct"),
          metric("Partial sources", 1, "partial"),
          metric("Gap sources", 2, "gap")
        ]
      }
    ]
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

    events
    |> Enum.filter(&(Map.get(&1, "event_type") == "maestro_review"))
    |> Enum.reduce(%{review_count: 0, agreed: 0, overridden: 0, pending: 0}, fn review, acc ->
      acc
      |> Map.update!(:review_count, &(&1 + 1))
      |> tally_maestro_verdict(maestro_verdict(review, next_run_state(review, run_starts)))
    end)
  end

  defp tally_maestro_verdict(acc, :excluded), do: acc
  defp tally_maestro_verdict(acc, verdict), do: Map.update!(acc, verdict, &(&1 + 1))

  @doc """
  Classifies whether the human verdict (the state of the next `run_started`
  dispatch for the issue, or `nil` when none exists yet) agreed with a
  `maestro_review` event's recommendation.
  """
  @spec maestro_verdict(map(), String.t() | nil) :: :agreed | :overridden | :pending | :excluded
  def maestro_verdict(review, next_state) when is_map(review) do
    classify_maestro_verdict(Map.get(review, "recommendation"), Map.get(review, "phase"), next_state)
  end

  defp classify_maestro_verdict("request_changes", _phase, "Rework"), do: :agreed
  defp classify_maestro_verdict("request_changes", _phase, next_state) when next_state in ["In Progress", "Merging"], do: :overridden
  defp classify_maestro_verdict("request_changes", _phase, _next_state), do: :pending

  defp classify_maestro_verdict("approve", phase, next_state) when phase in ["Requirements", "Design"] do
    case next_state do
      "In Progress" -> :agreed
      "Rework" -> :overridden
      _next_state -> :pending
    end
  end

  defp classify_maestro_verdict("approve", "Implementation", next_state), do: merge_expectation_verdict(next_state)
  defp classify_maestro_verdict("merge_nudge", _phase, next_state), do: merge_expectation_verdict(next_state)
  defp classify_maestro_verdict(_recommendation, _phase, _next_state), do: :excluded

  defp merge_expectation_verdict("Merging"), do: :agreed
  defp merge_expectation_verdict("Rework"), do: :overridden
  # "In Progress" is ambiguous: the issue may still be awaiting the Merging flip.
  defp merge_expectation_verdict(_next_state), do: :pending

  @doc false
  @spec run_started_entries([map()]) :: [map()]
  def run_started_entries(events) do
    events
    |> Enum.filter(&(Map.get(&1, "event_type") == "run_started"))
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
      metric("Maestro skipped", metrics.maestro_skipped_count, "direct"),
      metric("Hook failures", metrics.hook_failed_count, "direct"),
      metric("Running count", Map.get(latest_capacity, "running_count", 0), "partial"),
      %{
        label: "Effective capacity",
        value: Map.get(latest_capacity, "effective_capacity", Map.get(latest_capacity, "configured_capacity", 0)),
        status: "partial"
      }
    ]
  end

  defp data_quality(warnings, truncated?) do
    gaps =
      [
        "GitHub review/CI data is not configured in v1",
        "Linear phase metrics require collector availability"
      ] ++ if(truncated?, do: ["Analytics event file was truncated to the latest window"], else: [])

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
