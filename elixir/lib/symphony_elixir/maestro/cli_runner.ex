defmodule SymphonyElixir.Maestro.CliRunner do
  @moduledoc """
  Small timeout-aware wrapper for one-shot CLI calls used by Maestro.
  """

  @default_timeout_ms 30_000

  @type run_result :: {:ok, String.t()} | {:error, term()}

  @spec run(String.t(), [String.t()], keyword()) :: run_result()
  def run(command, args, opts \\ []) when is_binary(command) and is_list(args) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case System.find_executable(command) do
      nil -> {:error, {:missing_executable, command}}
      executable -> run_executable(executable, args, timeout_ms)
    end
  end

  defp run_executable(executable, args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(executable, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:exit_status, status, output}}
      nil -> {:error, :timeout}
    end
  end
end
