defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH, Workflow}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_workspace_inspect_marker "__SYMPHONY_WORKSPACE_INSPECT__"
  @remote_workspace_path_marker "__SYMPHONY_WORKSPACE_PATH__"
  @remote_workspace_identity_marker "__SYMPHONY_WORKSPACE_MARKER__"
  @remote_workspace_remote_marker "__SYMPHONY_WORKSPACE_REMOTE__"
  @remote_workspace_marker_write "__SYMPHONY_WORKSPACE_MARKER_WRITE__"
  @workspace_identity_marker ".symphony/workspace-identity.json"
  @workspace_identity_version 1

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, project_env} <- Workflow.resolve_project_env(issue_context),
           {:ok, expected_identity} <- expected_workspace_identity(issue_context, project_env),
           {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host, expected_identity),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, project_env),
           :ok <- maybe_write_workspace_identity_marker(workspace, expected_identity, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, worker_host, nil), do: ensure_workspace_without_identity(workspace, worker_host)

  defp ensure_workspace(workspace, nil, expected_identity) when is_map(expected_identity) do
    cond do
      File.dir?(workspace) ->
        workspace
        |> existing_workspace_identity_status(expected_identity, nil)
        |> handle_local_workspace_identity_status(workspace, expected_identity)

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host, expected_identity)
       when is_binary(worker_host) and is_map(expected_identity) do
    with {:ok, inspection} <- inspect_remote_workspace(workspace, worker_host) do
      inspection
      |> remote_workspace_identity_status(expected_identity)
      |> handle_remote_workspace_identity_status(inspection, workspace, expected_identity, worker_host)
    end
  end

  defp handle_local_workspace_identity_status(:reuse, workspace, _expected_identity) do
    {:ok, workspace, false}
  end

  defp handle_local_workspace_identity_status(:legacy_reuse, workspace, expected_identity) do
    with :ok <- write_workspace_identity_marker(workspace, expected_identity, nil) do
      {:ok, workspace, false}
    end
  end

  defp handle_local_workspace_identity_status({:quarantine, _reason}, workspace, _expected_identity) do
    with :ok <- quarantine_workspace(workspace, nil) do
      create_workspace(workspace)
    end
  end

  defp handle_remote_workspace_identity_status(:reuse, inspection, workspace, _expected_identity, _worker_host) do
    {:ok, Map.get(inspection, :path, workspace), false}
  end

  defp handle_remote_workspace_identity_status(:legacy_reuse, inspection, workspace, expected_identity, worker_host) do
    remote_workspace = Map.get(inspection, :path, workspace)

    with :ok <- write_workspace_identity_marker(remote_workspace, expected_identity, worker_host) do
      {:ok, remote_workspace, false}
    end
  end

  defp handle_remote_workspace_identity_status(:create, _inspection, workspace, _expected_identity, worker_host) do
    create_remote_workspace(workspace, worker_host)
  end

  defp handle_remote_workspace_identity_status({:quarantine, _reason}, _inspection, workspace, _expected_identity, worker_host) do
    quarantine_remote_workspace(workspace, worker_host)
  end

  defp ensure_workspace_without_identity(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace_without_identity(workspace, worker_host) when is_binary(worker_host) do
    create_remote_workspace(workspace, worker_host)
  end

  defp create_remote_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host), do: remove(workspace, worker_host, nil)

  @spec remove(Path.t(), worker_host(), map() | String.t() | nil) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil, issue_or_identifier) do
    issue_context = before_remove_issue_context(issue_or_identifier, workspace)

    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil, issue_context)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host, issue_or_identifier) when is_binary(worker_host) do
    issue_context = before_remove_issue_context(issue_or_identifier, workspace)
    maybe_run_before_remove_hook(workspace, worker_host, issue_context)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(issue_or_identifier, worker_host) when is_binary(worker_host) do
    case removable_issue_context(issue_or_identifier) do
      %{issue_identifier: identifier} = issue_context when is_binary(identifier) ->
        identifier
        |> safe_identifier()
        |> remove_issue_workspace_for_worker(worker_host, issue_context)

      _ ->
        :ok
    end

    :ok
  end

  def remove_issue_workspaces(issue_or_identifier, nil) do
    case removable_issue_context(issue_or_identifier) do
      %{issue_identifier: identifier} = issue_context when is_binary(identifier) ->
        remove_issue_workspaces_for_configured_workers(
          issue_or_identifier,
          safe_identifier(identifier),
          issue_context
        )

      _ ->
        :ok
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec issue_workspace_exists?(term()) :: boolean()
  def issue_workspace_exists?(issue_or_identifier) do
    case removable_issue_context(issue_or_identifier) do
      %{issue_identifier: identifier} when is_binary(identifier) ->
        issue_workspace_exists_for_configured_workers?(safe_identifier(identifier))

      _ ->
        false
    end
  end

  defp issue_workspace_exists_for_configured_workers?(safe_id) when is_binary(safe_id) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        issue_workspace_exists_for_worker?(safe_id, nil)

      worker_hosts ->
        Enum.any?(worker_hosts, &issue_workspace_exists_for_worker?(safe_id, &1))
    end
  end

  defp issue_workspace_exists_for_worker?(safe_id, nil) when is_binary(safe_id) do
    with {:ok, workspace} <- workspace_path_for_issue(safe_id, nil),
         :ok <- validate_workspace_path(workspace, nil) do
      File.exists?(workspace)
    else
      _ -> false
    end
  end

  defp issue_workspace_exists_for_worker?(safe_id, worker_host)
       when is_binary(safe_id) and is_binary(worker_host) do
    with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
         :ok <- validate_workspace_path(workspace, worker_host) do
      script =
        [
          remote_shell_assign("workspace", workspace),
          "[ -e \"$workspace\" ]"
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
        {:ok, {_output, 0}} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp remove_issue_workspaces_for_configured_workers(issue_or_identifier, safe_id, issue_context) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_issue_workspace_for_worker(safe_id, nil, issue_context)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue_or_identifier, &1))
    end
  end

  defp remove_issue_workspace_for_worker(safe_id, worker_host, issue_context) do
    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host, issue_context)
      {:error, _reason} -> :ok
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, project_env) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_after_create_hook(command, workspace, issue_context, worker_host, project_env)
        end

      false ->
        :ok
    end
  end

  defp run_after_create_hook(command, workspace, issue_context, worker_host, project_env) do
    case run_hook(command, workspace, issue_context, "after_create", worker_host, project_env) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        cleanup_failed_created_workspace(workspace, worker_host, issue_context)
        error
    end
  end

  defp cleanup_failed_created_workspace(workspace, nil, issue_context) do
    Logger.info("Removing workspace after failed after_create #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove workspace after failed after_create #{issue_log_context(issue_context)} workspace=#{workspace} path=#{path} reason=#{inspect(reason)} worker_host=local")
        :ok
    end
  end

  defp cleanup_failed_created_workspace(workspace, worker_host, issue_context)
       when is_binary(worker_host) do
    Logger.info("Removing workspace after failed after_create #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        sanitized_output = sanitize_hook_output_for_log(output)

        Logger.warning(
          "Failed to remove workspace after failed after_create #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)} worker_host=#{worker_host}"
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to remove workspace after failed after_create #{issue_log_context(issue_context)} workspace=#{workspace} reason=#{inspect(reason)} worker_host=#{worker_host}")
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil, issue_context) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              issue_context,
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host, issue_context) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        run_remote_before_remove_hook(command, workspace, worker_host, issue_context)
        |> ignore_hook_failure()
    end
  end

  defp run_remote_before_remove_hook(command, workspace, worker_host, issue_context) do
    with {:ok, exports} <- remote_hook_env_exports(issue_context) do
      script =
        [
          exports,
          remote_shell_assign("workspace", workspace),
          "if [ -d \"$workspace\" ]; then",
          "  cd \"$workspace\"",
          "  #{command}",
          "fi"
        ]
        |> Enum.join("\n")

      worker_host
      |> run_remote_command(script, Config.settings!().hooks.timeout_ms)
      |> handle_remote_before_remove_hook_result(workspace, issue_context)
    end
  end

  defp handle_remote_before_remove_hook_result({:ok, {output, status}}, workspace, issue_context) do
    handle_hook_command_result(
      {output, status},
      workspace,
      issue_context,
      "before_remove"
    )
  end

  defp handle_remote_before_remove_hook_result({:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason}, _workspace, _issue_context) do
    {:error, reason}
  end

  defp handle_remote_before_remove_hook_result({:error, reason}, _workspace, _issue_context) do
    {:error, reason}
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, project_env \\ nil)

  defp run_hook(command, workspace, issue_context, hook_name, nil, project_env) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    with {:ok, exports} <- hook_env_exports(issue_context, project_env) do
      script =
        [
          exports,
          command
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      task =
        Task.async(fn ->
          System.cmd("sh", ["-lc", script],
            cd: workspace,
            env: cleared_hook_env(),
            stderr_to_stdout: true
          )
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, cmd_result} ->
          handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

        nil ->
          Task.shutdown(task, :brutal_kill)

          Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

          {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
      end
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, project_env) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    with {:ok, exports} <- remote_hook_env_exports(issue_context, project_env) do
      script =
        [
          exports,
          "cd #{shell_escape(workspace)}",
          command
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, timeout_ms) do
        {:ok, cmd_result} ->
          handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

        {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp expected_workspace_identity(%{project: nil}, _project_env), do: {:ok, nil}

  defp expected_workspace_identity(%{project: project}, %{workflow_file: workflow_file, workflow_dir: workflow_dir, env: env})
       when is_map(project) and is_map(env) do
    repo = Map.get(env, "SYMPHONY_REPO")
    project_slug = Map.get(env, "SYMPHONY_PROJECT_SLUG")

    if blank?(repo) or blank?(project_slug) do
      {:ok, nil}
    else
      {:ok,
       %{
         "version" => @workspace_identity_version,
         "linear_project_id" => Map.get(project, :id),
         "linear_project_slug_id" => Map.get(project, :slug_id),
         "linear_project_name" => Map.get(project, :name),
         "workflow_dir" => workflow_dir,
         "workflow_file" => workflow_file,
         "symphony_project_slug" => project_slug,
         "symphony_repo" => repo
       }}
    end
  end

  defp expected_workspace_identity(_issue_context, _project_env), do: {:ok, nil}

  defp existing_workspace_identity_status(workspace, expected_identity, nil) do
    case read_workspace_identity_marker(workspace, nil) do
      {:ok, marker} ->
        if marker == expected_identity do
          :reuse
        else
          {:quarantine, :marker_mismatch}
        end

      {:error, :missing_marker} ->
        legacy_workspace_identity_status(infer_workspace_repo(workspace), expected_identity)

      {:error, _reason} ->
        {:quarantine, :invalid_marker}
    end
  end

  defp remote_workspace_identity_status(%{kind: :missing}, _expected_identity), do: :create
  defp remote_workspace_identity_status(%{kind: :other}, _expected_identity), do: :create

  defp remote_workspace_identity_status(%{kind: :dir} = inspection, expected_identity) do
    case Map.get(inspection, :marker) do
      marker_json when is_binary(marker_json) and marker_json != "" ->
        case Jason.decode(marker_json) do
          {:ok, ^expected_identity} -> :reuse
          {:ok, _marker} -> {:quarantine, :marker_mismatch}
          {:error, _reason} -> {:quarantine, :invalid_marker}
        end

      _ ->
        legacy_workspace_identity_status(normalize_repo_from_remote(Map.get(inspection, :remote)), expected_identity)
    end
  end

  defp legacy_workspace_identity_status({:ok, repo}, %{"symphony_repo" => expected_repo})
       when repo == expected_repo do
    :legacy_reuse
  end

  defp legacy_workspace_identity_status(_repo_result, _expected_identity) do
    {:quarantine, :legacy_repo_mismatch}
  end

  defp read_workspace_identity_marker(workspace, nil) do
    marker_path = Path.join(workspace, @workspace_identity_marker)

    case File.read(marker_path) do
      {:ok, content} -> Jason.decode(content)
      {:error, :enoent} -> {:error, :missing_marker}
      {:error, reason} -> {:error, reason}
    end
  end

  defp infer_workspace_repo(workspace) when is_binary(workspace) do
    ["upstream", "origin"]
    |> Enum.find_value({:error, :unknown_remote}, fn remote ->
      case System.cmd("git", ["-C", workspace, "remote", "get-url", remote], stderr_to_stdout: true) do
        {url, 0} -> normalize_repo_from_remote(String.trim(url))
        {_output, _status} -> nil
      end
    end)
  end

  defp normalize_repo_from_remote(remote_url) when is_binary(remote_url) and remote_url != "" do
    repo =
      remote_url
      |> String.trim()
      |> String.trim_trailing("/")
      |> String.trim_trailing(".git")
      |> String.split("/", trim: true)
      |> List.last()

    case repo do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :unknown_remote}
    end
  end

  defp normalize_repo_from_remote(_remote_url), do: {:error, :unknown_remote}

  defp quarantine_workspace(workspace, nil) do
    target = quarantine_path(workspace)

    case File.rename(workspace, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_quarantine_failed, workspace, target, reason}}
    end
  end

  defp quarantine_path(workspace) when is_binary(workspace) do
    parent = Path.dirname(workspace)
    base = Path.basename(workspace)
    timestamp = System.system_time(:millisecond)
    unique_quarantine_path(parent, base, timestamp, 0)
  end

  defp unique_quarantine_path(parent, base, timestamp, suffix) do
    suffix_part = if suffix == 0, do: "", else: ".#{suffix}"
    candidate = Path.join(parent, "#{base}.quarantine.#{timestamp}#{suffix_part}")

    if File.exists?(candidate) do
      unique_quarantine_path(parent, base, timestamp, suffix + 1)
    else
      candidate
    end
  end

  defp inspect_remote_workspace(workspace, worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'dir'",
        "  cd \"$workspace\"",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_path_marker}' \"$(pwd -P)\"",
        "  if [ -f \"$workspace/#{@workspace_identity_marker}\" ]; then",
        "    printf '%s\\t' '#{@remote_workspace_identity_marker}'",
        "    cat \"$workspace/#{@workspace_identity_marker}\"",
        "    printf '\\n'",
        "  fi",
        "  remote_url=\"$(git -C \"$workspace\" remote get-url upstream 2>/dev/null || git -C \"$workspace\" remote get-url origin 2>/dev/null || true)\"",
        "  if [ -n \"$remote_url\" ]; then",
        "    printf '%s\\t%s\\n' '#{@remote_workspace_remote_marker}' \"$remote_url\"",
        "  fi",
        "elif [ -e \"$workspace\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'other'",
        "else",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'missing'",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_remote_workspace_inspection(output)
      {:ok, {output, status}} -> {:error, {:workspace_inspect_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_remote_workspace_inspection(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &put_remote_workspace_inspection_line/2)
    |> case do
      %{kind: kind} = inspection when kind in [:dir, :other, :missing] -> {:ok, inspection}
      _inspection -> {:error, {:workspace_inspect_failed, :invalid_output, output}}
    end
  end

  defp put_remote_workspace_inspection_line(line, acc) do
    case String.split(line, "\t", parts: 2) do
      [@remote_workspace_inspect_marker, kind] -> put_remote_workspace_kind(acc, kind)
      [@remote_workspace_path_marker, path] -> Map.put(acc, :path, path)
      [@remote_workspace_identity_marker, marker] -> Map.put(acc, :marker, marker)
      [@remote_workspace_remote_marker, remote] -> Map.put(acc, :remote, String.trim(remote))
      _ -> acc
    end
  end

  defp put_remote_workspace_kind(acc, "dir"), do: Map.put(acc, :kind, :dir)
  defp put_remote_workspace_kind(acc, "other"), do: Map.put(acc, :kind, :other)
  defp put_remote_workspace_kind(acc, "missing"), do: Map.put(acc, :kind, :missing)
  defp put_remote_workspace_kind(acc, _kind), do: acc

  defp quarantine_remote_workspace(workspace, worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -e \"$workspace\" ]; then",
        "  parent=\"$(dirname \"$workspace\")\"",
        "  base=\"$(basename \"$workspace\")\"",
        "  timestamp=\"$(date +%Y%m%d%H%M%S).$$\"",
        "  quarantine=\"$parent/$base.quarantine.$timestamp\"",
        "  suffix=0",
        "  while [ -e \"$quarantine\" ]; do",
        "    suffix=$((suffix + 1))",
        "    quarantine=\"$parent/$base.quarantine.$timestamp.$suffix\"",
        "  done",
        "  mv \"$workspace\" \"$quarantine\"",
        "fi",
        "mkdir -p \"$workspace\"",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' '1' \"$(pwd -P)\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_remote_workspace_output(output)
      {:ok, {output, status}} -> {:error, {:workspace_quarantine_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_write_workspace_identity_marker(_workspace, nil, _created?, _worker_host), do: :ok
  defp maybe_write_workspace_identity_marker(_workspace, _expected_identity, false, _worker_host), do: :ok

  defp maybe_write_workspace_identity_marker(workspace, expected_identity, true, worker_host) do
    write_workspace_identity_marker(workspace, expected_identity, worker_host)
  end

  defp write_workspace_identity_marker(workspace, expected_identity, nil) do
    marker_path = Path.join(workspace, @workspace_identity_marker)

    case File.mkdir_p(Path.dirname(marker_path)) do
      :ok -> File.write(marker_path, Jason.encode!(expected_identity))
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_workspace_identity_marker(workspace, expected_identity, worker_host) when is_binary(worker_host) do
    marker_json = Jason.encode!(expected_identity)

    script =
      [
        "set -eu",
        "printf '%s\\n' '#{@remote_workspace_marker_write}'",
        remote_shell_assign("workspace", workspace),
        "mkdir -p \"$workspace/.symphony\"",
        "tmp=\"$workspace/#{@workspace_identity_marker}.tmp.$$\"",
        "printf '%s' #{shell_escape(marker_json)} > \"$tmp\"",
        "mv \"$tmp\" \"$workspace/#{@workspace_identity_marker}\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_marker_write_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp before_remove_issue_context(nil, workspace) do
    %{issue_id: nil, issue_identifier: Path.basename(workspace), project: nil}
  end

  defp before_remove_issue_context(%{issue_identifier: _issue_identifier} = issue_context, _workspace),
    do: issue_context

  defp before_remove_issue_context(issue_or_identifier, _workspace), do: issue_context(issue_or_identifier)

  defp removable_issue_context(%{identifier: identifier} = issue) when is_binary(identifier), do: issue_context(issue)
  defp removable_issue_context(identifier) when is_binary(identifier), do: issue_context(identifier)
  defp removable_issue_context(_issue_or_identifier), do: nil

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      project: normalize_issue_project(Map.get(issue, :project))
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      project: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      project: nil
    }
  end

  defp cleared_hook_env do
    [
      "SYMPHONY_WORKFLOW_DIR",
      "SYMPHONY_PROJECT_DIR",
      "SYMPHONY_PROJECT_SLUG",
      "SYMPHONY_REPO",
      "SYMPHONY_BASE_BRANCH",
      "SYMPHONY_PROFILE",
      "SYMPHONY_LINEAR_PROJECT_ID",
      "SYMPHONY_LINEAR_PROJECT_SLUG",
      "SYMPHONY_LINEAR_PROJECT_NAME"
    ]
    |> Enum.map(&{&1, nil})
  end

  defp remote_hook_env_exports(issue_context, project_env \\ nil) do
    hook_env_exports(issue_context, project_env)
  end

  defp hook_env_exports(issue_context, nil) do
    with {:ok, project_env} <- Workflow.resolve_project_env(issue_context) do
      hook_env_exports(issue_context, project_env)
    end
  end

  defp hook_env_exports(_issue_context, %{env: env}) when is_map(env) do
    exports =
      env
      |> Enum.sort_by(fn {name, _value} -> name end)
      |> Enum.map_join("\n", fn {name, value} ->
        "#{name}=#{shell_escape(value)}\nexport #{name}"
      end)

    {:ok,
     """
     unset SYMPHONY_PROJECT_DIR SYMPHONY_PROJECT_SLUG SYMPHONY_REPO SYMPHONY_BASE_BRANCH SYMPHONY_PROFILE SYMPHONY_LINEAR_PROJECT_ID SYMPHONY_LINEAR_PROJECT_SLUG SYMPHONY_LINEAR_PROJECT_NAME
     #{exports}
     """}
  end

  defp normalize_issue_project(%{id: _id, slug_id: _slug_id, name: _name} = project), do: project
  defp normalize_issue_project(_project), do: nil

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
