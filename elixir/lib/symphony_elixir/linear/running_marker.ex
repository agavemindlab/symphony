defmodule SymphonyElixir.Linear.RunningMarker do
  @moduledoc false

  alias SymphonyElixir.Linear.{Client, Issue}

  @page_size 50

  @issue_labels_query """
  query RunningMarkerIssueLabels($issueId: String!, $first: Int!, $after: String) {
    issue(id: $issueId) {
      team { id }
      labels(first: $first, after: $after) {
        nodes { id name }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @team_labels_query """
  query RunningMarkerTeamLabels($teamId: String!, $first: Int!, $after: String) {
    team(id: $teamId) {
      labels(first: $first, after: $after) {
        nodes { id name }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @create_label_mutation """
  mutation RunningMarkerCreateLabel($teamId: String!, $name: String!) {
    issueLabelCreate(input: {teamId: $teamId, name: $name}) {
      success
      issueLabel { id name }
    }
  }
  """

  @add_label_mutation """
  mutation RunningMarkerAddLabel($issueId: String!, $labelId: String!) {
    issueAddLabel(id: $issueId, labelId: $labelId) { success }
  }
  """

  @remove_label_mutation """
  mutation RunningMarkerRemoveLabel($issueId: String!, $labelId: String!) {
    issueRemoveLabel(id: $issueId, labelId: $labelId) { success }
  }
  """

  @type event :: :running | :stopped
  @type result :: :ok | {:error, atom()}

  @spec update(event(), Issue.t(), keyword()) :: result()
  def update(event, %Issue{id: issue_id}, opts)
      when event in [:running, :stopped] and is_binary(issue_id) and is_list(opts) do
    case find_attached_label(issue_id, nil, [], opts) do
      {:ok, team_id, attached_label} -> update_label(event, issue_id, team_id, attached_label, opts)
      :issue_missing -> :ok
      error -> error
    end
  end

  def update(_event, _issue, _opts), do: {:error, :invalid_running_marker_input}

  @spec label_name() :: String.t()
  def label_name do
    case System.get_env("SYMPHONY_RUNNING_LABEL") do
      label when is_binary(label) and label != "" ->
        label

      _ ->
        agent_id = System.get_env("SYMPHONY_AGENT_ID") || System.get_env("SYMPHONY_PROFILE") || "default"
        "symphony:running:#{agent_id}"
    end
  end

  defp update_label(:running, _issue_id, _team_id, %{"id" => label_id}, _opts) when is_binary(label_id), do: :ok
  defp update_label(:stopped, _issue_id, _team_id, nil, _opts), do: :ok

  defp update_label(:stopped, issue_id, _team_id, %{"id" => label_id}, opts) when is_binary(label_id) do
    mutate_label(@remove_label_mutation, "RunningMarkerRemoveLabel", "issueRemoveLabel", issue_id, label_id, :label_remove_failed, opts)
  end

  defp update_label(:running, issue_id, team_id, nil, opts) do
    with {:ok, label} <- find_team_label(team_id, nil, opts),
         {:ok, %{"id" => label_id}} <- ensure_label(label, team_id, opts) do
      mutate_label(@add_label_mutation, "RunningMarkerAddLabel", "issueAddLabel", issue_id, label_id, :label_add_failed, opts)
    end
  end

  defp find_attached_label(issue_id, cursor, seen_cursors, opts) do
    variables = %{issueId: issue_id, first: @page_size, after: cursor}

    case graphql(@issue_labels_query, variables, "RunningMarkerIssueLabels", opts) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{"id" => team_id},
             "labels" => %{"nodes" => nodes, "pageInfo" => page_info}
           }
         }
       }}
      when is_binary(team_id) and is_list(nodes) ->
        case Enum.find(nodes, &marker_label?/1) do
          nil -> next_issue_label_page(issue_id, team_id, page_info, [cursor | seen_cursors], opts)
          label -> {:ok, team_id, label}
        end

      {:ok, %{"data" => %{"issue" => nil}}} ->
        :issue_missing

      _ ->
        {:error, :issue_labels_query_failed}
    end
  end

  defp next_issue_label_page(issue_id, team_id, %{"hasNextPage" => true, "endCursor" => cursor}, seen_cursors, opts)
       when is_binary(cursor) and cursor != "" do
    if cursor in seen_cursors do
      {:error, :issue_labels_query_failed}
    else
      case find_attached_label(issue_id, cursor, seen_cursors, opts) do
        {:ok, _next_team_id, label} -> {:ok, team_id, label}
        error -> error
      end
    end
  end

  defp next_issue_label_page(_issue_id, team_id, %{"hasNextPage" => false}, _seen_cursors, _opts),
    do: {:ok, team_id, nil}

  defp next_issue_label_page(_issue_id, _team_id, _page_info, _seen_cursors, _opts),
    do: {:error, :issue_labels_query_failed}

  defp find_team_label(team_id, cursor, opts), do: find_team_label(team_id, cursor, [], opts)

  defp find_team_label(team_id, cursor, seen_cursors, opts) do
    variables = %{teamId: team_id, first: @page_size, after: cursor}

    case graphql(@team_labels_query, variables, "RunningMarkerTeamLabels", opts) do
      {:ok,
       %{
         "data" => %{
           "team" => %{
             "labels" => %{"nodes" => nodes, "pageInfo" => page_info}
           }
         }
       }}
      when is_list(nodes) ->
        case Enum.find(nodes, &marker_label?/1) do
          nil -> next_team_label_page(team_id, page_info, [cursor | seen_cursors], opts)
          label -> {:ok, label}
        end

      _ ->
        {:error, :team_labels_query_failed}
    end
  end

  defp next_team_label_page(team_id, %{"hasNextPage" => true, "endCursor" => cursor}, seen_cursors, opts)
       when is_binary(cursor) and cursor != "" do
    if cursor in seen_cursors,
      do: {:error, :team_labels_query_failed},
      else: find_team_label(team_id, cursor, seen_cursors, opts)
  end

  defp next_team_label_page(_team_id, %{"hasNextPage" => false}, _seen_cursors, _opts), do: {:ok, nil}
  defp next_team_label_page(_team_id, _page_info, _seen_cursors, _opts), do: {:error, :team_labels_query_failed}

  defp ensure_label(%{"id" => label_id} = label, _team_id, _opts) when is_binary(label_id), do: {:ok, label}

  defp ensure_label(nil, team_id, opts) do
    variables = %{teamId: team_id, name: label_name()}

    case graphql(@create_label_mutation, variables, "RunningMarkerCreateLabel", opts) do
      {:ok,
       %{
         "data" => %{
           "issueLabelCreate" => %{
             "success" => true,
             "issueLabel" => %{"id" => label_id} = label
           }
         }
       }}
      when is_binary(label_id) ->
        {:ok, label}

      _ ->
        {:error, :label_create_failed}
    end
  end

  defp mutate_label(query, operation, field, issue_id, label_id, error, opts) do
    variables = %{issueId: issue_id, labelId: label_id}

    case graphql(query, variables, operation, opts) do
      {:ok, %{"data" => %{^field => %{"success" => true}}}} -> :ok
      _ -> {:error, error}
    end
  end

  defp graphql(query, variables, operation_name, opts) do
    opts = opts |> Keyword.put(:operation_name, operation_name) |> Keyword.put(:log_error_body, false)
    Client.graphql(query, variables, opts)
  end

  defp marker_label?(%{"name" => name}) when is_binary(name), do: normalize(name) == normalize(label_name())
  defp marker_label?(_label), do: false

  defp normalize(label), do: label |> String.trim() |> String.downcase()
end
