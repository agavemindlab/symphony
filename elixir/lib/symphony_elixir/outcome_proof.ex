defmodule SymphonyElixir.OutcomeProof do
  @moduledoc """
  Reduces durable Linear/GitHub/runtime proof records into one analytics snapshot.
  """

  alias SymphonyElixir.{Analytics, Config}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.OutcomeProof.GitHub

  @accepted_weeks 9
  @issue_cap 200
  @proof_read_events 5_000

  @type source :: %{optional(atom() | String.t()) => term()}
  @type snapshot :: map()

  @query_by_project_slug """
  query SymphonyOutcomeProofIssuesByProjectSlug($projectSlug: String!, $stateNames: [String!]!, $first: Int!) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, or: [{state: {name: {in: $stateNames}}}, {comments: {some: {body: {contains: "✅ 已批准，进入 Deployment"}, parent: {body: {contains: "## Implementation"}}}}}]}, first: $first) {
      nodes {
        id
        identifier
        url
        completedAt
        updatedAt
        state { name type }
        project { name slugId }
        comments(first: 50) {
          nodes {
            body
            createdAt
            user { name app }
            botActor { name type }
            children(first: 20) {
              nodes {
                body
                createdAt
                user { name app }
                botActor { name type }
              }
            }
          }
        }
        stateHistory(first: 50) {
          nodes {
            startedAt
            endedAt
            state { name }
          }
        }
        attachments(first: 20) {
          nodes { title url sourceType }
        }
      }
    }
  }
  """

  @query_by_project_name """
  query SymphonyOutcomeProofIssuesByProjectName($projectName: String!, $stateNames: [String!]!, $first: Int!) {
    issues(filter: {project: {name: {eq: $projectName}}, or: [{state: {name: {in: $stateNames}}}, {comments: {some: {body: {contains: "✅ 已批准，进入 Deployment"}, parent: {body: {contains: "## Implementation"}}}}}]}, first: $first) {
      nodes {
        id
        identifier
        url
        completedAt
        updatedAt
        state { name type }
        project { name slugId }
        comments(first: 50) {
          nodes {
            body
            createdAt
            user { name app }
            botActor { name type }
            children(first: 20) {
              nodes {
                body
                createdAt
                user { name app }
                botActor { name type }
              }
            }
          }
        }
        stateHistory(first: 50) {
          nodes {
            startedAt
            endedAt
            state { name }
          }
        }
        attachments(first: 20) {
          nodes { title url sourceType }
        }
      }
    }
  }
  """

  @spec collect(keyword()) :: {:ok, snapshot()} | {:error, term()}
  def collect(opts \\ []) when is_list(opts) do
    path = Keyword.get(opts, :path, Analytics.file_path())

    with {:ok, accepted_issues} <- fetch_linear_accepted_issues(opts) do
      now = Keyword.get(opts, :now, Date.utc_today())
      github_fun = Keyword.get(opts, :github_pull_request, &GitHub.pull_request/1)

      accepted_issues =
        attach_github_pull_requests(accepted_issues, github_fun, now)

      runtime_events =
        [path: path, max_events: @proof_read_events]
        |> Analytics.read_events()
        |> Map.get(:events, [])
        |> Enum.reject(&(Map.get(&1, "event_type") == "outcome_proof_snapshot"))

      snapshot =
        snapshot(
          %{accepted_issues: accepted_issues, runtime_events: runtime_events},
          opts
        )

      maybe_record_snapshot(snapshot, path, Keyword.get(opts, :collected_at))
      {:ok, snapshot}
    end
  end

  @spec snapshot(source(), keyword()) :: snapshot()
  def snapshot(source, opts \\ []) when is_map(source) and is_list(opts) do
    collected_at = Keyword.get(opts, :collected_at, iso8601(DateTime.utc_now()))
    now = Keyword.get(opts, :now, Date.utc_today())
    automated_reviewers = automated_reviewers(opts)

    {accepted_issues, truncated?} =
      source
      |> get_list(:accepted_issues)
      |> retained_accepted_issues(now)
      |> cap_accepted_issues()

    runtime_events = get_list(source, :runtime_events)
    cohorts = cohorts(accepted_issues, now, truncated?)
    trend = trend(cohorts, truncated?)
    baseline = trend_endpoint(trend, :baseline)
    latest = trend_endpoint(trend, :latest)
    metrics = metrics(accepted_issues, runtime_events, automated_reviewers, baseline, latest)

    %{
      event_type: "outcome_proof_snapshot",
      collected_at: collected_at,
      digest: digest(%{accepted_issues: accepted_issues, runtime_events: runtime_events}),
      proof_window: %{
        accepted_weeks: @accepted_weeks,
        issue_cap: @issue_cap,
        proof_read_events: @proof_read_events,
        current_week_included?: true
      },
      accepted_issue_count: length(accepted_issues),
      truncated?: truncated?,
      cohorts: cohorts,
      baseline: baseline,
      latest: latest,
      trend: Map.take(trend, [:status, :reason]),
      metrics: metrics,
      data_quality: data_quality(accepted_issues, truncated?, trend, metrics)
    }
  end

  defp automated_reviewers(opts) do
    opts
    |> Keyword.get(:automated_reviewers, System.get_env("AUTOMATED_REVIEWER"))
    |> List.wrap()
    |> Enum.flat_map(&split_reviewer_value/1)
    |> Enum.map(&normalize_login/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp fetch_linear_accepted_issues(opts) do
    graphql_fun = Keyword.get(opts, :linear_graphql, &Client.graphql/2)
    state_names = Config.settings!().tracker.terminal_states

    with {:ok, slugs} <- Config.configured_project_slugs(),
         {:ok, names} <- Config.configured_project_names() do
      {:ok, []}
      |> fetch_project_scope({:slug, slugs}, state_names, graphql_fun)
      |> fetch_project_scope({:name, names}, state_names, graphql_fun)
      |> case do
        {:ok, issues} -> {:ok, issues}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_project_scope({:ok, acc}, {_kind, []}, _state_names, _graphql_fun), do: {:ok, acc}
  defp fetch_project_scope({:error, reason}, _scope, _state_names, _graphql_fun), do: {:error, reason}

  defp fetch_project_scope({:ok, acc}, {kind, projects}, state_names, graphql_fun)
       when kind in [:slug, :name] and is_list(projects) do
    Enum.reduce_while(projects, {:ok, acc}, fn project, {:ok, issues_acc} ->
      case fetch_project_issues(kind, project, state_names, graphql_fun) do
        {:ok, issues} -> {:cont, {:ok, issues_acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_project_issues(kind, project, state_names, graphql_fun) do
    variables =
      case kind do
        :slug -> %{projectSlug: project, stateNames: state_names, first: @issue_cap + 1}
        :name -> %{projectName: project, stateNames: state_names, first: @issue_cap + 1}
      end

    with {:ok, response} <- graphql_fun.(project_query(kind), variables),
         nodes when is_list(nodes) <- get_in(response, ["data", "issues", "nodes"]) do
      {:ok, Enum.map(nodes, &normalize_linear_issue/1)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :linear_outcome_proof_payload}
    end
  end

  defp project_query(:slug), do: @query_by_project_slug
  defp project_query(:name), do: @query_by_project_name

  defp normalize_linear_issue(issue) do
    raw_comments = get_in(issue, ["comments", "nodes"]) || []
    comments = flatten_comments(raw_comments)
    phase_closings = phase_closings(raw_comments)
    pull_request_url = issue |> get_in(["attachments", "nodes"]) |> github_pull_request_url()

    %{
      id: issue["id"],
      identifier: issue["identifier"],
      url: issue["url"],
      accepted_at: accepted_at(issue, phase_closings),
      state: get_in(issue, ["state", "name"]),
      project: get_in(issue, ["project", "name"]) || get_in(issue, ["project", "slugId"]),
      phase_closings: phase_closings,
      comments: comments,
      state_spans: state_spans(get_in(issue, ["stateHistory", "nodes"]) || []),
      clarification?: Enum.any?(comments, &String.contains?(get_string(&1, :body), "[NEEDS CLARIFICATION]")),
      phase_artifacts: comments,
      pull_request_url: pull_request_url
    }
  end

  defp attach_github_pull_requests(issues, github_fun, now) do
    retained_issue_ids =
      issues
      |> retained_accepted_issues(now)
      |> cap_accepted_issues()
      |> elem(0)
      |> Enum.map(&get_string(&1, :id))
      |> MapSet.new()

    Enum.map(issues, fn issue ->
      if MapSet.member?(retained_issue_ids, get_string(issue, :id)) do
        Map.put(issue, :pull_request, fetch_pull_request(get_value(issue, :pull_request_url), github_fun))
      else
        issue
      end
    end)
  end

  defp flatten_comments(comments) when is_list(comments) do
    Enum.flat_map(comments, fn comment ->
      [comment | get_in(comment, ["children", "nodes"]) || []]
    end)
  end

  defp phase_closings(comments) do
    comments
    |> Enum.flat_map(fn comment ->
      phase = phase_heading(get_string(comment, :body))

      [comment | get_in(comment, ["children", "nodes"]) || []]
      |> Enum.flat_map(&phase_closing(&1, phase))
    end)
  end

  defp phase_closing(comment, phase) do
    body = get_string(comment, :body)

    cond do
      String.contains?(body, "⏩ 自动进入") ->
        [%{kind: "auto_advance", phase: phase, created_at: comment_created_at(comment)}]

      String.contains?(body, "✅ 已批准") ->
        [%{kind: "human_approval", phase: phase, created_at: comment_created_at(comment)}]

      true ->
        []
    end
  end

  defp phase_heading(body) when is_binary(body) do
    case Regex.run(~r/^##\s+(Requirements|Design|Implementation|Deployment)\b/m, body) do
      [_, phase] -> phase
      _ -> nil
    end
  end

  defp comment_created_at(comment), do: get_string(comment, :createdAt)

  defp accepted_at(issue, phase_closings) do
    phase_acceptance_at(phase_closings) || terminal_acceptance_at(issue)
  end

  defp phase_acceptance_at(phase_closings) do
    phase_closings
    |> Enum.filter(&implementation_or_deployment_approval?/1)
    |> Enum.map(&get_string(&1, :created_at))
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort(:desc)
    |> List.first()
  end

  defp implementation_or_deployment_approval?(closing) do
    closing_kind(closing) == "human_approval" and get_string(closing, :phase) in ["Implementation", "Deployment"]
  end

  defp terminal_acceptance_at(issue) do
    state = get_in(issue, ["state", "name"])

    if terminal_state?(state) and not excluded_state?(state) do
      issue["completedAt"] || issue["updatedAt"]
    end
  end

  defp terminal_state?(state) do
    state = normalize_issue_state(state)

    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.member?(state)
  end

  defp state_spans(spans) when is_list(spans) do
    Enum.map(spans, fn span ->
      %{
        state: get_in(span, ["state", "name"]),
        started_at: span["startedAt"],
        ended_at: span["endedAt"]
      }
    end)
  end

  defp github_pull_request_url(attachments) when is_list(attachments) do
    Enum.find_value(attachments, fn attachment ->
      url = attachment["url"]
      if is_binary(url) and Regex.match?(~r/github\.com\/[^\/]+\/[^\/]+\/pull\/\d+/, url), do: url
    end)
  end

  defp github_pull_request_url(_attachments), do: nil

  defp fetch_pull_request(nil, _github_fun), do: nil

  defp fetch_pull_request(url, github_fun) when is_binary(url) and is_function(github_fun, 1) do
    case github_fun.(url) do
      {:ok, pull_request} when is_map(pull_request) -> pull_request
      _ -> %{url: url, error: "github_pull_request_unavailable"}
    end
  end

  defp maybe_record_snapshot(snapshot, path, recorded_at) do
    if latest_recorded_digest(path) == snapshot.digest do
      :ok
    else
      Analytics.record_event(snapshot, path: path, recorded_at: recorded_at || snapshot.collected_at)
    end
  end

  defp latest_recorded_digest(path) do
    [path: path, max_events: @proof_read_events]
    |> Analytics.read_events()
    |> Map.get(:events, [])
    |> Enum.reverse()
    |> Enum.find(&(Map.get(&1, "event_type") == "outcome_proof_snapshot"))
    |> case do
      %{"digest" => digest} -> digest
      _ -> nil
    end
  end

  defp split_reviewer_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp split_reviewer_value(value), do: [to_string(value)]

  defp retained_accepted_issues(issues, now) do
    window_start =
      now
      |> week_start()
      |> Date.add(-7 * (@accepted_weeks - 1))

    issues
    |> Enum.reject(&excluded_issue?/1)
    |> Enum.filter(fn issue ->
      case accepted_date(issue) do
        %Date{} = date -> Date.compare(date, window_start) != :lt
        _ -> false
      end
    end)
    |> Enum.sort_by(&accepted_sort_key/1, :desc)
  end

  defp excluded_issue?(issue) do
    issue
    |> get_string(:state)
    |> excluded_state?()
  end

  defp excluded_state?(state), do: normalize_issue_state(state) in ["canceled", "cancelled", "duplicate"]

  defp normalize_issue_state(state) do
    state
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp cap_accepted_issues(issues) do
    {Enum.take(issues, @issue_cap), length(issues) > @issue_cap}
  end

  defp cohorts(issues, now, truncated?) do
    current_week = iso_week(now)

    issues
    |> Enum.group_by(fn issue -> {accepted_week(issue), project_name(issue)} end)
    |> Enum.map(fn {{week, project}, cohort_issues} ->
      %{
        week: week,
        project: project,
        sample_count: length(cohort_issues),
        complete_week?: week != current_week,
        truncated?: truncated?
      }
    end)
    |> Enum.sort_by(&{&1.week, &1.project})
  end

  defp trend(cohorts, truncated?) do
    complete = Enum.filter(cohorts, & &1.complete_week?)

    cond do
      complete == [] ->
        %{status: "gap", reason: "no_complete_accepted_issue_cohort"}

      truncated? or Enum.any?(complete, & &1.truncated?) ->
        %{status: "partial", reason: "accepted_issue_cap_reached", baseline: hd(complete), latest: List.last(complete)}

      length(complete) == 1 ->
        %{status: "partial", reason: "single_complete_accepted_issue_cohort", baseline: hd(complete), latest: hd(complete)}

      true ->
        %{status: "direct", baseline: hd(complete), latest: List.last(complete)}
    end
  end

  defp trend_endpoint(%{baseline: baseline}, :baseline), do: Map.take(baseline, [:week, :project, :sample_count])
  defp trend_endpoint(%{latest: latest}, :latest), do: Map.take(latest, [:week, :project, :sample_count])
  defp trend_endpoint(_trend, _key), do: nil

  defp metrics(accepted_issues, runtime_events, automated_reviewers, baseline, latest) do
    accepted_ids = accepted_issue_ids(accepted_issues)

    [
      linear_phase_handoff_metric(accepted_issues),
      auto_advance_metric(accepted_issues),
      human_touch_metric(accepted_issues),
      human_review_wait_metric(accepted_issues),
      clarification_metric(accepted_issues),
      rework_metric(accepted_issues),
      pr_human_review_metric(accepted_issues, automated_reviewers),
      ci_success_metric(accepted_issues),
      tokens_per_accepted_issue_metric(accepted_issues, runtime_events, accepted_ids),
      retry_denominator_metric(accepted_issues, runtime_events, accepted_ids),
      blocked_denominator_metric(accepted_issues, runtime_events, accepted_ids),
      capacity_trend_metric(runtime_events, baseline, latest)
    ]
  end

  defp linear_phase_handoff_metric(issues) do
    handoffs =
      issues
      |> Enum.flat_map(&get_list(&1, :phase_closings))
      |> Enum.count(&(get_string(&1, :phase) != ""))

    denominator = length(issues)

    %{
      id: "linear_phase_handoff_count",
      label: "Linear phase handoffs",
      value: if(denominator > 0, do: handoffs, else: "accepted issue denominator required"),
      status: status_for(denominator),
      source: "linear",
      numerator: handoffs,
      denominator: denominator
    }
  end

  defp auto_advance_metric(issues) do
    closings = Enum.flat_map(issues, &get_list(&1, :phase_closings))
    numerator = Enum.count(closings, &(closing_kind(&1) == "auto_advance"))
    denominator = length(closings)

    ratio_metric("auto_advance_rate", "Auto-advance rate", numerator, denominator, "linear")
  end

  defp human_touch_metric(issues) do
    value =
      issues
      |> Enum.flat_map(&get_list(&1, :comments))
      |> Enum.count(&human_linear_actor?/1)

    %{
      id: "human_touch_count",
      label: "Human touch count",
      value: value,
      status: status_for(length(issues)),
      source: "linear",
      numerator: value,
      denominator: length(issues)
    }
  end

  defp human_review_wait_metric(issues) do
    value =
      issues
      |> Enum.flat_map(&get_list(&1, :state_spans))
      |> Enum.filter(&(String.downcase(get_string(&1, :state)) == "human review"))
      |> Enum.reduce(0, &(&2 + span_seconds(&1)))

    %{
      id: "human_review_wait_seconds",
      label: "Human review wait",
      value: value,
      status: status_for(length(issues)),
      source: "linear",
      numerator: value,
      denominator: length(issues)
    }
  end

  defp clarification_metric(issues) do
    numerator =
      Enum.count(issues, fn issue ->
        get_bool(issue, :clarification?) or artifact_contains?(issue, "[NEEDS CLARIFICATION]")
      end)

    ratio_metric("clarification_rate", "Clarification rate", numerator, length(issues), "linear")
  end

  defp rework_metric(issues) do
    numerator =
      Enum.count(issues, fn issue ->
        Enum.any?(get_list(issue, :state_spans), &(String.downcase(get_string(&1, :state)) == "rework")) or
          artifact_contains?(issue, "🔧 本轮修改")
      end)

    ratio_metric("rework_rate", "Rework rate", numerator, length(issues), "linear")
  end

  defp pr_human_review_metric(issues, automated_reviewers) do
    pull_requests = pull_requests(issues)
    status = linked_source_status(length(pull_requests), length(issues))

    value =
      pull_requests
      |> Enum.flat_map(&(get_list(&1, :reviews) ++ get_list(&1, :comments)))
      |> Enum.count(&human_github_actor?(&1, automated_reviewers))

    %{
      id: "pr_human_review_count",
      label: "PR review quality",
      value: if(status == "gap", do: "GitHub review/CI data gap", else: value),
      status: status,
      source: "github",
      numerator: value,
      denominator: length(pull_requests)
    }
  end

  defp ci_success_metric(issues) do
    pull_requests = pull_requests(issues)

    {success, total} =
      Enum.reduce(pull_requests, {0, 0}, fn pull_request, {success, total} ->
        case ci_result(pull_request) do
          :success -> {success + 1, total + 1}
          :failure -> {success, total + 1}
          :missing -> {success, total}
        end
      end)

    %{
      id: "ci_success_rate",
      label: "GitHub CI pass rate",
      value: ratio_value(success, total),
      status: ci_status(total, length(pull_requests), length(issues)),
      source: "github",
      numerator: success,
      denominator: total
    }
  end

  defp pull_requests(issues) do
    issues
    |> Enum.map(&get_value(&1, :pull_request))
    |> Enum.filter(&pull_request_source?/1)
  end

  defp pull_request_source?(%{} = pull_request), do: is_nil(get_value(pull_request, :error))
  defp pull_request_source?(_pull_request), do: false

  defp linked_source_status(0, _accepted_count), do: "gap"
  defp linked_source_status(source_count, accepted_count) when source_count == accepted_count, do: "direct"
  defp linked_source_status(_source_count, _accepted_count), do: "partial"

  defp ci_status(0, 0, _accepted_count), do: "gap"
  defp ci_status(total, pull_request_count, accepted_count) when total == pull_request_count and pull_request_count == accepted_count, do: "direct"
  defp ci_status(total, _pull_request_count, _accepted_count) when total > 0, do: "partial"
  defp ci_status(_total, _pull_request_count, _accepted_count), do: "gap"

  defp tokens_per_accepted_issue_metric(issues, runtime_events, accepted_ids) do
    total =
      runtime_events
      |> Enum.filter(&(MapSet.member?(accepted_ids, get_string(&1, :issue_id)) and get_string(&1, :event_type) == "cost_snapshot"))
      |> Enum.map(&integer_value(get_in(get_map(&1, :tokens), ["total_tokens"])))
      |> Enum.sum()

    denominator = length(issues)
    value = if denominator > 0, do: div(total, denominator), else: "accepted issue denominator required"

    %{
      id: "tokens_per_accepted_issue",
      label: "Tokens per accepted issue",
      value: value,
      status: status_for(denominator),
      source: "runtime",
      numerator: total,
      denominator: denominator
    }
  end

  defp retry_denominator_metric(issues, runtime_events, accepted_ids) do
    numerator = runtime_issue_event_count(runtime_events, accepted_ids, "retry_scheduled")
    ratio_metric("retry_denominator", "Retry denominator", numerator, length(issues), "runtime")
  end

  defp blocked_denominator_metric(issues, runtime_events, accepted_ids) do
    numerator = runtime_issue_event_count(runtime_events, accepted_ids, "blocked")
    ratio_metric("blocked_denominator", "Blocked denominator", numerator, length(issues), "runtime")
  end

  defp capacity_trend_metric(runtime_events, baseline, latest) when is_map(baseline) and is_map(latest) do
    baseline_capacity = capacity_for_week(runtime_events, baseline.week)
    latest_capacity = capacity_for_week(runtime_events, latest.week)

    case {baseline_capacity, latest_capacity} do
      {left, right} when is_integer(left) and is_integer(right) ->
        delta = right - left

        %{
          id: "capacity_trend",
          label: "Capacity trend",
          value: signed_integer(delta),
          status: "direct",
          source: "runtime",
          numerator: right,
          denominator: left
        }

      {nil, nil} ->
        gap_metric("capacity_trend", "Capacity trend", "capacity source required", "runtime")

      _ ->
        partial_metric("capacity_trend", "Capacity trend", "capacity baseline/latest bucket missing", "runtime")
    end
  end

  defp capacity_trend_metric(_runtime_events, _baseline, _latest),
    do: gap_metric("capacity_trend", "Capacity trend", "accepted cohort trend required", "runtime")

  defp data_quality(accepted_issues, truncated?, trend, metrics) do
    %{
      direct: metrics |> Enum.filter(&(&1.status == "direct")) |> Enum.map(& &1.source) |> Enum.uniq(),
      partial: metrics |> Enum.filter(&(&1.status == "partial")) |> Enum.map(& &1.source) |> Enum.uniq(),
      gaps: metrics |> Enum.filter(&(&1.status == "gap")) |> Enum.map(& &1.value) |> Enum.filter(&is_binary/1) |> Enum.uniq(),
      warnings: proof_warnings(accepted_issues, truncated?, trend)
    }
  end

  defp proof_warnings([], _truncated?, _trend), do: ["accepted_issue_denominator_empty"]

  defp proof_warnings(_issues, truncated?, trend) do
    []
    |> maybe_warn(truncated?, "accepted_issue_cap_reached")
    |> maybe_warn(Map.get(trend, :status) == "partial", Map.get(trend, :reason))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp maybe_warn(warnings, true, warning), do: [warning | warnings]
  defp maybe_warn(warnings, _condition, _warning), do: warnings

  defp ratio_metric(id, label, numerator, denominator, source) do
    %{
      id: id,
      label: label,
      value: ratio_value(numerator, denominator),
      status: status_for(denominator),
      source: source,
      numerator: numerator,
      denominator: denominator
    }
  end

  defp partial_metric(id, label, value, source) do
    %{id: id, label: label, value: value, status: "partial", source: source, numerator: nil, denominator: nil}
  end

  defp gap_metric(id, label, value, source) do
    %{id: id, label: label, value: value, status: "gap", source: source, numerator: nil, denominator: nil}
  end

  defp ratio_value(_numerator, 0), do: "denominator required"
  defp ratio_value(numerator, denominator), do: "#{numerator} / #{denominator}"

  defp status_for(denominator) when is_integer(denominator) and denominator > 0, do: "direct"
  defp status_for(_denominator), do: "gap"

  defp accepted_issue_ids(issues) do
    issues
    |> Enum.map(&get_string(&1, :id))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp runtime_issue_event_count(runtime_events, accepted_ids, event_type) do
    Enum.count(runtime_events, fn event ->
      get_string(event, :event_type) == event_type and MapSet.member?(accepted_ids, get_string(event, :issue_id))
    end)
  end

  defp capacity_for_week(runtime_events, week) when is_binary(week) do
    runtime_events
    |> Enum.filter(fn event ->
      get_string(event, :event_type) == "capacity_snapshot" and event_week(event) == week
    end)
    |> List.last()
    |> case do
      nil -> nil
      event -> integer_value(Map.get(event, "effective_capacity", Map.get(event, :effective_capacity)))
    end
  end

  defp event_week(event), do: event |> get_string(:recorded_at) |> parse_date() |> maybe_iso_week()
  defp accepted_week(issue), do: issue |> accepted_date() |> iso_week()

  defp accepted_sort_key(issue), do: get_string(issue, :accepted_at)

  defp accepted_date(issue), do: issue |> get_string(:accepted_at) |> parse_date()

  defp parse_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_date(datetime)
      _ -> nil
    end
  end

  defp maybe_iso_week(%Date{} = date), do: iso_week(date)
  defp maybe_iso_week(_value), do: nil

  defp iso_week(%Date{} = date) do
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  defp week_start(%Date{} = date) do
    Date.add(date, 1 - Date.day_of_week(date))
  end

  defp project_name(issue) do
    case get_value(issue, :project) do
      value when is_binary(value) and value != "" -> value
      %{} = project -> get_string(project, :name)
      _ -> "unknown"
    end
  end

  defp closing_kind(closing) do
    closing
    |> get_value(:kind)
    |> to_string()
  end

  defp human_linear_actor?(%{} = comment) do
    user = get_map(comment, :user)
    bot_actor = get_value(comment, :bot_actor) || get_value(comment, :botActor)
    map_size(user) > 0 and get_bool(user, :app) == false and is_nil(bot_actor)
  end

  defp human_linear_actor?(_comment), do: false

  defp human_github_actor?(entry, automated_reviewers) do
    author = get_map(entry, :author)
    login = get_string(author, :login)
    normalized_login = normalize_login(login)
    type = get_string(author, :type)

    type != "Bot" and normalized_login != "" and
      normalized_login not in ["github-actions[bot]"] and
      not String.ends_with?(normalized_login, ["[bot]", "-bot"]) and
      not MapSet.member?(automated_reviewers, normalized_login)
  end

  defp normalize_login(login), do: login |> to_string() |> String.trim() |> String.downcase()

  defp ci_result(pull_request) do
    head_sha = get_string(pull_request, :head_sha)

    pull_request
    |> get_list(:checks)
    |> Enum.filter(fn check ->
      check_sha = get_string(check, :sha)
      head_sha == "" or check_sha == "" or check_sha == head_sha
    end)
    |> case do
      [] ->
        :missing

      checks ->
        if Enum.all?(checks, &(get_string(&1, :conclusion) in ["success", "neutral", "skipped"])) do
          :success
        else
          :failure
        end
    end
  end

  defp artifact_contains?(issue, needle) when is_binary(needle) do
    issue
    |> get_list(:phase_artifacts)
    |> Enum.any?(fn artifact -> artifact |> get_string(:body) |> String.contains?(needle) end)
  end

  defp span_seconds(span) do
    with {:ok, started_at, _} <- DateTime.from_iso8601(get_string(span, :started_at)),
         {:ok, ended_at, _} <- DateTime.from_iso8601(get_string(span, :ended_at)) do
      max(0, DateTime.diff(ended_at, started_at, :second))
    else
      _ -> 0
    end
  end

  defp get_list(map, key) do
    case get_value(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp get_map(map, key) do
    case get_value(map, key) do
      %{} = value -> value
      _ -> %{}
    end
  end

  defp get_bool(map, key), do: get_value(map, key) == true

  defp get_string(map, key) do
    case get_value(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> ""
    end
  end

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_value(_map, _key), do: nil

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(value) when is_float(value), do: trunc(value)

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp integer_value(_value), do: 0

  defp signed_integer(value) when is_integer(value) and value > 0, do: "+#{value}"
  defp signed_integer(value) when is_integer(value), do: Integer.to_string(value)

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
