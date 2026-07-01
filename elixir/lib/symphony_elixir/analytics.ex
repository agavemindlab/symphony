defmodule SymphonyElixir.Analytics do
  @moduledoc """
  Durable, best-effort analytics event storage and v1 dashboard summaries.
  """

  require Logger

  alias SymphonyElixir.{Config, LogFile}

  @default_max_events 500
  @proof_max_events 5_000
  @read_chunk_bytes 65_536
  @lock_retry_ms 10
  @lock_timeout_ms 5_000
  @outcome_proof_keys %{
    "id" => :id,
    "label" => :label,
    "value" => :value,
    "status" => :status,
    "source" => :source,
    "numerator" => :numerator,
    "denominator" => :denominator,
    "week" => :week,
    "project" => :project,
    "sample_count" => :sample_count,
    "complete_week?" => :complete_week?,
    "truncated?" => :truncated?,
    "direct" => :direct,
    "partial" => :partial,
    "gaps" => :gaps,
    "warnings" => :warnings,
    "reason" => :reason
  }

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
    proof = outcome_proof(opts)
    metrics = runtime_metrics(events)

    %{
      event_sample_count: length(events),
      outcome_proof: proof,
      panels: panels(metrics, proof),
      data_quality: data_quality(warnings, truncated?, proof),
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
    token_totals = token_totals(events)

    %{
      run_count: count_events(events, "run_started"),
      phase_event_count: count_events(events, "phase_event"),
      completed_count: count_events(events, "run_completed"),
      retry_count: count_events(events, "retry_scheduled"),
      blocked_count: count_events(events, "blocked"),
      total_tokens: token_totals.total_tokens,
      input_tokens: token_totals.input_tokens,
      output_tokens: token_totals.output_tokens,
      runtime_seconds: sum_integer(events, "runtime_seconds"),
      latest_capacity: latest_event(events, "capacity_snapshot")
    }
  end

  defp outcome_proof(opts) do
    opts
    |> Keyword.put(:max_events, @proof_max_events)
    |> read_events()
    |> latest_outcome_proof()
  end

  defp latest_outcome_proof(%{events: events, truncated?: truncated?}) do
    events
    |> Enum.reverse()
    |> Enum.find(&(Map.get(&1, "event_type") == "outcome_proof_snapshot"))
    |> case do
      nil ->
        %{
          status: "gap",
          reason: if(truncated?, do: "proof_snapshot_outside_read_window", else: "outcome_proof_snapshot_required")
        }

      snapshot ->
        normalize_outcome_proof_snapshot(snapshot)
    end
  end

  defp normalize_outcome_proof_snapshot(snapshot) when is_map(snapshot) do
    %{
      status: snapshot_status(snapshot),
      collected_at: Map.get(snapshot, "collected_at"),
      accepted_issue_count: integer_value(Map.get(snapshot, "accepted_issue_count")),
      cohorts: atomize_known_maps(Map.get(snapshot, "cohorts", [])),
      baseline: atomize_known_map(Map.get(snapshot, "baseline")),
      latest: atomize_known_map(Map.get(snapshot, "latest")),
      trend: atomize_known_map(Map.get(snapshot, "trend")),
      metrics: atomize_known_maps(Map.get(snapshot, "metrics", [])),
      data_quality: atomize_known_map(Map.get(snapshot, "data_quality"))
    }
  end

  defp snapshot_status(%{"trend" => %{"status" => "direct"}}), do: "direct"
  defp snapshot_status(%{"trend" => %{"status" => "partial"}}), do: "partial"
  defp snapshot_status(_snapshot), do: "gap"

  defp panels(metrics, proof) do
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
        status: proof_panel_status(proof, "autonomy_funnel", "partial"),
        metrics: [
          proof_metric(proof, "linear_phase_handoff_count", "Linear phase handoffs", "Linear phase handoff proof required", "gap"),
          proof_metric(proof, "auto_advance_rate", "Auto-advance rate", "Linear phase comments required", "gap"),
          proof_metric(proof, "human_touch_count", "Human touch count", "Linear comments required", "gap"),
          proof_metric(proof, "human_review_wait_seconds", "Human review wait", "Linear state history required", "gap")
        ]
      },
      %{
        id: "quality_rework",
        title: "Quality / Rework",
        question: "How much accepted work comes back as rework or PR/CI failure?",
        status: proof_panel_status(proof, "quality_rework", "gap"),
        metrics: [
          proof_metric(proof, "clarification_rate", "Clarification rate", "Linear phase comments required", "gap"),
          proof_metric(proof, "rework_rate", "Rework rate", "Linear state history required", "gap"),
          proof_metric(proof, "pr_human_review_count", "PR review quality", "GitHub review/CI data gap", "gap"),
          proof_metric(proof, "ci_success_rate", "GitHub CI pass rate", "GitHub CI data gap", "gap")
        ]
      },
      %{
        id: "cost_per_accepted_issue",
        title: "Cost Per Accepted Issue",
        question: "What token and runtime cost is attached to accepted issues?",
        status: "direct",
        metrics: [
          proof_metric(proof, "tokens_per_accepted_issue", "Tokens per accepted issue", "Accepted issue denominator required", "gap"),
          metric("Runtime seconds", metrics.runtime_seconds, "partial"),
          metric("Total tokens", metrics.total_tokens, "partial"),
          metric("Input tokens", metrics.input_tokens, "partial"),
          metric("Output tokens", metrics.output_tokens, "partial")
        ]
      },
      %{
        id: "capacity_reliability",
        title: "Capacity / Reliability",
        question: "Where do retries, blockers, or capacity pressure stall throughput?",
        status: "direct",
        metrics: capacity_metrics(metrics, proof)
      },
      %{
        id: "data_quality_exclusions",
        title: "Data Quality / Exclusions",
        question: "Which signals are safe to use, and which are only gaps?",
        status: "direct",
        metrics: [
          metric("Direct sources", 1, "direct"),
          metric("Partial sources", 1, "partial"),
          metric("Gap sources", gap_source_count(proof), "gap")
        ]
      }
    ]
  end

  defp metric(label, value, status), do: %{label: label, value: value, status: status}

  defp proof_metric(%{metrics: metrics}, id, fallback_label, fallback_value, fallback_status) when is_list(metrics) do
    case Enum.find(metrics, &(&1.id == id)) do
      nil -> metric(fallback_label, fallback_value, fallback_status)
      metric -> Map.take(metric, [:label, :value, :status, :numerator, :denominator, :source])
    end
  end

  defp proof_metric(_proof, _id, fallback_label, fallback_value, fallback_status),
    do: metric(fallback_label, fallback_value, fallback_status)

  defp proof_panel_status(%{status: status}, _panel, _fallback) when status in ["direct", "partial"], do: status
  defp proof_panel_status(_proof, _panel, fallback), do: fallback

  defp capacity_metrics(%{latest_capacity: latest_capacity} = metrics, proof) do
    latest_capacity = latest_capacity || %{}

    [
      proof_metric(proof, "capacity_trend", "Capacity trend", "Capacity proof required", "gap"),
      proof_metric(proof, "retry_denominator", "Retry denominator", "Accepted issue denominator required", "gap"),
      proof_metric(proof, "blocked_denominator", "Blocked denominator", "Accepted issue denominator required", "gap"),
      metric("Retry events", metrics.retry_count, "partial"),
      metric("Blocked events", metrics.blocked_count, "partial"),
      metric("Running count", Map.get(latest_capacity, "running_count", 0), "partial"),
      %{
        label: "Effective capacity",
        value: Map.get(latest_capacity, "effective_capacity", Map.get(latest_capacity, "configured_capacity", 0)),
        status: "partial"
      }
    ]
  end

  defp data_quality(warnings, truncated?, proof) do
    gaps =
      proof_gaps(proof) ++
        if(truncated?, do: ["Analytics event file was truncated to the latest window"], else: [])

    %{
      direct: ["Symphony runtime event store"] ++ proof_sources(proof, :direct),
      partial: proof_sources(proof, :partial),
      gaps: gaps,
      warnings: warnings
    }
  end

  defp proof_gaps(%{status: status, data_quality: data_quality}) when status in ["direct", "partial"] and is_map(data_quality) do
    Map.get(data_quality, :gaps, [])
  end

  defp proof_gaps(%{reason: "proof_snapshot_outside_read_window"}) do
    [
      "proof_snapshot_outside_read_window",
      "GitHub review/CI data is not configured in v1",
      "Linear phase metrics require collector availability"
    ]
  end

  defp proof_gaps(_proof) do
    [
      "GitHub review/CI data is not configured in v1",
      "Linear phase metrics require collector availability"
    ]
  end

  defp proof_sources(%{data_quality: data_quality}, key) when is_map(data_quality) do
    Map.get(data_quality, key, [])
  end

  defp proof_sources(_proof, _key), do: []

  defp gap_source_count(%{data_quality: %{gaps: gaps}}) when is_list(gaps), do: length(gaps)
  defp gap_source_count(_proof), do: 2

  defp count_events(events, event_type) do
    Enum.count(events, &(Map.get(&1, "event_type") == event_type))
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
    |> Enum.reduce(%{input_tokens: 0, output_tokens: 0, total_tokens: 0}, fn snapshot, totals ->
      %{
        input_tokens: totals.input_tokens + snapshot.input_tokens,
        output_tokens: totals.output_tokens + snapshot.output_tokens,
        total_tokens: totals.total_tokens + snapshot.total_tokens
      }
    end)
  end

  defp token_snapshot(%{"tokens" => tokens}) when is_map(tokens) do
    %{
      input_tokens: integer_value(Map.get(tokens, "input_tokens")),
      output_tokens: integer_value(Map.get(tokens, "output_tokens")),
      total_tokens: integer_value(Map.get(tokens, "total_tokens"))
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

  defp atomize_known_maps(values) when is_list(values), do: Enum.map(values, &atomize_known_map/1)
  defp atomize_known_maps(_values), do: []

  defp atomize_known_map(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {known_atom_key(key), atomize_known_value(nested)}
    end)
  end

  defp atomize_known_map(_value), do: nil

  defp atomize_known_value(values) when is_list(values), do: Enum.map(values, &atomize_known_value/1)
  defp atomize_known_value(value) when is_map(value), do: atomize_known_map(value)
  defp atomize_known_value(value), do: value

  defp known_atom_key(key) when is_binary(key) do
    Map.get(@outcome_proof_keys, key, key)
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
