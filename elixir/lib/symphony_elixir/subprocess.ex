defmodule SymphonyElixir.Subprocess do
  @moduledoc false

  alias SymphonyElixir.Config

  @spec cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    cmd(executable, args, opts, Config.linear_auth_env_names())
  end

  @spec cmd(String.t(), [String.t()], keyword(), [String.t()]) :: {String.t(), non_neg_integer()}
  def cmd(executable, args, opts, auth_names)
      when is_binary(executable) and is_list(args) and is_list(auth_names) do
    System.cmd(executable, args, put_env(opts, auth_names, :cmd))
  end

  @spec open_port(term(), list()) :: port()
  def open_port(name, opts) when is_list(opts) do
    open_port(name, opts, Config.linear_auth_env_names())
  end

  @spec open_port(term(), list(), [String.t()]) :: port()
  def open_port(name, opts, auth_names) when is_list(opts) and is_list(auth_names) do
    Port.open(name, put_env(opts, auth_names, :port))
  end

  defp put_env(opts, auth_names, target) do
    protected = MapSet.new(auth_names)

    caller_env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.reject(fn {name, _value} -> MapSet.member?(protected, to_string(name)) end)
      |> Enum.map(&normalize_env_entry(&1, target))

    cleared_env =
      Enum.map(auth_names, fn name ->
        case target do
          :cmd -> {name, nil}
          :port -> {String.to_charlist(name), false}
        end
      end)

    opts
    |> Enum.reject(&match?({:env, _value}, &1))
    |> then(&[{:env, caller_env ++ cleared_env} | &1])
  end

  defp normalize_env_entry(entry, :cmd), do: entry

  defp normalize_env_entry({name, value}, :port) do
    {String.to_charlist(to_string(name)), port_env_value(value)}
  end

  defp port_env_value(nil), do: false
  defp port_env_value(false), do: false
  defp port_env_value(value) when is_binary(value), do: String.to_charlist(value)
  defp port_env_value(value), do: value
end
