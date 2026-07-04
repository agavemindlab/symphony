defmodule SymphonyElixir.MaestroEval do
  @moduledoc """
  Local eval corpus builder for Maestro pre-review verdicts.

  `pairs/1` joins each `maestro_review` analytics event with the first
  subsequent `run_started` dispatch for the same issue; the state of that
  dispatch is the human verdict (ground truth). Classification reuses the
  public `SymphonyElixir.Analytics.maestro_verdict/2`, so corpus labels agree
  with the dashboard agreement metrics. `summarize/1` and `report/1` are pure;
  `read_all_events/1` and `write_corpus!/2` are the thin IO layer used by
  `mix symphony.eval.maestro`.
  """

  alias SymphonyElixir.Analytics

  @type agreement :: :agreed | :overridden | :pending | :excluded

  @type pair :: %{
          issue_identifier: String.t() | nil,
          phase: String.t() | nil,
          recommendation: String.t() | nil,
          confidence: number() | nil,
          auto: boolean() | nil,
          reviewed_at: String.t() | nil,
          verdict_state: String.t() | nil,
          verdict_at: String.t() | nil,
          agreement: agreement()
        }

  @type stats :: %{
          total: non_neg_integer(),
          agreed: non_neg_integer(),
          overridden: non_neg_integer(),
          pending: non_neg_integer(),
          excluded: non_neg_integer(),
          agreement_rate: float() | nil
        }

  @type summary :: %{
          overall: stats(),
          by_phase: %{optional(String.t()) => stats()},
          by_recommendation: %{optional(String.t()) => stats()}
        }

  @doc """
  Builds review/verdict pairs from a full analytics event list.

  Events are deduplicated by `event_id` first (events without an `event_id`
  are always kept). Timestamps are compared as parsed `DateTime`s — the
  review side uses `occurred_at` falling back to `recorded_at` — never
  lexically. Reviews without a subsequent dispatch keep a `nil` verdict.
  """
  @spec pairs([map()]) :: [pair()]
  def pairs(events) when is_list(events) do
    events = dedup_events(events)
    run_starts = run_started_entries(events)

    events
    |> Enum.filter(&(Map.get(&1, "event_type") == "maestro_review"))
    |> Enum.map(&build_pair(&1, run_starts))
  end

  @doc """
  Totals and agreement rates overall, by phase, and by recommendation.

  The agreement rate is `agreed / (agreed + overridden)` (pending and
  excluded pairs are not counted), or `nil` when no pair was decided.
  """
  @spec summarize([pair()]) :: summary()
  def summarize(pairs) when is_list(pairs) do
    %{
      overall: agreement_stats(pairs),
      by_phase: group_stats(pairs, :phase),
      by_recommendation: group_stats(pairs, :recommendation)
    }
  end

  @doc """
  Renders the markdown eval report for a pair list.
  """
  @spec report([pair()]) :: String.t()
  def report(pairs) when is_list(pairs) do
    summary = summarize(pairs)

    """
    # Maestro Verdict Eval Report

    Corpus of #{summary.overall.total} maestro review pair(s); ground truth is the state of the
    first subsequent `run_started` dispatch for the reviewed issue.

    ## Overall agreement

    #{stats_table("Scope", [{"all reviews", summary.overall}])}

    ## Agreement by phase

    #{stats_table("Phase", Enum.sort(summary.by_phase))}

    ## Agreement by recommendation

    #{stats_table("Recommendation", Enum.sort(summary.by_recommendation))}

    ## Overridden cases (prompt-improvement candidates)

    #{overridden_section(pairs)}
    """
  end

  @doc """
  Reads every event line in an analytics NDJSON file (no window bound,
  unlike `SymphonyElixir.Analytics.read_events/1`). Malformed lines are
  skipped.
  """
  @spec read_all_events(Path.t()) :: {:ok, [map()]} | {:error, :enoent}
  def read_all_events(path) do
    if File.regular?(path) do
      {:ok, path |> File.stream!() |> Enum.flat_map(&decode_line/1)}
    else
      {:error, :enoent}
    end
  end

  @doc """
  Writes pairs as JSONL (one pair per line), creating the directory.
  """
  @spec write_corpus!(Path.t(), [pair()]) :: :ok
  def write_corpus!(path, pairs) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(pairs, &[Jason.encode!(&1), "\n"]))
  end

  defp dedup_events(events) do
    {deduped, _seen} = Enum.reduce(events, {[], MapSet.new()}, &dedup_step/2)
    Enum.reverse(deduped)
  end

  defp dedup_step(event, {kept, seen}) do
    case Map.get(event, "event_id") do
      nil ->
        {[event | kept], seen}

      event_id ->
        if MapSet.member?(seen, event_id) do
          {kept, seen}
        else
          {[event | kept], MapSet.put(seen, event_id)}
        end
    end
  end

  defp run_started_entries(events) do
    events
    |> Enum.filter(&(Map.get(&1, "event_type") == "run_started"))
    |> Enum.flat_map(&run_started_entry/1)
  end

  defp run_started_entry(event) do
    case parse_datetime(Map.get(event, "recorded_at")) do
      nil ->
        []

      recorded_at ->
        [%{issue_id: Map.get(event, "issue_id"), recorded_at: recorded_at, state: Map.get(event, "state")}]
    end
  end

  defp build_pair(review, run_starts) do
    reviewed_at = parse_datetime(Map.get(review, "occurred_at") || Map.get(review, "recorded_at"))
    verdict = next_run_start(review, reviewed_at, run_starts)
    verdict_state = verdict && verdict.state

    %{
      issue_identifier: Map.get(review, "issue_identifier"),
      phase: Map.get(review, "phase"),
      recommendation: Map.get(review, "recommendation"),
      confidence: Map.get(review, "confidence"),
      auto: Map.get(review, "auto"),
      reviewed_at: reviewed_at && DateTime.to_iso8601(reviewed_at),
      verdict_state: verdict_state,
      verdict_at: verdict && DateTime.to_iso8601(verdict.recorded_at),
      agreement: Analytics.maestro_verdict(review, verdict_state)
    }
  end

  defp next_run_start(_review, nil, _run_starts), do: nil

  defp next_run_start(review, reviewed_at, run_starts) do
    case Map.get(review, "issue_id") do
      nil ->
        nil

      issue_id ->
        run_starts
        |> Enum.filter(&(&1.issue_id == issue_id and DateTime.compare(&1.recorded_at, reviewed_at) == :gt))
        |> Enum.min_by(& &1.recorded_at, DateTime, fn -> nil end)
    end
  end

  defp agreement_stats(pairs) do
    counts = Enum.frequencies_by(pairs, & &1.agreement)
    agreed = Map.get(counts, :agreed, 0)
    overridden = Map.get(counts, :overridden, 0)

    %{
      total: length(pairs),
      agreed: agreed,
      overridden: overridden,
      pending: Map.get(counts, :pending, 0),
      excluded: Map.get(counts, :excluded, 0),
      agreement_rate: agreement_rate(agreed, overridden)
    }
  end

  defp agreement_rate(0, 0), do: nil
  defp agreement_rate(agreed, overridden), do: Float.round(agreed / (agreed + overridden), 4)

  defp group_stats(pairs, key) do
    pairs
    |> Enum.group_by(&(Map.get(&1, key) || "unknown"))
    |> Map.new(fn {group, group_pairs} -> {group, agreement_stats(group_pairs)} end)
  end

  defp stats_table(label_header, rows) do
    header = "| #{label_header} | Total | Agreed | Overridden | Pending | Excluded | Agreement rate |"
    divider = "| --- | --- | --- | --- | --- | --- | --- |"
    Enum.join([header, divider | Enum.map(rows, &stats_row/1)], "\n")
  end

  defp stats_row({label, stats}) do
    cells = [label, stats.total, stats.agreed, stats.overridden, stats.pending, stats.excluded]
    "| " <> Enum.map_join(cells, " | ", &to_string/1) <> " | #{format_rate(stats.agreement_rate)} |"
  end

  defp format_rate(nil), do: "n/a"
  defp format_rate(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp overridden_section(pairs) do
    case Enum.filter(pairs, &(&1.agreement == :overridden)) do
      [] -> "None."
      overridden -> Enum.map_join(overridden, "\n", &overridden_line/1)
    end
  end

  defp overridden_line(pair) do
    "- #{pair.issue_identifier || "unknown"} — #{pair.phase || "unknown"}/#{pair.recommendation} " <>
      "(reviewed #{pair.reviewed_at}, next dispatch #{pair.verdict_state} at #{pair.verdict_at})"
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) -> [event]
      _malformed -> []
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
