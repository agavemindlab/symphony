defmodule SymphonyElixir.MaestroPreReview do
  @moduledoc """
  Runs an isolated Maestro pre-review after a Symphony issue reaches Human Review.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{Analytics, Linear.Issue, PhaseEventScanner, SSH, Workspace}

  @workspace_suffix "-maestro"
  @maestro_linear_api_key_env "MAESTRO_LINEAR_API_KEY"
  @maestro_auto_rework_env "MAESTRO_AUTO_REWORK"
  @maestro_auto_approve_env "MAESTRO_AUTO_APPROVE"
  @maestro_auto_approve_min_confidence_env "MAESTRO_AUTO_APPROVE_MIN_CONFIDENCE"
  @default_auto_approve_min_confidence 8
  @handoff_claims_key {__MODULE__, :handoff_claims}
  @handoff_claim_lock {__MODULE__, :handoff_claim_lock}
  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec run(Issue.t(), keyword()) :: :ok | {:error, term()}
  def run(%Issue{} = issue, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    app_server_runner = Keyword.get(opts, :app_server_runner, &AppServer.run/4)
    workspace_issue = %{issue | identifier: workspace_identifier(issue)}

    result =
      with {:ok, maestro_api_key} <- resolve_maestro_linear_api_key(opts),
           :ok <- validate_maestro_linear_api_key(maestro_api_key, linear_client) do
        Logger.info("Maestro pre-review started for #{issue_context(issue)} worker_host=#{worker_host || "local"}")

        case Workspace.create_for_issue(workspace_issue, worker_host) do
          {:ok, workspace} ->
            try do
              with :ok <- prepare_main_branch(workspace, worker_host),
                   {:ok, _turn} <-
                     app_server_runner.(workspace, build_prompt(issue), issue,
                       worker_host: worker_host,
                       on_message: on_message,
                       tool_executor: maestro_tool_executor(maestro_api_key, linear_client)
                     ) do
                :ok
              end
            after
              Workspace.remove(workspace, worker_host, workspace_issue)
              PhaseEventScanner.scan(issue)
            end

          {:error, reason} ->
            {:error, reason}
        end
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        record_no_action_reason(issue, reason)
        error
    end
  end

  @doc false
  @spec claim_handoff(Issue.t()) :: boolean()
  def claim_handoff(%Issue{} = issue) do
    # ponytail: in-memory claim closes same-BEAM launch races; Linear marker stays durable after restart.
    key = handoff_claim_key(issue)

    case :global.trans(@handoff_claim_lock, fn -> claim_handoff_key(key) end) do
      true -> true
      _ -> false
    end
  end

  @doc false
  @spec claim_handoff_for_test(Issue.t()) :: boolean()
  def claim_handoff_for_test(%Issue{} = issue), do: claim_handoff(issue)

  @doc false
  @spec reset_handoff_claims_for_test() :: :ok
  def reset_handoff_claims_for_test do
    :persistent_term.erase(@handoff_claims_key)
    :ok
  end

  @doc false
  @spec build_prompt_for_test(Issue.t()) :: String.t()
  def build_prompt_for_test(%Issue{} = issue), do: build_prompt(issue)

  @doc false
  @spec workspace_identifier_for_test(Issue.t()) :: String.t()
  def workspace_identifier_for_test(%Issue{} = issue), do: workspace_identifier(issue)

  @doc false
  @spec prepare_main_branch_command_for_test() :: String.t()
  def prepare_main_branch_command_for_test, do: prepare_main_branch_command()

  defp prepare_main_branch(workspace, nil) do
    case System.cmd("sh", ["-lc", prepare_main_branch_command()],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:maestro_main_branch_prepare_failed, status, output}}
    end
  end

  defp prepare_main_branch(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "cd #{shell_escape(workspace)}",
        prepare_main_branch_command()
      ]
      |> Enum.join("\n")

    case SSH.run(worker_host, script, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:maestro_main_branch_prepare_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_main_branch_command do
    """
    set -e
    base_branch="${SYMPHONY_BASE_BRANCH:-main}"
    git rev-parse --is-inside-work-tree >/dev/null
    if git remote get-url upstream >/dev/null 2>&1; then
      git fetch upstream "$base_branch" --prune
      git checkout -B "$base_branch" "upstream/$base_branch"
    else
      git checkout "$base_branch"
      git pull --ff-only origin "$base_branch"
    fi
    """
  end

  defp build_prompt(%Issue{} = issue) do
    build_prompt(issue, auto_rework_enabled?(), auto_approve_config())
  end

  defp build_prompt(%Issue{} = issue, auto_rework?, auto_approve_config) do
    identifier = issue.identifier || issue.id || "unknown"

    """
    You are the isolated Maestro pre-review session for #{identifier}.

    This is a fresh Codex session launched after the working agent handed the issue to `Human Review`.
    Do not reuse the working agent, do not rely on any prior conversation, and do not edit repository files.
    All Linear reads, comments, and state changes available through `linear_graphql` use the dedicated Maestro Linear OAuth app credentials injected by the host. If that tool reports auth failure, stop without using any fallback identity.

    First invoke `$maestro #{identifier}` to obtain the read-only Maestro recommendation.
    Then act on that recommendation using Linear tools under these DEV-5316 rules:

    1. Before mutating anything, re-read the issue. If it is no longer in `Human Review`, stop without commenting or changing state.
    2. Identify the current awaiting-review phase artifact. If that artifact thread already contains a Maestro pre-review reply for the same current artifact/head, stop without adding another reply.
    3. #{rework_rule(auto_rework?)}
    4. #{approve_rule(auto_approve_config)}
    5. If Maestro recommends clarification, no reply yet, merge nudge, completion confirmation, or if the pre-review evidence is unavailable, record a short no-action reason in the awaiting artifact thread when safe, keep the issue in `Human Review`, and do not advance or rework.

    The reply must start with `🤖 Maestro 预审核:` so future sessions can detect that this handoff was already reviewed.
    """
  end

  defp rework_rule(true = _auto_rework?) do
    "If Maestro recommends `request changes`, `request changes / rework`, or equivalent rework, reply in the awaiting artifact thread with the Maestro review, end that reply with the line `🤖 auto: 已自动将 issue 置为 Rework`, and move the issue to the team's `Rework` state (resolve it via a `workflowStates` query matching the name `Rework` exactly; if no such state exists, do not change state and note that in the reply). This action is reversible: a human who disagrees can move the issue back and reply with the reason. Do not write any phase-closing approval reply."
  end

  defp rework_rule(false = _auto_rework?) do
    "If Maestro recommends `request changes`, `request changes / rework`, or equivalent rework, reply in the awaiting artifact thread with the Maestro review and keep the issue in `Human Review` — the operator disabled auto-rework (`MAESTRO_AUTO_REWORK`), so state changes are left to the human. Do not write any phase-closing approval reply."
  end

  defp approve_rule(%{enabled?: true, min_confidence: min_confidence}) do
    "If Maestro recommends `approve`, reply in the awaiting artifact thread with the Maestro review plus a confidence score in `0-10` format and a short text description. Then, only when ALL of these hold — the awaiting-review phase is Requirements or Design (never Implementation, Deployment, or Spike findings), the recommendation is `approve` with confidence >= #{min_confidence}/10, and the artifact body contains no unresolved `[NEEDS CLARIFICATION` marker and no 🔴 high-impact open question — end that reply with the line `🤖 auto: 已自动批准，置为 In Progress` and move the issue to the team's `In Progress` state (resolve it via a `workflowStates` query matching the name `In Progress` exactly; if no such state exists, keep the issue in `Human Review` and note that in the reply). If any condition fails, keep the issue in `Human Review` exactly as when auto-approve is off. This action is reversible: a human who disagrees can set the issue to `Rework` with the reason. `Merging` and `Done` are always the human's; never move the issue to them."
  end

  defp approve_rule(%{enabled?: false}) do
    "If Maestro recommends `approve`, reply in the awaiting artifact thread with the Maestro review plus a confidence score in `0-10` format and a short text description. Keep the issue in `Human Review`. Do not move it to `In Progress`, `Merging`, `Done`, or any other state."
  end

  defp auto_approve_config do
    %{enabled?: auto_approve_enabled?(), min_confidence: auto_approve_min_confidence()}
  end

  defp auto_approve_enabled? do
    @maestro_auto_approve_env
    |> System.get_env()
    |> auto_approve_flag_enabled?()
  end

  # Default OFF: rule 4 grants a new power (advancing the issue), so it needs an
  # explicit true/1 opt-in — the opposite default to auto-rework.
  defp auto_approve_flag_enabled?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["true", "1"]
  end

  defp auto_approve_flag_enabled?(_value), do: false

  defp auto_approve_min_confidence do
    with value when is_binary(value) <- System.get_env(@maestro_auto_approve_min_confidence_env),
         {confidence, ""} <- Integer.parse(String.trim(value)) do
      confidence |> max(0) |> min(10)
    else
      _ -> @default_auto_approve_min_confidence
    end
  end

  defp auto_rework_enabled? do
    @maestro_auto_rework_env
    |> System.get_env()
    |> auto_rework_flag_enabled?()
  end

  # Default ON: rule 3 has always moved request-changes issues to Rework.
  # Only an explicit false/0 downgrades the session to recommendation-only.
  defp auto_rework_flag_enabled?(value) when is_binary(value) do
    String.downcase(String.trim(value)) not in ["false", "0"]
  end

  defp auto_rework_flag_enabled?(_value), do: true

  defp workspace_identifier(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "" do
    identifier <> @workspace_suffix
  end

  defp workspace_identifier(%Issue{id: id}) when is_binary(id) and id != "" do
    id <> @workspace_suffix
  end

  defp workspace_identifier(_issue), do: "issue" <> @workspace_suffix

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{identifier || "n/a"}"
  end

  defp record_no_action_reason(issue, reason) do
    Logger.warning("Maestro pre-review no-action for #{issue_context(issue)}: #{safe_failure_reason(reason)}")
    record_maestro_skipped_event(issue, reason)
    :ok
  end

  defp record_maestro_skipped_event(%Issue{} = issue, reason) do
    Analytics.record_event(%{
      event_type: "maestro_skipped",
      reason: maestro_skipped_reason(reason),
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_url: issue.url
    })
  rescue
    error ->
      Logger.warning("Failed to record maestro_skipped analytics event for #{issue_context(issue)}: #{Exception.message(error)}")
      :ok
  end

  defp maestro_skipped_reason(:missing_maestro_linear_api_key), do: "missing_linear_auth"
  defp maestro_skipped_reason(:invalid_maestro_linear_api_key), do: "invalid_linear_auth"
  defp maestro_skipped_reason(_reason), do: "launch_error"

  defp resolve_maestro_linear_api_key(opts) do
    opts
    |> Keyword.get(:maestro_linear_api_key, System.get_env(@maestro_linear_api_key_env))
    |> normalize_maestro_linear_api_key()
  end

  defp normalize_maestro_linear_api_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :missing_maestro_linear_api_key}
      api_key -> {:ok, api_key}
    end
  end

  defp normalize_maestro_linear_api_key(_value), do: {:error, :missing_maestro_linear_api_key}

  defp validate_maestro_linear_api_key(api_key, linear_client) do
    case linear_client.(@viewer_query, %{}, api_key: api_key) do
      {:ok, response} ->
        if graphql_success?(response), do: :ok, else: {:error, :invalid_maestro_linear_api_key}

      {:error, _reason} ->
        {:error, :invalid_maestro_linear_api_key}
    end
  end

  defp graphql_success?(%{"errors" => errors}) when is_list(errors) and errors != [], do: false
  defp graphql_success?(%{errors: errors}) when is_list(errors) and errors != [], do: false
  defp graphql_success?(%{"data" => _data}), do: true
  defp graphql_success?(%{data: _data}), do: true
  defp graphql_success?(_response), do: false

  defp handoff_claim_key(%Issue{} = issue) do
    {
      issue.id || issue.identifier || "unknown",
      normalize_claim_part(issue.state),
      normalize_claim_updated_at(issue.updated_at)
    }
  end

  defp claim_handoff_key(key) do
    claims = :persistent_term.get(@handoff_claims_key, MapSet.new())

    if MapSet.member?(claims, key) do
      false
    else
      :persistent_term.put(@handoff_claims_key, MapSet.put(claims, key))
      true
    end
  end

  defp normalize_claim_updated_at(%DateTime{} = updated_at), do: DateTime.to_unix(updated_at, :microsecond)
  defp normalize_claim_updated_at(updated_at) when is_binary(updated_at), do: updated_at
  defp normalize_claim_updated_at(_updated_at), do: :unknown_updated_at

  defp normalize_claim_part(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_claim_part(value), do: value

  defp maestro_tool_executor(api_key, linear_client) do
    fn tool, arguments ->
      DynamicTool.execute(tool, arguments, api_key: api_key, linear_client: linear_client)
    end
  end

  defp safe_failure_reason({:maestro_main_branch_prepare_failed, status, _output}) do
    "main 分支准备失败（exit #{status}）"
  end

  defp safe_failure_reason({:workspace_prepare_failed, _worker_host, status, _output}) do
    "workspace 准备失败（exit #{status}）"
  end

  defp safe_failure_reason({:invalid_workspace_cwd, reason, _path}) do
    "workspace 路径不可用（#{reason}）"
  end

  defp safe_failure_reason({:invalid_workspace_cwd, reason, _path, _root}) do
    "workspace 路径不可用（#{reason}）"
  end

  defp safe_failure_reason(reason) when is_atom(reason), do: "`#{reason}`"
  defp safe_failure_reason(_reason), do: "预审核会话启动失败"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
