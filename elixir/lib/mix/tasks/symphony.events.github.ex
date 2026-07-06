defmodule Mix.Tasks.Symphony.Events.Github do
  use Mix.Task

  @shortdoc "Backfill pr_merged review events from GitHub into the analytics store"

  @moduledoc """
  Sweeps merged pull requests from GitHub via the `gh` CLI and appends one
  `pr_merged` event per PR to the analytics NDJSON event store, skipping
  events whose `event_id` is already present. Event ids are deterministic
  (`github-pr-OWNER/NAME#NUMBER`), so re-running is idempotent and appends
  go through the analytics `.lock` directory like every other writer.

      mix symphony.events.github [--repo OWNER/NAME ...] [--limit N] [--analytics PATH] [--dry-run]

  `--repo` is repeatable and defaults to `SymphonyElixir.Config.github_repos/0`
  (the `:github_repos` app env list, then the comma-separated
  `SYMPHONY_GITHUB_REPOS` environment variable). `--limit` bounds the merged
  PRs fetched per repo (default 200). `--analytics` defaults to the
  configured analytics event file; `--dry-run` prints per-repo counts
  without writing.

  Requires an installed and authenticated `gh` CLI. Repos are processed
  sequentially; a `gh pr list` failure logs the repo and the sweep continues.
  """

  @requirements ["app.config"]

  @default_limit 200
  @pr_list_json_fields "number,title,headRefName,url,mergedAt,reviews"
  @issue_identifier_regex ~r/\b[A-Z][A-Z0-9]+-\d+\b/

  alias SymphonyElixir.{Analytics, AnalyticsRollup, Config}

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [repo: :keep, limit: :integer, analytics: :string, dry_run: :boolean]
      )

    if invalid != [], do: Mix.raise("Invalid option(s): #{inspect(invalid)}")

    repos = resolve_repos!(Keyword.get_values(opts, :repo))
    limit = opts[:limit] || @default_limit
    analytics_path = opts[:analytics] || Analytics.file_path()
    dry_run? = Keyword.get(opts, :dry_run, false)

    ensure_gh_ready!()
    existing_event_ids = existing_event_ids(analytics_path)

    counts =
      Enum.reduce(
        repos,
        %{appended: 0, present: 0, failures: 0},
        &sync_repo(&1, &2, limit, existing_event_ids, analytics_path, dry_run?)
      )

    Mix.shell().info(summary_line(length(repos), counts, analytics_path, dry_run?))
  end

  defp resolve_repos!([]) do
    case Config.github_repos() do
      [] ->
        Mix.raise("""
        No GitHub repos to sweep. Pass --repo OWNER/NAME (repeatable), set the
        :github_repos app env, or export SYMPHONY_GITHUB_REPOS as a
        comma-separated OWNER/NAME list.
        """)

      repos ->
        repos
    end
  end

  defp resolve_repos!(repos), do: repos

  defp ensure_gh_ready! do
    if is_nil(System.find_executable("gh")) do
      Mix.raise("The gh CLI is required but was not found on PATH.")
    end

    case gh(["auth", "status"]) do
      {_output, 0} -> :ok
      {_output, _status} -> Mix.raise("gh is not authenticated. Run `gh auth login` first.")
    end
  end

  defp existing_event_ids(analytics_path) do
    %{events: events} = AnalyticsRollup.read_all_events(analytics_path)

    events
    |> Enum.map(&Map.get(&1, "event_id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp sync_repo(repo, counts, limit, existing_event_ids, analytics_path, dry_run?) do
    case fetch_merged_prs(repo, limit) do
      {:ok, prs} ->
        record_repo_events(repo, prs, counts, existing_event_ids, analytics_path, dry_run?)

      {:error, message} ->
        Mix.shell().error("github: merged PR fetch failed for #{repo}: #{message}")
        %{counts | failures: counts.failures + 1}
    end
  end

  defp fetch_merged_prs(repo, limit) do
    {output, status} =
      gh([
        "pr",
        "list",
        "--repo",
        repo,
        "--state",
        "merged",
        "--limit",
        Integer.to_string(limit),
        "--json",
        @pr_list_json_fields
      ])

    with 0 <- status,
         {:ok, prs} when is_list(prs) <- Jason.decode(output) do
      {:ok, prs}
    else
      {:ok, _not_a_list} -> {:error, "unexpected gh pr list JSON payload"}
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      _nonzero_exit -> {:error, "exit #{status}: #{String.trim(output)}"}
    end
  end

  defp record_repo_events(repo, prs, counts, existing_event_ids, analytics_path, dry_run?) do
    {new_events, present_events} =
      prs
      |> Enum.map(&pr_merged_event(repo, &1))
      |> Enum.split_with(&(not MapSet.member?(existing_event_ids, &1.event_id)))

    unless dry_run? do
      Enum.each(new_events, &Analytics.record_event(&1, path: analytics_path))
    end

    if dry_run? do
      Mix.shell().info("dry-run #{repo}: #{length(new_events)} new event(s), #{length(present_events)} already present")
    end

    %{counts | appended: counts.appended + length(new_events), present: counts.present + length(present_events)}
  end

  defp pr_merged_event(repo, pr) do
    reviews = pr |> Map.get("reviews") |> List.wrap()
    review_states = Enum.map(reviews, &Map.get(&1, "state"))
    number = Map.get(pr, "number")

    %{
      event_type: "pr_merged",
      event_id: "github-pr-#{repo}##{number}",
      repo: repo,
      pr_number: number,
      pr_url: Map.get(pr, "url"),
      issue_identifier: issue_identifier(pr),
      reviews_count: length(reviews),
      changes_requested: "CHANGES_REQUESTED" in review_states,
      approved: "APPROVED" in review_states,
      occurred_at: Map.get(pr, "mergedAt"),
      source: "github"
    }
  end

  defp issue_identifier(pr) do
    [Map.get(pr, "headRefName"), Map.get(pr, "title")]
    |> Enum.find_value(fn text ->
      with true <- is_binary(text),
           [identifier] <- Regex.run(@issue_identifier_regex, text) do
        identifier
      else
        _no_match -> nil
      end
    end)
  end

  defp summary_line(repo_count, counts, analytics_path, dry_run?) do
    {prefix, appended} =
      if dry_run? do
        {"github (dry-run)", "#{counts.appended} events would be appended"}
      else
        {"github", "#{counts.appended} events appended"}
      end

    "#{prefix}: #{repo_count} repos scanned, #{appended} " <>
      "(#{counts.present} already present, #{counts.failures} fetch failures) -> #{analytics_path}"
  end

  # PATH-resolved on purpose so tests can inject a fake `gh` binary, the
  # same runner precedent as `mix workspace.before_remove`.
  defp gh(args), do: System.cmd("gh", args, stderr_to_stdout: true)
end
