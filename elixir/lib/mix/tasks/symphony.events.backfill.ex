defmodule Mix.Tasks.Symphony.Events.Backfill do
  use Mix.Task

  @shortdoc "One-shot backfill of phase artifact events from existing tracker issues"

  @moduledoc """
  Backfills the analytics NDJSON event store from EXISTING tracker issues so
  the Maestro eval corpus does not have to wait for live accumulation. The
  running scanner only covers actively-dispatched issues; this task sweeps
  every issue in the configured active + terminal states, derives Phase
  Artifact Protocol events plus `human_comment` events (one per non-bot
  comment) from the full comment history, and appends only
  the events whose `event_id` is not already present in the analytics file.

      mix symphony.events.backfill --workflow PATH [--analytics PATH] [--dry-run]

  `--workflow` (required) points at the project `WORKFLOW.md`. Its `$VAR`
  values (api key, project scope) resolve from the environment, so source the
  env layers first (see `bin/README.md`). `--analytics` defaults to the
  configured analytics event file; `--dry-run` prints per-issue counts
  without writing.

  Safe to run next to a RUNNING engine by design: appends go through the
  analytics `.lock` directory like every other writer, event ids are
  deterministic, and duplicate lines across scanner/backfill are tolerated
  read-side (all readers dedup by `event_id`). Issues are processed
  sequentially to stay rate-friendly; a comment-fetch error logs the issue
  identifier and the sweep continues.

  `Tracker.fetch_issues_by_states/1` filters by project scope + state name
  only (the Linear GraphQL query carries no label filter), so
  `tracker.required_labels` are enforced client-side here.
  """

  @requirements ["app.config"]

  alias SymphonyElixir.{Analytics, AnalyticsRollup, Config, PhaseEvents, Tracker, Workflow}

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [workflow: :string, analytics: :string, dry_run: :boolean])

    if invalid != [], do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

    workflow_path = opts[:workflow] || Mix.raise("--workflow PATH is required")
    {:ok, _apps} = Application.ensure_all_started(:yamerl)
    {:ok, _apps} = Application.ensure_all_started(:req)

    Workflow.set_workflow_file_path(Path.expand(workflow_path))
    settings = settings_or_raise!()

    analytics_path = opts[:analytics] || Analytics.file_path()
    dry_run? = Keyword.get(opts, :dry_run, false)

    issues = backfill_issues!(settings.tracker)
    existing_event_ids = existing_event_ids(analytics_path)

    counts =
      Enum.reduce(
        issues,
        %{appended: 0, present: 0, failures: 0},
        &backfill_issue(&1, &2, existing_event_ids, analytics_path, dry_run?)
      )

    Mix.shell().info(summary_line(length(issues), counts, analytics_path, dry_run?))
  end

  defp settings_or_raise! do
    Config.settings!()
  rescue
    error in ArgumentError ->
      Mix.raise("""
      #{Exception.message(error)}

      Hint: WORKFLOW.md resolves $VAR values from the environment. Source the
      env layers before running (see bin/README.md), e.g.:

          set -a
          source workflows/agavemindlab/project.env.defaults
          source ~/.config/symphony/<profile>.env
          source workflows/<project>/project.env
          set +a
      """)
  end

  defp backfill_issues!(tracker) do
    states = Enum.uniq(tracker.active_states ++ tracker.terminal_states)

    case Tracker.fetch_issues_by_states(states) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&carries_required_labels?(&1, tracker.required_labels))
        |> Enum.reject(&is_nil(issue_field(&1, :id)))
        |> Enum.uniq_by(&issue_field(&1, :id))

      {:error, reason} ->
        Mix.raise("Unable to fetch issues by states #{inspect(states)}: #{inspect(reason)}")
    end
  end

  defp carries_required_labels?(_issue, []), do: true

  defp carries_required_labels?(issue, required_labels) do
    issue_labels =
      issue
      |> issue_field(:labels)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new(&normalize_label/1)

    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  defp normalize_label(label), do: label |> String.trim() |> String.downcase()

  defp existing_event_ids(analytics_path) do
    %{events: events} = AnalyticsRollup.read_all_events(analytics_path)

    events
    |> Enum.map(&Map.get(&1, "event_id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp backfill_issue(issue, counts, existing_event_ids, analytics_path, dry_run?) do
    case Tracker.fetch_issue_comments(issue_field(issue, :id)) do
      {:ok, comments} ->
        record_issue_events(issue, comments, counts, existing_event_ids, analytics_path, dry_run?)

      {:error, reason} ->
        count_fetch_failure(issue, counts, inspect(reason))
    end
  rescue
    error -> count_fetch_failure(issue, counts, Exception.message(error))
  end

  defp count_fetch_failure(issue, counts, message) do
    Mix.shell().error("backfill: comment fetch failed for #{issue_label(issue)}: #{message}")
    %{counts | failures: counts.failures + 1}
  end

  defp record_issue_events(issue, comments, counts, existing_event_ids, analytics_path, dry_run?) do
    {new_events, present_events} =
      comments
      |> PhaseEvents.derive_all()
      |> Enum.split_with(&(not MapSet.member?(existing_event_ids, &1.event_id)))

    unless dry_run? do
      Enum.each(new_events, &record_event(&1, issue, analytics_path))
    end

    if dry_run? do
      Mix.shell().info("dry-run #{issue_label(issue)}: #{length(new_events)} new event(s), #{length(present_events)} already present")
    end

    %{counts | appended: counts.appended + length(new_events), present: counts.present + length(present_events)}
  end

  defp record_event(event, issue, analytics_path) do
    event
    |> Map.merge(%{
      issue_id: issue_field(issue, :id),
      issue_identifier: issue_field(issue, :identifier),
      issue_url: issue_field(issue, :url),
      source: "backfill"
    })
    |> Analytics.record_event(path: analytics_path)
  end

  defp summary_line(issue_count, counts, analytics_path, dry_run?) do
    {prefix, appended} =
      if dry_run? do
        {"backfill (dry-run)", "#{counts.appended} events would be appended"}
      else
        {"backfill", "#{counts.appended} events appended"}
      end

    "#{prefix}: #{issue_count} issues scanned, #{appended} " <>
      "(#{counts.present} already present, #{counts.failures} fetch failures) -> #{analytics_path}"
  end

  defp issue_field(issue, key) when is_map(issue), do: Map.get(issue, key)
  defp issue_field(_issue, _key), do: nil

  defp issue_label(issue) do
    issue_field(issue, :identifier) || issue_field(issue, :id) || "n/a"
  end
end
