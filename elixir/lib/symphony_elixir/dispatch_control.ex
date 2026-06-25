defmodule SymphonyElixir.DispatchControl do
  @moduledoc """
  Durable scheduler pause marker, separate from issue workspaces.
  """

  require Logger

  alias SymphonyElixir.{LogFile, RunRegistry, Workflow}

  @spec paused?() :: boolean()
  def paused?, do: state().paused == true

  @spec pause(String.t() | nil) :: :ok
  def pause(reason \\ nil) do
    payload =
      %{
        paused: true,
        reason: normalize_reason(reason),
        paused_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        scope: %{
          profile: profile(),
          workflow_path: Workflow.workflow_file_path()
        }
      }
      |> Jason.encode!(pretty: true)

    path = file_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, payload <> "\n") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to write dispatch pause marker: #{inspect(reason)}")
        :ok
    end
  end

  @spec resume() :: :ok
  def resume do
    case File.rm(file_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Failed to remove dispatch pause marker: #{inspect(reason)}")
    end
  end

  @spec state() :: map()
  def state do
    path = file_path()

    if File.regular?(path) do
      paused_state(path)
    else
      %{paused: false, path: path, registry_path: RunRegistry.file_path()}
    end
  end

  @spec file_path() :: Path.t()
  def file_path do
    Application.get_env(:symphony_elixir, :dispatch_control_file) ||
      Path.join(runtime_dir(), "symphony-dispatch-paused-#{scope_hash()}.json")
  end

  defp paused_state(path) do
    base = %{paused: true, path: path, registry_path: RunRegistry.file_path()}

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = payload} ->
            Map.merge(base, %{
              reason: payload["reason"],
              paused_at: payload["paused_at"]
            })

          _ ->
            base
        end

      {:error, _reason} ->
        base
    end
  end

  defp normalize_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)
    if reason == "", do: nil, else: reason
  end

  defp normalize_reason(_reason), do: nil

  defp runtime_dir do
    Path.dirname(Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file()))
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
