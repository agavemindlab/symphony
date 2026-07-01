defmodule SymphonyElixir.RunRegistry do
  @moduledoc """
  Durable active-run registry used to resume Codex threads after restart.
  """

  require Logger

  alias SymphonyElixir.{LogFile, Workflow}

  @schema_version 1
  @entry_keys %{
    "issue_id" => :issue_id,
    "identifier" => :identifier,
    "issue_url" => :issue_url,
    "workspace_path" => :workspace_path,
    "worker_host" => :worker_host,
    "thread_id" => :thread_id,
    "session_id" => :session_id,
    "attempt" => :attempt,
    "started_at" => :started_at,
    "updated_at" => :updated_at,
    "workflow_path" => :workflow_path,
    "profile" => :profile,
    "project" => :project
  }

  @spec load() :: [map()]
  def load do
    path = file_path()

    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"entries" => entries}} when is_list(entries) <- Jason.decode(content) do
      Enum.map(entries, &atomize_entry/1)
    else
      false ->
        []

      {:error, reason} ->
        Logger.warning("Failed to load run registry: #{inspect(reason)}")
        []

      _ ->
        Logger.warning("Ignoring malformed run registry at #{path}")
        []
    end
  end

  @spec upsert(map()) :: :ok
  def upsert(entry) when is_map(entry) do
    issue_id = entry[:issue_id] || entry["issue_id"]

    entries =
      load()
      |> Enum.reject(&((Map.get(&1, :issue_id) || Map.get(&1, "issue_id")) == issue_id))
      |> Kernel.++([entry])

    replace_entries(entries)
  end

  @spec delete(String.t()) :: :ok
  def delete(issue_id) when is_binary(issue_id) do
    load()
    |> Enum.reject(&(Map.get(&1, :issue_id) == issue_id))
    |> replace_entries()
  end

  @spec replace_entries([map()]) :: :ok
  def replace_entries(entries) when is_list(entries) do
    payload =
      %{
        schema_version: @schema_version,
        scope: scope(),
        entries: Enum.map(entries, &stringify_entry/1)
      }
      |> Jason.encode!(pretty: true)

    write_file(file_path(), payload)
  end

  @spec file_path() :: Path.t()
  def file_path do
    Application.get_env(:symphony_elixir, :run_registry_file) ||
      Path.join(runtime_dir(), "symphony-run-registry-#{scope_hash()}.json")
  end

  defp write_file(path, payload) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        write_payload(path, payload)

      {:error, reason} ->
        Logger.warning("Failed to create run registry directory: #{inspect(reason)}")
        :ok
    end
  end

  defp write_payload(path, payload) do
    tmp_path = "#{path}.#{System.unique_integer([:positive])}.tmp"

    # ponytail: single orchestrator writer; add file locking if multiple writers appear.
    case File.write(tmp_path, payload <> "\n") do
      :ok ->
        rename_payload(tmp_path, path)

      {:error, reason} ->
        log_write_failure(tmp_path, path, reason)
    end
  end

  defp rename_payload(tmp_path, path) do
    case File.rename(tmp_path, path) do
      :ok -> :ok
      {:error, reason} -> log_write_failure(tmp_path, path, reason)
    end
  end

  defp log_write_failure(tmp_path, path, reason) do
    _ = File.rm(tmp_path)
    Logger.warning("Failed to write run registry #{path}: #{inspect(reason)}")
    :ok
  end

  defp stringify_entry(entry) when is_map(entry) do
    now = DateTime.utc_now()

    entry
    |> Map.new(fn {key, value} -> {to_string(key), json_value(value)} end)
    |> Map.put_new("updated_at", DateTime.to_iso8601(now))
    |> Map.put_new("started_at", DateTime.to_iso8601(now))
    |> Map.put("workflow_path", Workflow.workflow_file_path())
    |> Map.put("profile", profile())
  end

  defp json_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json_value(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), json_value(value)} end)
  defp json_value(values) when is_list(values), do: Enum.map(values, &json_value/1)
  defp json_value(value), do: value

  defp atomize_entry(entry) when is_map(entry) do
    Map.new(entry, fn {key, value} ->
      {Map.get(@entry_keys, key, key), parsed_value(key, value)}
    end)
  end

  defp parsed_value(key, value) when key in ["started_at", "updated_at"] and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp parsed_value(_key, value), do: value

  defp runtime_dir do
    Path.dirname(Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file()))
  end

  defp scope do
    %{
      "profile" => profile(),
      "workflow_path" => Workflow.workflow_file_path()
    }
  end

  defp profile do
    case System.get_env("SYMPHONY_PROFILE") do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp scope_hash do
    :crypto.hash(:sha256, "#{profile()}:#{Workflow.workflow_file_path()}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end
end
