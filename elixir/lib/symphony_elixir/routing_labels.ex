defmodule SymphonyElixir.RoutingLabels do
  @moduledoc """
  Ground-truth test set for Main Flow steps 3–5 target-phase routing.

  Every `run_started` dispatch in an active state (`Todo`, `In Progress`,
  `Rework`, `Merging`) is a routing decision; `Human Review` dispatches are
  the Maestro reviewer picking the issue up and are never cases. `cases/1`
  labels a dispatch with the phase of the FIRST `phase_published` event of
  the same issue strictly after the dispatch and before that issue's next
  `run_started` (any state): the artifact the session actually produced is
  the ground-truth target phase. Dispatches whose window published nothing
  (crash, question/discussion reply, merge nudge, clarification ask) have no
  observable target and are returned only as the `unlabeled` count.

  `cases/1` and `report/1` are pure; `read_all_events/1` (reusing
  `SymphonyElixir.AnalyticsRollup`) and `write_cases!/2` are the thin IO
  layer used by `mix symphony.eval.routing`.
  """

  alias SymphonyElixir.AnalyticsRollup

  @active_states ["Todo", "In Progress", "Rework", "Merging"]
  @phases ["Requirements", "Design", "Implementation", "Deployment"]

  @type case_entry :: %{
          issue_identifier: String.t() | nil,
          issue_url: String.t() | nil,
          dispatch_at: String.t(),
          state: String.t(),
          expected_phase: String.t(),
          published_event_id: String.t() | nil
        }

  @type labeled :: %{cases: [case_entry()], unlabeled: non_neg_integer()}

  @doc """
  Labels every active-state dispatch with the first publication in its window.

  Events are deduplicated by `event_id` first (events without an `event_id`
  are always kept); dispatches are additionally deduplicated by issue + time
  since `run_started` events carry no `event_id`. Timestamps are compared as
  parsed `DateTime`s — both sides use `occurred_at` falling back to
  `recorded_at` — and a publication must be strictly after the dispatch.
  Cases are ordered per issue by dispatch time.
  """
  @spec cases([map()]) :: labeled()
  def cases(events) when is_list(events) do
    events = dedup_events(events)
    dispatches = dispatch_entries(events)
    publications = publication_entries(events)

    {labeled, unlabeled} =
      dispatches
      |> Enum.filter(&(&1.state in @active_states))
      |> Enum.map(&build_case(&1, dispatches, publications))
      |> Enum.split_with(&(&1 != nil))

    %{
      cases: Enum.sort_by(labeled, &{&1.issue_identifier || "", &1.dispatch_at}),
      unlabeled: length(unlabeled)
    }
  end

  @doc """
  Renders the markdown label report: counts by state × expected phase and the
  unlabeled dispatch count.
  """
  @spec report(labeled()) :: String.t()
  def report(%{cases: cases, unlabeled: unlabeled}) do
    """
    # Routing Label Corpus Report

    #{length(cases)} labeled routing case(s): each is an active-state dispatch
    (`Todo` / `In Progress` / `Rework` / `Merging`) whose session published a
    phase artifact before the issue's next dispatch — that artifact's phase is
    the ground-truth target phase.

    ## Cases by state × expected phase

    #{state_table(cases)}

    Active dispatch(es) that published nothing (unlabeled, excluded): #{unlabeled}

    ## Caveats

    `Human Review` dispatches are the Maestro reviewer picking the issue up,
    not a routing decision, and are never cases. A dispatch whose session
    published no artifact (crash, question/discussion reply, merge nudge,
    clarification ask) has no observable target phase; it is excluded from
    `cases.jsonl` and only counted above.
    """
  end

  @doc """
  Reads the FULL analytics NDJSON file via `AnalyticsRollup.read_all_events/1`
  (event_id-deduplicated, malformed lines skipped).
  """
  @spec read_all_events(Path.t()) :: {:ok, [map()]} | {:error, :enoent}
  def read_all_events(path) do
    if File.regular?(path) do
      {:ok, AnalyticsRollup.read_all_events(path).events}
    else
      {:error, :enoent}
    end
  end

  @doc """
  Writes cases as JSONL (one case per line), creating the directory.
  """
  @spec write_cases!(Path.t(), [case_entry()]) :: :ok
  def write_cases!(path, cases) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(cases, &[Jason.encode!(&1), "\n"]))
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

  defp dispatch_entries(events) do
    for(
      event <- events,
      Map.get(event, "event_type") == "run_started",
      issue_id = Map.get(event, "issue_id"),
      at = event_datetime(event),
      do: %{
        issue_id: issue_id,
        issue_identifier: Map.get(event, "issue_identifier"),
        issue_url: Map.get(event, "issue_url"),
        state: Map.get(event, "state"),
        at: at
      }
    )
    |> Enum.uniq_by(&{&1.issue_id, &1.at})
  end

  defp publication_entries(events) do
    for event <- events,
        Map.get(event, "event_type") == "phase_published",
        issue_id = Map.get(event, "issue_id"),
        phase = Map.get(event, "phase"),
        at = event_datetime(event) do
      %{issue_id: issue_id, phase: phase, event_id: Map.get(event, "event_id"), at: at}
    end
  end

  defp build_case(dispatch, dispatches, publications) do
    window_end = next_dispatch_at(dispatch, dispatches)

    publication =
      publications
      |> Enum.filter(&in_window?(&1, dispatch, window_end))
      |> Enum.min_by(& &1.at, DateTime, fn -> nil end)

    publication &&
      %{
        issue_identifier: dispatch.issue_identifier,
        issue_url: dispatch.issue_url,
        dispatch_at: DateTime.to_iso8601(dispatch.at),
        state: dispatch.state,
        expected_phase: publication.phase,
        published_event_id: publication.event_id
      }
  end

  defp next_dispatch_at(dispatch, dispatches) do
    dispatches
    |> Enum.filter(&(&1.issue_id == dispatch.issue_id and DateTime.compare(&1.at, dispatch.at) == :gt))
    |> Enum.map(& &1.at)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp in_window?(publication, dispatch, window_end) do
    publication.issue_id == dispatch.issue_id and
      DateTime.compare(publication.at, dispatch.at) == :gt and
      (window_end == nil or DateTime.compare(publication.at, window_end) == :lt)
  end

  defp state_table(cases) do
    by_state = Enum.group_by(cases, & &1.state)
    rows = by_state |> Enum.sort() |> Enum.map(fn {state, state_cases} -> state_row(state, state_cases) end)

    header = "| State | " <> Enum.join(@phases, " | ") <> " | Total |"
    divider = "| --- |" <> String.duplicate(" --- |", length(@phases) + 1)
    Enum.join([header, divider] ++ rows ++ [state_row("Total", cases)], "\n")
  end

  defp state_row(label, cases) do
    counts = Enum.frequencies_by(cases, & &1.expected_phase)
    cells = Enum.map(@phases, &Map.get(counts, &1, 0)) ++ [length(cases)]
    "| #{label} | " <> Enum.map_join(cells, " | ", &to_string/1) <> " |"
  end

  defp event_datetime(event) do
    parse_datetime(Map.get(event, "occurred_at") || Map.get(event, "recorded_at"))
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
