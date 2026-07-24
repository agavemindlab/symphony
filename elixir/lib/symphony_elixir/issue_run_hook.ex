defmodule SymphonyElixir.IssueRunHook do
  @moduledoc """
  Runs optional workflow hooks for issue Running lifecycle markers.
  """

  require Logger

  alias SymphonyElixir.{Analytics, Config, Subprocess, Workflow}
  alias SymphonyElixir.Linear.{Issue, RunningMarker}

  @type event :: :running | :stopped

  @spec configured?(event()) :: boolean()
  def configured?(event) when event in [:running, :stopped] do
    hooks = Config.settings!().hooks
    hooks.linear_running_marker == true or configured_command?(hook_command(event, hooks))
  end

  def configured?(_event), do: false

  @spec run(event(), Issue.t()) :: :ok
  def run(event, issue), do: run(event, issue, [])

  @spec run(event(), Issue.t(), keyword()) :: :ok
  def run(event, %Issue{} = issue, opts) when event in [:running, :stopped] do
    settings = Config.settings!()
    hooks = settings.hooks
    auth_names = Config.linear_auth_env_names(settings)
    run_native_marker(hooks.linear_running_marker == true, event, issue, opts, hooks.timeout_ms)
    run_custom_hook(hook_command(event, hooks), event, issue, opts, hooks.timeout_ms, auth_names)
    :ok
  end

  def run(_event, _issue, _opts), do: :ok

  defp run_native_marker(false, _event, _issue, _opts, _timeout_ms), do: :ok

  defp run_native_marker(true, event, issue, opts, timeout_ms) do
    hook_name = hook_name(event)
    action = "linear_running_marker"

    Logger.info("Running issue run hook hook=#{hook_name} action=#{action} #{issue_log_context(issue)}")

    task = Task.async(fn -> update_marker(event, issue, Keyword.get(opts, :marker_opts, [])) end)

    case Task.yield(task, timeout_ms) do
      {:ok, :ok} ->
        Logger.info("Issue run hook completed hook=#{hook_name} action=#{action} #{issue_log_context(issue)}")

      {:ok, {:error, reason}} ->
        Logger.warning("Issue run hook failed hook=#{hook_name} action=#{action} #{issue_log_context(issue)} reason=#{inspect(reason)}")
        record_hook_failed_event(hook_name, action, issue)

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("Issue run hook timed out hook=#{hook_name} action=#{action} #{issue_log_context(issue)} timeout_ms=#{timeout_ms}")
        record_hook_failed_event(hook_name, action, issue)
    end
  end

  defp update_marker(event, issue, opts) do
    RunningMarker.update(event, issue, opts)
  rescue
    _error -> {:error, :task_exit}
  catch
    _kind, _reason -> {:error, :task_exit}
  end

  defp run_custom_hook(command, event, issue, opts, timeout_ms, auth_names) when is_binary(command) do
    if configured_command?(command), do: run_command(command, event, issue, opts, timeout_ms, auth_names)
  end

  defp run_custom_hook(_command, _event, _issue, _opts, _timeout_ms, _auth_names), do: :ok

  defp run_command(command, event, issue, opts, timeout_ms, auth_names) do
    hook_name = hook_name(event)
    action = "custom"
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    env = hook_env(event, issue, opts, workflow_dir)

    Logger.info("Running issue run hook hook=#{hook_name} action=#{action} #{issue_log_context(issue)}")

    task =
      Task.async(fn ->
        payload = Config.linear_auth_unset_command(auth_names) <> "\n" <> command

        Subprocess.cmd(
          "sh",
          ["-lc", payload],
          [cd: workflow_dir, env: env, stderr_to_stdout: true],
          auth_names
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Issue run hook failed hook=#{hook_name} action=#{action} #{issue_log_context(issue)} status=#{status} output=#{inspect(sanitize_output(output))}")

        record_hook_failed_event(hook_name, action, issue)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Issue run hook timed out hook=#{hook_name} action=#{action} #{issue_log_context(issue)} timeout_ms=#{timeout_ms}")

        record_hook_failed_event(hook_name, action, issue)
    end
  end

  defp record_hook_failed_event(hook_name, action, %Issue{} = issue) do
    Analytics.record_event(%{
      event_type: "hook_failed",
      hook: hook_name,
      action: action,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_url: issue.url
    })
  rescue
    error ->
      Logger.warning("Failed to record hook_failed analytics event hook=#{hook_name} #{issue_log_context(issue)}: #{Exception.message(error)}")
      :ok
  end

  defp configured_command?(command) when is_binary(command), do: String.trim(command) != ""
  defp configured_command?(_command), do: false

  defp hook_command(:running, hooks), do: hooks.issue_running
  defp hook_command(:stopped, hooks), do: hooks.issue_stopped

  defp hook_name(:running), do: "issue_running"
  defp hook_name(:stopped), do: "issue_stopped"

  defp hook_env(event, issue, opts, workflow_dir) do
    [
      {"SYMPHONY_WORKFLOW_DIR", workflow_dir},
      {"SYMPHONY_HOOK_EVENT", Atom.to_string(event)},
      {"SYMPHONY_HOOK_REASON", env_value(Keyword.get(opts, :reason))},
      {"SYMPHONY_ISSUE_ID", env_value(issue.id)},
      {"SYMPHONY_ISSUE_IDENTIFIER", env_value(issue.identifier)},
      {"SYMPHONY_ISSUE_TITLE", env_value(issue.title)},
      {"SYMPHONY_ISSUE_STATE", env_value(issue.state)},
      {"SYMPHONY_ISSUE_URL", env_value(issue.url)},
      {"SYMPHONY_WORKER_HOST", env_value(Keyword.get(opts, :worker_host))}
    ]
  end

  defp env_value(nil), do: ""
  defp env_value(value) when is_binary(value), do: value
  defp env_value(value), do: to_string(value)

  defp issue_log_context(%Issue{id: id, identifier: identifier}) do
    "issue_id=#{id || "n/a"} issue_identifier=#{identifier || "n/a"}"
  end

  defp sanitize_output(output, max_bytes \\ 2_048) do
    binary = IO.iodata_to_binary(output)

    if byte_size(binary) > max_bytes do
      binary_part(binary, 0, max_bytes) <> "... (truncated)"
    else
      binary
    end
  end
end
