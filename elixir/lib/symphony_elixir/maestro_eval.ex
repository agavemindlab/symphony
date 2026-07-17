defmodule SymphonyElixir.MaestroEval do
  @moduledoc """
  Local eval corpus builder for Maestro pre-review verdicts.

  `pairs/1` resolves the human verdict (ground truth) for each
  `maestro_review` analytics event from two sources, thread signal first:

    * **thread** — ordinary recommendations use the first subsequent
      `phase_approved`, `phase_reworked`, or `phase_rollback` signal.
      ESCALATED convergence recommendations instead use only the next valid
      `phase_published` / `phase_rollback` outcome for the same issue.
    * **dispatch** — when no thread signal exists, the review is joined with
      the first subsequent `run_started` dispatch for the same issue and
      classified via `SymphonyElixir.Analytics.maestro_verdict/2` or `/3`, so
      labels agree with the dashboard agreement metrics.

  `summarize/1` and `report/1` are pure; `read_all_events/1` and
  `write_corpus!/2` are the thin IO layer used by `mix symphony.eval.maestro`.
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
          verdict_source: String.t() | nil,
          verdict_phase: String.t() | nil,
          signal_event_id: String.t() | nil,
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
  are always kept). Timestamps are compared as parsed `DateTime`s — both
  sides use `occurred_at` falling back to `recorded_at` — never lexically.
  Reviews without a thread signal or subsequent dispatch keep a `nil` verdict.
  """
  @spec pairs([map()]) :: [pair()]
  def pairs(events) when is_list(events) do
    events = dedup_events(events)
    reviews = Enum.filter(events, &(Map.get(&1, "event_type") == "maestro_review"))
    run_starts = Analytics.run_started_entries(events)
    signals = signal_candidates(events, ["phase_approved", "phase_reworked", "phase_rollback"])

    outcomes =
      if Enum.any?(reviews, &Analytics.convergence_review?/1),
        do: Analytics.phase_outcome_entries(events),
        else: []

    Enum.map(reviews, &build_pair(&1, run_starts, signals, outcomes))
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

    Corpus of #{summary.overall.total} maestro review pair(s); ground truth prefers the thread
    phase/thread outcome signal and falls back to the state of the
    first subsequent `run_started` dispatch for the reviewed issue.

    ## Overall agreement

    #{stats_table("Scope", [{"all reviews", summary.overall}])}

    #{verdict_source_line(pairs)}

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

  defp build_pair(review, run_starts, signals, outcomes) do
    reviewed_at = parse_datetime(Map.get(review, "occurred_at") || Map.get(review, "recorded_at"))
    verdict = next_run_start(review, reviewed_at, run_starts)
    verdict_state = verdict && verdict.state

    signal =
      if Analytics.convergence_review?(review),
        do: convergence_signal(review, reviewed_at, outcomes),
        else: thread_signal(review, reviewed_at, signals)

    {agreement, verdict_source, signal_event_id} = resolve_verdict(review, signal, verdict_state)

    %{
      issue_identifier: Map.get(review, "issue_identifier"),
      phase: Map.get(review, "phase"),
      recommendation: Map.get(review, "recommendation"),
      confidence: Map.get(review, "confidence"),
      auto: Map.get(review, "auto"),
      reviewed_at: reviewed_at && DateTime.to_iso8601(reviewed_at),
      verdict_state: verdict_state,
      verdict_at: verdict && DateTime.to_iso8601(verdict.recorded_at),
      verdict_source: verdict_source,
      verdict_phase: signal && signal.target_phase,
      signal_event_id: signal_event_id,
      agreement: agreement
    }
  end

  defp signal_candidates(events, event_types) do
    events
    |> Enum.filter(&(Map.get(&1, "event_type") in event_types))
    |> Enum.flat_map(fn event ->
      case parse_datetime(Map.get(event, "occurred_at") || Map.get(event, "recorded_at")) do
        nil -> []
        at -> [%{event: event, at: at}]
      end
    end)
  end

  defp thread_signal(_review, nil, _signals), do: nil

  defp thread_signal(review, reviewed_at, signals) do
    signals
    |> Enum.filter(fn %{event: event, at: at} ->
      DateTime.compare(at, reviewed_at) == :gt and signal_matches?(event, review)
    end)
    |> Enum.min_by(& &1.at, DateTime, fn -> nil end)
    |> case do
      nil ->
        nil

      %{event: event} ->
        %{verdict: signal_verdict(event), target_phase: signal_phase(event), event_id: Map.get(event, "event_id")}
    end
  end

  defp convergence_signal(_review, nil, _outcomes), do: nil

  defp convergence_signal(review, reviewed_at, outcomes) do
    issue_id = Map.get(review, "issue_id")

    outcomes
    |> Enum.filter(fn outcome ->
      not is_nil(issue_id) and
        outcome.issue_id == issue_id and
        DateTime.compare(outcome.occurred_at, reviewed_at) == :gt
    end)
    |> Enum.min_by(& &1.occurred_at, DateTime, fn -> nil end)
    |> case do
      nil ->
        nil

      outcome ->
        %{verdict: :phase_outcome, target_phase: outcome.target_phase, event_id: outcome.event_id}
    end
  end

  defp signal_matches?(event, review) do
    case Map.get(event, "event_type") do
      "phase_approved" ->
        same_artifact?(event, review)

      "phase_reworked" ->
        same_artifact?(event, review) or same_issue_phase?(event, "phase", review)

      "phase_rollback" ->
        same_issue_phase?(event, "from_phase", review)
    end
  end

  defp same_artifact?(event, review) do
    case Map.get(review, "artifact_comment_id") do
      artifact_id when is_binary(artifact_id) -> Map.get(event, "artifact_comment_id") == artifact_id
      _missing -> false
    end
  end

  defp same_issue_phase?(event, phase_key, review) do
    issue_id = Map.get(review, "issue_id")
    phase = Map.get(review, "phase")

    not is_nil(issue_id) and not is_nil(phase) and
      Map.get(event, "issue_id") == issue_id and Map.get(event, phase_key) == phase
  end

  defp signal_verdict(%{"event_type" => "phase_approved"}), do: :approved_signal
  defp signal_verdict(_event), do: :rework_signal

  defp signal_phase(%{"event_type" => "phase_rollback"} = event), do: Map.get(event, "target_phase")
  defp signal_phase(event), do: Map.get(event, "phase")

  defp resolve_verdict(%{"recommendation" => recommendation} = review, signal, verdict_state)
       when recommendation in ["continue_implementation", "rework_design"] do
    agreement = Analytics.maestro_verdict(review, verdict_state, signal)

    cond do
      verdict_state == "Merging" -> {agreement, "dispatch", nil}
      signal -> {agreement, "thread", signal.event_id}
      true -> {agreement, nil, nil}
    end
  end

  defp resolve_verdict(review, signal, verdict_state) do
    case thread_agreement(Map.get(review, "recommendation"), signal, verdict_state) do
      nil -> dispatch_verdict(review, verdict_state)
      agreement -> {agreement, "thread", signal.event_id}
    end
  end

  defp thread_agreement("approve", %{verdict: :approved_signal}, _state), do: :agreed
  defp thread_agreement("approve", %{verdict: :rework_signal}, _state), do: :overridden
  defp thread_agreement("request_changes", %{verdict: :rework_signal}, _state), do: :agreed
  defp thread_agreement("request_changes", %{verdict: :approved_signal}, _state), do: :overridden
  defp thread_agreement("merge_nudge", %{verdict: :approved_signal}, _state), do: :agreed
  defp thread_agreement("merge_nudge", %{verdict: :rework_signal}, _state), do: :overridden
  defp thread_agreement(_recommendation, _signal, _state), do: nil

  defp dispatch_verdict(review, verdict_state) do
    case Analytics.maestro_verdict(review, verdict_state) do
      agreement when agreement in [:agreed, :overridden] -> {agreement, "dispatch", nil}
      agreement -> {agreement, nil, nil}
    end
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

  defp verdict_source_line(pairs) do
    counts = Enum.frequencies_by(pairs, &(Map.get(&1, :verdict_source) || "none"))

    "Verdict sources: thread #{Map.get(counts, "thread", 0)} / dispatch #{Map.get(counts, "dispatch", 0)} / " <>
      "none #{Map.get(counts, "none", 0)}."
  end

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
