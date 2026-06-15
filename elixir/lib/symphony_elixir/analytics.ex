defmodule SymphonyElixir.Analytics do
  @moduledoc """
  Durable, best-effort analytics event storage and v1 dashboard summaries.
  """

  require Logger

  alias SymphonyElixir.{Config, LogFile}

  @default_max_events 500
  @retained_event_lines @default_max_events

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

    event
    |> normalize_event(recorded_at)
    |> Jason.encode()
    |> case do
      {:ok, json} ->
        write_event_line(path, json)

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
         {:ok, content} <- File.read(path) do
      content
      |> String.split("\n", trim: true)
      |> maybe_take_latest(max_events)
      |> decode_event_lines()
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

  defp write_event_line(path, json) when is_binary(path) and is_binary(json) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok ->
        case File.write(path, json <> "\n", [:append]) do
          :ok ->
            retain_event_file(path)

          {:error, reason} ->
            Logger.warning("Failed to write analytics event: #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        Logger.warning("Failed to create analytics directory: #{inspect(reason)}")
        :ok
    end
  end

  defp retain_event_file(path) do
    case File.read(path) do
      {:ok, content} ->
        retain_event_lines(path, String.split(content, "\n", trim: true))

      {:error, reason} ->
        Logger.warning("Failed to retain analytics event file: #{inspect(reason)}")
        :ok
    end
  end

  defp retain_event_lines(path, lines) do
    if length(lines) > @retained_event_lines do
      File.write(path, Enum.join(Enum.take(lines, -@retained_event_lines), "\n") <> "\n")
      :ok
    else
      :ok
    end
  end

  defp maybe_take_latest(lines, max_events) when is_integer(max_events) and max_events > 0 do
    line_count = length(lines)

    if line_count > max_events do
      lines
      |> Enum.with_index(1)
      |> Enum.take(-max_events)
      |> then(&{&1, true})
    else
      lines
      |> Enum.with_index(1)
      |> then(&{&1, false})
    end
  end

  defp maybe_take_latest(lines, _max_events) do
    lines
    |> Enum.with_index(1)
    |> then(&{&1, false})
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

  defp panels(metrics) do
    [
      %{
        id: "delivery_cycle",
        title: "Delivery Cycle",
        status: "partial",
        metrics: [
          %{label: "Runtime-backed runs", value: metrics.run_count},
          %{label: "Completed runs", value: metrics.completed_count}
        ]
      },
      %{
        id: "autonomy_funnel",
        title: "Autonomy Funnel",
        status: "partial",
        metrics: [
          %{label: "Phase events", value: metrics.phase_event_count},
          %{label: "Auto-advance rate", value: "Linear phase comments required"},
          %{label: "Human touch count", value: "Linear comments required"}
        ]
      },
      %{
        id: "quality_rework",
        title: "Quality / Rework",
        status: "gap",
        metrics: [
          %{label: "Rework rate", value: "Linear state history required"},
          %{label: "PR review quality", value: "GitHub review/CI data gap"}
        ]
      },
      %{
        id: "cost_per_accepted_issue",
        title: "Cost Per Accepted Issue",
        status: "direct",
        metrics: [
          %{label: "Runtime seconds", value: metrics.runtime_seconds},
          %{label: "Total tokens", value: metrics.total_tokens},
          %{label: "Input tokens", value: metrics.input_tokens},
          %{label: "Output tokens", value: metrics.output_tokens}
        ]
      },
      %{
        id: "capacity_reliability",
        title: "Capacity / Reliability",
        status: "direct",
        metrics: capacity_metrics(metrics)
      },
      %{
        id: "data_quality_exclusions",
        title: "Data Quality / Exclusions",
        status: "direct",
        metrics: [
          %{label: "Direct sources", value: 1},
          %{label: "Gap sources", value: 2}
        ]
      }
    ]
  end

  defp capacity_metrics(%{latest_capacity: latest_capacity} = metrics) do
    [
      %{label: "Retry events", value: metrics.retry_count},
      %{label: "Blocked events", value: metrics.blocked_count},
      %{label: "Running count", value: Map.get(latest_capacity || %{}, "running_count", 0)},
      %{label: "Configured capacity", value: Map.get(latest_capacity || %{}, "configured_capacity", 0)}
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

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
