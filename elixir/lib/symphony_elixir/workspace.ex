defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Analytics, Config, PathSafety, SSH, Workflow}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_workspace_inspect_marker "__SYMPHONY_WORKSPACE_INSPECT__"
  @remote_workspace_path_marker "__SYMPHONY_WORKSPACE_PATH__"
  @remote_workspace_identity_marker "__SYMPHONY_WORKSPACE_MARKER__"
  @remote_workspace_remote_marker "__SYMPHONY_WORKSPACE_REMOTE__"
  @remote_workspace_marker_write "__SYMPHONY_WORKSPACE_MARKER_WRITE__"
  @workspace_identity_marker ".symphony/workspace-identity.json"
  @workspace_identity_version 1
  @workspace_identity_max_bytes 65_536

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
           :ok <-
             initialize_workspace(workspace, issue_context, expected_identity, created?, worker_host, project_env) do
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

  defp handle_remote_workspace_identity_status({:reject, reason}, _inspection, _workspace, _expected_identity, _worker_host) do
    {:error, {:workspace_symlink_escape, reason}}
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
        remote_shell_assign("root", Config.settings!().workspace.root),
        "mkdir -p \"$root\"",
        "root_canonical=\"$(cd \"$root\" && pwd -P)\"",
        "if [ -L \"$workspace\" ]; then",
        "  rm -f \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "elif [ -d \"$workspace\" ]; then",
        "  workspace_canonical=\"$(cd \"$workspace\" && pwd -P)\"",
        "  case \"$workspace_canonical/\" in",
        "    \"$root_canonical\"/*) created=0 ;;",
        "    *) rm -rf \"$workspace\"; mkdir -p \"$workspace\"; created=1 ;;",
        "  esac",
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
    run_before_run_hook(workspace, issue_or_identifier, worker_host, nil)
  end

  @doc false
  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), Workflow.resolved_project_env() | nil) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host, project_env) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host, project_env)
    end
  end

  @doc false
  @spec validate_identity(Path.t(), map() | String.t() | nil, Workflow.resolved_project_env(), worker_host()) ::
          :ok | {:error, term()}
  def validate_identity(workspace, issue_or_identifier, project_env, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    with {:ok, expected_identity} <- expected_workspace_identity(issue_context, project_env),
         :ok <- validate_workspace_path(workspace, worker_host) do
      validate_current_identity(workspace, expected_identity, worker_host)
    end
  end

  defp validate_current_identity(_workspace, nil, _worker_host), do: :ok

  defp validate_current_identity(workspace, expected_identity, nil) do
    case existing_workspace_identity_status(workspace, expected_identity, nil) do
      :reuse -> :ok
      status -> {:error, {:workspace_identity_changed, status}}
    end
  end

  defp validate_current_identity(workspace, expected_identity, worker_host) when is_binary(worker_host) do
    with {:ok, inspection} <- inspect_remote_workspace(workspace, worker_host) do
      case remote_workspace_identity_status(inspection, expected_identity) do
        :reuse -> :ok
        status -> {:error, {:workspace_identity_changed, status}}
      end
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    run_after_run_hook(workspace, issue_or_identifier, worker_host, nil)
  end

  @doc false
  @spec run_after_run_hook(
          Path.t(),
          map() | String.t() | nil,
          worker_host(),
          Workflow.resolved_project_env() | nil
        ) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host, project_env) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host, project_env)
        |> ignore_hook_failure("after_run", issue_context)
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(Config.settings!().workspace.root) do
      {:ok, Path.join(canonical_root, safe_id)}
    end
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp initialize_workspace(_workspace, _issue_context, _expected_identity, false, _worker_host, _project_env), do: :ok

  defp initialize_workspace(workspace, issue_context, expected_identity, true, worker_host, project_env) do
    result =
      with :ok <- maybe_run_after_create_hook(workspace, issue_context, worker_host, project_env) do
        write_workspace_identity_marker(workspace, expected_identity, worker_host)
      end

    if result != :ok, do: cleanup_failed_created_workspace(workspace, worker_host, issue_context)
    result
  end

  defp maybe_run_after_create_hook(workspace, issue_context, worker_host, project_env) do
    hooks = Config.settings!().hooks

    case hooks.after_create do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_create", worker_host, project_env)
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
            |> ignore_hook_failure("before_remove", issue_context)
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
        |> ignore_hook_failure("before_remove", issue_context)
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

  defp ignore_hook_failure(:ok, _hook_name, _issue_context), do: :ok

  defp ignore_hook_failure({:error, _reason}, hook_name, issue_context) do
    record_hook_failed_event(hook_name, issue_context)
    :ok
  end

  defp record_hook_failed_event(hook_name, issue_context) do
    Analytics.record_event(%{
      event_type: "hook_failed",
      hook: hook_name,
      issue_id: Map.get(issue_context, :issue_id),
      issue_identifier: Map.get(issue_context, :issue_identifier)
    })
  rescue
    error ->
      Logger.warning("Failed to record hook_failed analytics event hook=#{hook_name} #{issue_log_context(issue_context)}: #{Exception.message(error)}")
      :ok
  end

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

    missing_keys =
      [{"SYMPHONY_PROJECT_SLUG", project_slug}, {"SYMPHONY_REPO", repo}]
      |> Enum.filter(fn {_key, value} -> blank?(value) end)
      |> Enum.map(fn {key, _value} -> key end)

    if missing_keys == [] do
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
    else
      {:error, {:workspace_identity_missing_project_env, missing_keys}}
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
  defp remote_workspace_identity_status(%{kind: :link}, _expected_identity), do: {:quarantine, :workspace_symlink}
  defp remote_workspace_identity_status(%{kind: :escape}, _expected_identity), do: {:reject, :intermediate_symlink}
  defp remote_workspace_identity_status(%{kind: :unsafe_marker}, _expected_identity), do: {:quarantine, :unsafe_marker}

  defp remote_workspace_identity_status(%{kind: :dir} = inspection, expected_identity) do
    case Map.get(inspection, :marker) do
      marker_json when is_binary(marker_json) ->
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
    with {:ok, marker_path} <- safe_workspace_identity_marker_path(workspace) do
      case File.open(marker_path, [:read, :binary], &IO.binread(&1, @workspace_identity_max_bytes + 1)) do
        {:ok, :eof} -> Jason.decode("")
        {:ok, content} when byte_size(content) <= @workspace_identity_max_bytes -> Jason.decode(content)
        {:ok, _content} -> {:error, :marker_too_large}
        {:error, :enoent} -> {:error, :missing_marker}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp infer_workspace_repo(workspace) when is_binary(workspace) do
    ["upstream", "origin"]
    |> Enum.find_value({:error, :unknown_remote}, fn remote ->
      case run_local_command("git", ["-C", workspace, "remote", "get-url", remote]) do
        {:ok, {url, 0}} -> normalize_repo_from_remote(String.trim(url))
        _ -> nil
      end
    end)
  end

  defp run_local_command(command, args) when is_binary(command) and is_list(args) do
    case System.find_executable(command) do
      nil ->
        {:error, :executable_not_found}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        timeout_ms = Config.settings!().hooks.timeout_ms
        receive_local_command(port, [], System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp receive_local_command(port, output, deadline_ms) do
    timeout_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_local_command(port, [data | output], deadline_ms)

      {^port, {:exit_status, status}} ->
        {:ok, {output |> Enum.reverse() |> IO.iodata_to_binary(), status}}
    after
      timeout_ms ->
        if Port.info(port), do: Port.close(port)
        {:error, :timeout}
    end
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
        remote_shell_assign("root", Config.settings!().workspace.root),
        "mkdir -p \"$root\"",
        "root_canonical=\"$(cd \"$root\" && pwd -P)\"",
        "if [ -L \"$workspace\" ]; then",
        "  printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'link'",
        "elif [ -d \"$workspace\" ]; then",
        "  workspace_canonical=\"$(cd \"$workspace\" && pwd -P)\"",
        "  case \"$workspace_canonical/\" in",
        "    \"$root_canonical\"/*) ;;",
        "    *)",
        "      printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'escape'",
        "      printf '%s\\t' '#{@remote_workspace_path_marker}'",
        "      printf '%s' \"$workspace_canonical\" | base64 | tr -d '\\n'",
        "      printf '\\n'",
        "      exit 0",
        "      ;;",
        "  esac",
        "  marker_dir=\"$workspace/.symphony\"",
        "  marker=\"$workspace/#{@workspace_identity_marker}\"",
        "  unsafe=0",
        "  if [ -L \"$marker_dir\" ] || { [ -e \"$marker_dir\" ] && [ ! -d \"$marker_dir\" ]; } ||",
        "     [ -L \"$marker\" ] || { [ -e \"$marker\" ] && [ ! -f \"$marker\" ]; }; then",
        "    unsafe=1",
        "  elif [ -f \"$marker\" ] && [ \"$(wc -c < \"$marker\" | tr -d '[:space:]')\" -gt #{@workspace_identity_max_bytes} ]; then",
        "    unsafe=1",
        "  fi",
        "  remote_url=\"$(git -C \"$workspace\" remote get-url upstream 2>/dev/null || git -C \"$workspace\" remote get-url origin 2>/dev/null || true)\"",
        "  if [ \"${#remote_url}\" -gt 4096 ]; then unsafe=1; fi",
        "  if [ \"$unsafe\" -eq 1 ]; then",
        "    printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'unsafe_marker'",
        "  else",
        "    printf '%s\\t%s\\n' '#{@remote_workspace_inspect_marker}' 'dir'",
        "    printf '%s\\t' '#{@remote_workspace_path_marker}'",
        "    printf '%s' \"$workspace_canonical\" | base64 | tr -d '\\n'",
        "    printf '\\n'",
        "    if [ -f \"$marker\" ]; then",
        "      printf '%s\\t' '#{@remote_workspace_identity_marker}'",
        "      base64 < \"$marker\" | tr -d '\\n'",
        "      printf '\\n'",
        "    fi",
        "    if [ -n \"$remote_url\" ]; then",
        "      printf '%s\\t' '#{@remote_workspace_remote_marker}'",
        "      printf '%s' \"$remote_url\" | base64 | tr -d '\\n'",
        "      printf '\\n'",
        "    fi",
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
    result =
      output
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, %{}}, &put_remote_workspace_inspection_line/2)

    case result do
      {:ok, %{kind: kind} = inspection} when kind in [:dir, :other, :missing, :link, :escape, :unsafe_marker] ->
        {:ok, inspection}

      _result ->
        {:error, {:workspace_inspect_failed, :invalid_output, output}}
    end
  end

  defp put_remote_workspace_inspection_line(line, {:ok, acc}) do
    case String.split(line, "\t", parts: 2) do
      [@remote_workspace_inspect_marker, kind] -> put_remote_workspace_kind(acc, kind)
      [@remote_workspace_path_marker, encoded] -> put_remote_workspace_field(acc, :path, encoded)
      [@remote_workspace_identity_marker, encoded] -> put_remote_workspace_field(acc, :marker, encoded)
      [@remote_workspace_remote_marker, encoded] -> put_remote_workspace_field(acc, :remote, encoded)
      _ -> {:cont, {:ok, acc}}
    end
  end

  defp put_remote_workspace_kind(acc, kind) when kind in ["dir", "other", "missing", "link", "escape", "unsafe_marker"] do
    put_remote_workspace_value(acc, :kind, String.to_existing_atom(kind))
  end

  defp put_remote_workspace_kind(_acc, _kind), do: {:halt, {:error, :invalid_kind}}

  defp put_remote_workspace_field(acc, key, encoded) do
    case Base.decode64(encoded) do
      {:ok, value} -> put_remote_workspace_value(acc, key, value)
      :error -> {:halt, {:error, :invalid_base64}}
    end
  end

  defp put_remote_workspace_value(acc, key, value) do
    if Map.has_key?(acc, key) do
      {:halt, {:error, {:duplicate_field, key}}}
    else
      {:cont, {:ok, Map.put(acc, key, value)}}
    end
  end

  defp quarantine_remote_workspace(workspace, worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -e \"$workspace\" ] || [ -L \"$workspace\" ]; then",
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

  defp write_workspace_identity_marker(_workspace, nil, _worker_host), do: :ok

  defp write_workspace_identity_marker(workspace, expected_identity, nil) do
    marker_dir = Path.join(workspace, ".symphony")

    with {:ok, _marker_path} <- safe_workspace_identity_marker_path(workspace),
         :ok <- File.mkdir_p(marker_dir),
         {:ok, marker_path} <- safe_workspace_identity_marker_path(workspace) do
      atomic_write(marker_path, Jason.encode!(expected_identity))
    end
  end

  defp write_workspace_identity_marker(workspace, expected_identity, worker_host) when is_binary(worker_host) do
    marker_json = Jason.encode!(expected_identity)

    script =
      [
        "set -eu",
        "printf '%s\\n' '#{@remote_workspace_marker_write}'",
        remote_shell_assign("workspace", workspace),
        remote_shell_assign("root", Config.settings!().workspace.root),
        "[ ! -L \"$workspace\" ]",
        "root_canonical=\"$(cd \"$root\" && pwd -P)\"",
        "workspace_canonical=\"$(cd \"$workspace\" && pwd -P)\"",
        "case \"$workspace_canonical/\" in \"$root_canonical\"/*) ;; *) exit 65 ;; esac",
        "marker_dir=\"$workspace/.symphony\"",
        "marker=\"$workspace/#{@workspace_identity_marker}\"",
        "[ ! -L \"$marker_dir\" ] && [ ! -L \"$marker\" ]",
        "{ [ ! -e \"$marker_dir\" ] || [ -d \"$marker_dir\" ]; }",
        "{ [ ! -e \"$marker\" ] || [ -f \"$marker\" ]; }",
        "mkdir -p \"$marker_dir\"",
        "marker_dir_canonical=\"$(cd \"$marker_dir\" && pwd -P)\"",
        "case \"$marker_dir_canonical/\" in \"$workspace_canonical\"/*) ;; *) exit 65 ;; esac",
        "tmp=\"$marker.tmp.$$\"",
        "trap 'rm -f \"$tmp\"' EXIT",
        "set -C",
        "printf '%s' #{shell_escape(marker_json)} > \"$tmp\"",
        "set +C",
        "mv \"$tmp\" \"$marker\"",
        "trap - EXIT"
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
    Enum.map(Workflow.project_env_keys(), &{&1, nil})
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
     unset #{Enum.join(Workflow.project_env_keys(), " ")}
     #{exports}
     """}
  end

  defp safe_workspace_identity_marker_path(workspace) do
    marker_dir = Path.join(workspace, ".symphony")
    marker_path = Path.join(workspace, @workspace_identity_marker)

    with :ok <- reject_symlink(workspace),
         :ok <- validate_workspace_path(workspace, nil),
         :ok <- validate_marker_dir(marker_dir),
         :ok <- validate_marker_file(marker_path),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_marker} <- PathSafety.canonicalize(marker_path),
         true <- String.starts_with?(canonical_marker, canonical_workspace <> "/") do
      {:ok, marker_path}
    else
      false -> {:error, :unsafe_marker_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_marker_path}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_marker_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :unsafe_marker_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_marker_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :unsafe_marker_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_write(path, content) do
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with {:ok, :ok} <- File.open(tmp, [:write, :exclusive], &IO.binwrite(&1, content)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp normalize_issue_project(%{id: _id, slug_id: _slug_id, name: _name} = project), do: project
  defp normalize_issue_project(_project), do: nil

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
