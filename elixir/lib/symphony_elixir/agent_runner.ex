defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, DynamicTool}
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, SSH, Tracker, Workspace}
  alias SymphonyElixir.Linear.Client

  @stop_after_turn_marker Path.join([".symphony", "stop-after-turn"])
  @bot_review_workspace_suffix "-bot-review"
  @maestro_linear_api_key_env "MAESTRO_LINEAR_API_KEY"

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    workspace_issue = workspace_issue_for_run(issue)

    case Workspace.create_for_issue(workspace_issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
               :ok <- maybe_prepare_bot_review_workspace(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
          maybe_remove_bot_review_workspace(workspace, issue, worker_host, workspace_issue)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    clear_stop_after_turn_marker(workspace, worker_host)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host, issue: issue) do
      try do
        context = %{
          app_session: session,
          workspace: workspace,
          codex_update_recipient: codex_update_recipient,
          opts: opts,
          issue_state_fetcher: issue_state_fetcher,
          worker_host: worker_host,
          max_turns: max_turns
        }

        do_run_codex_turns(context, issue, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(context, issue, turn_number) do
    %{
      app_session: app_session,
      codex_update_recipient: codex_update_recipient,
      max_turns: max_turns,
      opts: opts,
      workspace: workspace
    } = context

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(app_session, prompt, issue, run_turn_opts(issue, codex_update_recipient, opts)) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      continue_after_turn(context, issue, turn_number, turn_session)
    end
  end

  defp continue_after_turn(context, issue, turn_number, turn_session) do
    %{
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      worker_host: worker_host,
      workspace: workspace
    } = context

    if stop_after_turn_marker?(workspace, worker_host) do
      Logger.info("Stop-after-turn marker present for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace}; returning control to orchestrator")

      :ok
    else
      continue_normally(context, issue, issue_state_fetcher, turn_number, max_turns)
    end
  end

  defp continue_normally(context, issue, issue_state_fetcher, turn_number, max_turns) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(context, refreshed_issue, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_after_turn_marker?(workspace, nil) when is_binary(workspace) do
    workspace
    |> stop_after_turn_marker_path()
    |> File.exists?()
  end

  defp stop_after_turn_marker?(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    marker_path = stop_after_turn_marker_path(workspace)

    case run_remote_marker_command(worker_host, "test -e #{shell_escape(marker_path)}") do
      {:ok, {_output, 0}} ->
        true

      {:ok, {_output, 1}} ->
        false

      {:ok, {output, status}} ->
        Logger.warning("Failed to inspect stop-after-turn marker worker_host=#{worker_host} workspace=#{workspace} status=#{status} output=#{inspect(output)}; returning control to orchestrator")
        true

      {:error, reason} ->
        Logger.warning("Failed to inspect stop-after-turn marker worker_host=#{worker_host} workspace=#{workspace} reason=#{inspect(reason)}; returning control to orchestrator")
        true
    end
  end

  defp clear_stop_after_turn_marker(workspace, nil) when is_binary(workspace) do
    case workspace |> stop_after_turn_marker_path() |> File.rm() do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clear stop-after-turn marker workspace=#{workspace} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp clear_stop_after_turn_marker(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    marker_path = stop_after_turn_marker_path(workspace)

    case run_remote_marker_command(worker_host, "rm -f #{shell_escape(marker_path)}") do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Failed to clear stop-after-turn marker worker_host=#{worker_host} workspace=#{workspace} status=#{status} output=#{inspect(output)}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clear stop-after-turn marker worker_host=#{worker_host} workspace=#{workspace} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp stop_after_turn_marker_path(workspace) when is_binary(workspace) do
    Path.join(workspace, @stop_after_turn_marker)
  end

  defp run_remote_marker_command(worker_host, script) when is_binary(worker_host) and is_binary(script) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:stop_after_turn_marker_timeout, timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp run_turn_opts(%Issue{} = issue, codex_update_recipient, opts) do
    base_opts = [on_message: codex_message_handler(codex_update_recipient, issue)]

    if bot_review_issue?(issue) do
      Keyword.put(base_opts, :tool_executor, bot_review_tool_executor(opts))
    else
      base_opts
    end
  end

  defp workspace_issue_for_run(%Issue{} = issue) do
    if bot_review_issue?(issue) do
      %{issue | identifier: bot_review_workspace_identifier(issue)}
    else
      issue
    end
  end

  defp bot_review_workspace_identifier(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "" do
    identifier <> @bot_review_workspace_suffix
  end

  defp bot_review_workspace_identifier(%Issue{id: id}) when is_binary(id) and id != "" do
    id <> @bot_review_workspace_suffix
  end

  defp bot_review_workspace_identifier(_issue), do: "issue" <> @bot_review_workspace_suffix

  defp maybe_prepare_bot_review_workspace(workspace, %Issue{} = issue, worker_host) do
    if bot_review_issue?(issue), do: prepare_main_branch(workspace, worker_host), else: :ok
  end

  defp maybe_remove_bot_review_workspace(workspace, %Issue{} = issue, worker_host, workspace_issue) do
    if bot_review_issue?(issue), do: Workspace.remove(workspace, worker_host, workspace_issue), else: :ok
  end

  defp prepare_main_branch(workspace, nil) do
    case System.cmd("sh", ["-lc", prepare_main_branch_command()],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:bot_review_main_branch_prepare_failed, status, output}}
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
      {:ok, {output, status}} -> {:error, {:bot_review_main_branch_prepare_failed, status, output}}
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

  defp bot_review_tool_executor(opts) do
    api_key = System.get_env(@maestro_linear_api_key_env)
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    fn tool, arguments ->
      DynamicTool.execute(tool, arguments, api_key: api_key, linear_client: linear_client)
    end
  end

  defp bot_review_issue?(%Issue{state: state}) when is_binary(state) do
    normalize_issue_state(state) == "bot review"
  end

  defp bot_review_issue?(_issue), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
