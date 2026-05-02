defmodule SymphonyElixir.ClaudeCode.StreamJson do
  @moduledoc """
  Experimental Claude Code CLI adapter using stream-json input and output.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576

  @type session_result :: %{
          result: map(),
          session_id: String.t(),
          thread_id: String.t(),
          turn_id: String.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, session_result()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, settings} <- Config.claude_code_runtime_settings(),
         {:ok, port} <- start_port(expanded_workspace, settings.command, worker_host) do
      metadata = port_metadata(port, worker_host)

      try do
        send_user_message(port, prompt)
        await_completion(port, on_message, settings.turn_timeout_ms, "", [], metadata)
      after
        stop_port(port)
      end
    else
      {:error, reason} ->
        Logger.warning("Claude Code session failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, command, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(launch_command(command))],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, command, worker_host) when is_binary(worker_host) do
    remote_command =
      [
        "cd #{shell_escape(workspace)}",
        launch_command(command)
      ]
      |> Enum.join(" && ")

    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp launch_command(command) when is_binary(command) do
    "IFS= read -r symphony_claude_code_input && printf '%s\\n' \"$symphony_claude_code_input\" | exec #{command}"
  end

  defp send_user_message(port, prompt) when is_port(port) do
    payload =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [
            %{
              "type" => "text",
              "text" => prompt
            }
          ]
        }
      })

    Port.command(port, [payload, "\n"])
  end

  defp await_completion(port, on_message, timeout_ms, pending_line, events, metadata) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_stream_line(port, on_message, timeout_ms, complete_line, events, metadata)

      {^port, {:data, {:noeol, chunk}}} ->
        await_completion(port, on_message, timeout_ms, pending_line <> to_string(chunk), events, metadata)

      {^port, {:exit_status, status}} ->
        {:error, {:claude_code_exit, status, Enum.reverse(events)}}
    after
      timeout_ms ->
        {:error, :claude_code_turn_timeout}
    end
  end

  defp handle_stream_line(port, on_message, timeout_ms, line, events, base_metadata) do
    payload_string = to_string(line)

    case Jason.decode(payload_string) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        metadata = metadata_from_message(base_metadata, payload)

        emit_message(
          on_message,
          :session_started,
          %{
            payload: payload,
            raw: payload_string,
            session_id: Map.get(payload, "session_id"),
            claude_code_model: Map.get(payload, "model"),
            claude_code_tools: Map.get(payload, "tools")
          },
          metadata
        )

        await_completion(port, on_message, timeout_ms, "", [payload | events], base_metadata)

      {:ok, %{"type" => "result"} = payload} ->
        metadata = metadata_from_message(base_metadata, payload)

        if successful_result?(payload) do
          emit_message(
            on_message,
            :turn_completed,
            %{payload: payload, raw: payload_string, details: payload},
            metadata
          )

          {:ok, session_result(payload)}
        else
          emit_message(
            on_message,
            :turn_failed,
            %{payload: payload, raw: payload_string, details: payload},
            metadata
          )

          {:error, {:claude_code_result, payload}}
        end

      {:ok, payload} ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: payload_string},
          metadata_from_message(base_metadata, payload)
        )

        await_completion(port, on_message, timeout_ms, "", [payload | events], base_metadata)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string)
        await_completion(port, on_message, timeout_ms, "", events, base_metadata)
    end
  end

  defp successful_result?(%{"subtype" => "success", "is_error" => false}), do: true
  defp successful_result?(%{"subtype" => "success"} = payload), do: Map.get(payload, "is_error") in [nil, false]
  defp successful_result?(_payload), do: false

  defp session_result(payload) do
    session_id = Map.get(payload, "session_id") || "claude-code-session"
    turn_id = payload |> Map.get("num_turns", 0) |> to_string()

    %{
      result: payload,
      session_id: session_id,
      thread_id: session_id,
      turn_id: turn_id
    }
  end

  defp metadata_from_message(base_metadata, payload) when is_map(payload) do
    base_metadata
    |> maybe_put(:session_id, Map.get(payload, "session_id"))
    |> maybe_put(:usage, Map.get(payload, "usage"))
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{claude_code_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp emit_message(on_message, event, details, metadata) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp stop_port(port) when is_port(port) do
    Port.close(port)
  catch
    :error, _reason -> :ok
  end

  defp log_non_json_stream_line(line) do
    Logger.debug("Claude Code stream output: #{String.slice(line, 0, 1_000)}")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue=unknown"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
