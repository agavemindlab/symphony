defmodule SymphonyElixir.ReviewLabels do
  @moduledoc """
  Human-labeled review test set for the maestro-reviewer prompt.

  Each `phase_published` analytics event is a review handoff; its eventual
  disposition is the human verdict on what a reviewer should have recommended
  at that handoff. `cases/1` labels every published artifact with its FIRST
  disposition strictly after publication:

    * `phase_approved` on the artifact (human ✅) → `"approve"`
    * `phase_auto_advanced` on the artifact (agent ⏩) → `"auto_advanced"`
      (recorded, excluded from scoring)
    * a later `phase_published` of the same issue+phase → `"request_changes"`
      (the artifact was superseded by a rework round)
    * `phase_rollback` of the same issue with `from_phase` == the artifact's
      phase → `"request_changes"`
    * none → `"pending"` (excluded from scoring)

  First-by-time wins among the dispositions. `cases/1` and `report/1` are
  pure; `read_all_events/1` (reusing `SymphonyElixir.AnalyticsRollup`) and
  `write_cases!/2` are the thin IO layer used by `mix symphony.eval.reviews`.
  """

  alias SymphonyElixir.AnalyticsRollup

  @scoreable_labels ["approve", "request_changes"]
  @report_labels ["approve", "request_changes", "auto_advanced", "pending"]

  @type label :: String.t()

  @type case_entry :: %{
          issue_identifier: String.t() | nil,
          issue_url: String.t() | nil,
          phase: String.t() | nil,
          artifact_comment_id: String.t() | nil,
          published_at: String.t() | nil,
          label: label(),
          disposition_event_id: String.t() | nil,
          disposition_at: String.t() | nil,
          needs_clarification: boolean() | nil
        }

  @doc """
  Labels every `phase_published` event with its first disposition.

  Events are deduplicated by `event_id` first (events without an `event_id`
  are always kept). Timestamps are compared as parsed `DateTime`s — both
  sides use `occurred_at` falling back to `recorded_at` — and a disposition
  must be strictly after the publication. Cases are ordered per issue by
  publication time.
  """
  @spec cases([map()]) :: [case_entry()]
  def cases(events) when is_list(events) do
    events = dedup_events(events)
    published = published_entries(events)
    dispositions = disposition_candidates(events, published)

    published
    |> Enum.map(&build_case(&1, dispositions))
    |> Enum.sort_by(&{&1.issue_identifier || "", &1.published_at || "", &1.artifact_comment_id || ""})
  end

  @doc """
  Renders the markdown label report: counts by label × phase and the
  scoreable total.
  """
  @spec report([case_entry()]) :: String.t()
  def report(cases) when is_list(cases) do
    scoreable = Enum.count(cases, &(&1.label in @scoreable_labels))

    """
    # Review Label Corpus Report

    #{length(cases)} published phase artifact(s), each labeled with its first
    disposition (human ✅ approval, agent ⏩ auto-advance, a superseding rework
    round, or a rollback out of the phase).

    ## Labels by phase

    #{label_table(cases)}

    Total scoreable (approve + request_changes): #{scoreable}

    ## Caveats

    `auto_advanced` artifacts were advanced by the agent without a human ✅ and
    carry no human verdict; `pending` artifacts have no disposition yet. Both
    are recorded but excluded from scoring. Each label answers the as-of
    question "what should a reviewer have recommended at that handoff": an
    artifact approved and only later superseded by new feedback still counts
    as `approve` for its own handoff.
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

  defp published_entries(events) do
    for event <- events, Map.get(event, "event_type") == "phase_published" do
      %{event: event, at: event_datetime(event)}
    end
  end

  defp disposition_candidates(events, published) do
    closings(events) ++ supersessions(published) ++ rollbacks(events)
  end

  defp closings(events) do
    for event <- events,
        label = closing_label(Map.get(event, "event_type")),
        at = event_datetime(event) do
      %{
        label: label,
        at: at,
        event_id: Map.get(event, "event_id"),
        matches: {:artifact, Map.get(event, "artifact_comment_id")}
      }
    end
  end

  defp closing_label("phase_approved"), do: "approve"
  defp closing_label("phase_auto_advanced"), do: "auto_advanced"
  defp closing_label(_event_type), do: nil

  defp supersessions(published) do
    for %{event: event, at: at} <- published, not is_nil(at) do
      %{
        label: "request_changes",
        at: at,
        event_id: Map.get(event, "event_id"),
        matches: {:issue_phase, Map.get(event, "issue_id"), Map.get(event, "phase")}
      }
    end
  end

  defp rollbacks(events) do
    for event <- events,
        Map.get(event, "event_type") == "phase_rollback",
        at = event_datetime(event) do
      %{
        label: "request_changes",
        at: at,
        event_id: Map.get(event, "event_id"),
        matches: {:issue_phase, Map.get(event, "issue_id"), Map.get(event, "from_phase")}
      }
    end
  end

  defp build_case(%{event: event, at: published_at}, dispositions) do
    disposition = first_disposition(event, published_at, dispositions)

    %{
      issue_identifier: Map.get(event, "issue_identifier"),
      issue_url: Map.get(event, "issue_url"),
      phase: Map.get(event, "phase"),
      artifact_comment_id: Map.get(event, "comment_id"),
      published_at: published_at && DateTime.to_iso8601(published_at),
      label: (disposition && disposition.label) || "pending",
      disposition_event_id: disposition && disposition.event_id,
      disposition_at: disposition && DateTime.to_iso8601(disposition.at),
      needs_clarification: Map.get(event, "needs_clarification")
    }
  end

  defp first_disposition(_event, nil, _dispositions), do: nil

  defp first_disposition(event, published_at, dispositions) do
    dispositions
    |> Enum.filter(fn candidate ->
      DateTime.compare(candidate.at, published_at) == :gt and disposition_matches?(candidate.matches, event)
    end)
    |> Enum.min_by(& &1.at, DateTime, fn -> nil end)
  end

  defp disposition_matches?({:artifact, artifact_comment_id}, event) do
    is_binary(artifact_comment_id) and artifact_comment_id == Map.get(event, "comment_id")
  end

  defp disposition_matches?({:issue_phase, issue_id, phase}, event) do
    not is_nil(issue_id) and not is_nil(phase) and
      issue_id == Map.get(event, "issue_id") and phase == Map.get(event, "phase")
  end

  defp label_table(cases) do
    by_phase = Enum.group_by(cases, &(&1.phase || "unknown"))
    rows = by_phase |> Enum.sort() |> Enum.map(fn {phase, phase_cases} -> label_row(phase, phase_cases) end)

    header = "| Phase | " <> Enum.join(@report_labels, " | ") <> " | Total |"
    divider = "| --- |" <> String.duplicate(" --- |", length(@report_labels) + 1)
    Enum.join([header, divider] ++ rows ++ [label_row("Total", cases)], "\n")
  end

  defp label_row(label, cases) do
    counts = Enum.frequencies_by(cases, & &1.label)
    cells = Enum.map(@report_labels, &Map.get(counts, &1, 0)) ++ [length(cases)]
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
