defmodule SymphonyElixir.SubprocessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Subprocess

  @auth_names [
    "LINEAR_API_KEY",
    "LINEAR_CLIENT_ID",
    "LINEAR_CLIENT_SECRET",
    "CUSTOM_LINEAR_API_KEY",
    "CUSTOM_LINEAR_CLIENT_ID",
    "CUSTOM_LINEAR_CLIENT_SECRET"
  ]

  setup do
    previous = Map.new(@auth_names, &{&1, System.get_env(&1)})

    Enum.each(@auth_names, &System.put_env(&1, "parent-#{&1}"))
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$CUSTOM_LINEAR_API_KEY",
      tracker_client_id: "$CUSTOM_LINEAR_CLIENT_ID",
      tracker_client_secret: "$CUSTOM_LINEAR_CLIENT_SECRET"
    )

    :ok
  end

  test "cmd/3 clears standard and configured auth after caller env while preserving context" do
    command =
      "printf '%s|%s|%s|%s|%s|%s|%s' " <>
        Enum.map_join(@auth_names, " ", &"\"\${#{&1}-unset}\"") <>
        ~s( "$SAFE_CONTEXT")

    caller_env =
      Enum.map(@auth_names, &{&1, "caller-#{&1}"}) ++
        [{"SAFE_CONTEXT", "kept"}]

    assert {"unset|unset|unset|unset|unset|unset|kept", 0} =
             Subprocess.cmd("/bin/sh", ["-c", command], env: caller_env)
  end

  test "explicit auth names keep one scrub snapshot for cmd and Port spawns" do
    previous = System.get_env("SNAPSHOT_LINEAR_SECRET")
    System.put_env("SNAPSHOT_LINEAR_SECRET", "parent-secret")
    on_exit(fn -> restore_env("SNAPSHOT_LINEAR_SECRET", previous) end)

    assert {"unset", 0} =
             Subprocess.cmd(
               "/bin/sh",
               ["-c", ~s(printf '%s' "${SNAPSHOT_LINEAR_SECRET-unset}")],
               [],
               ["SNAPSHOT_LINEAR_SECRET"]
             )

    port =
      Subprocess.open_port(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          args: [~c"-c", ~c"printf '%s' \"${SNAPSHOT_LINEAR_SECRET-unset}\""]
        ],
        ["SNAPSHOT_LINEAR_SECRET"]
      )

    assert {0, "unset"} = collect_port(port)
  end

  test "open_port/2 clears standard and configured auth after caller env while preserving context" do
    previous_safe_nil = System.get_env("SAFE_NIL")
    previous_safe_false = System.get_env("SAFE_FALSE")
    System.put_env("SAFE_NIL", "parent")
    System.put_env("SAFE_FALSE", "parent")

    on_exit(fn ->
      restore_env("SAFE_NIL", previous_safe_nil)
      restore_env("SAFE_FALSE", previous_safe_false)
    end)

    command =
      "printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' " <>
        Enum.map_join(@auth_names, " ", &"\"\${#{&1}-unset}\"") <>
        ~s( "$SAFE_CONTEXT" "\${SAFE_NIL-unset}" "\${SAFE_FALSE-unset}")

    caller_env =
      Enum.map(@auth_names, &{String.to_charlist(&1), ~c"caller-override"}) ++
        [{~c"SAFE_CONTEXT", ~c"kept"}, {~c"SAFE_NIL", nil}, {~c"SAFE_FALSE", false}]

    port =
      Subprocess.open_port(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          args: [~c"-c", String.to_charlist(command)],
          env: caller_env
        ]
      )

    assert {0, "unset|unset|unset|unset|unset|unset|kept|unset|unset"} = collect_port(port)
  end

  test "cmd/3 fails closed before spawning when auth name resolution fails" do
    sentinel = Path.join(System.tmp_dir!(), "symphony-subprocess-cmd-#{System.unique_integer([:positive])}")
    File.write!(Workflow.workflow_file_path(), "---\npolling:\n  interval_ms: invalid\n---\n")
    WorkflowStore.force_reload()

    assert_raise ArgumentError, fn ->
      Subprocess.cmd("/bin/sh", ["-c", "touch \"$1\"", "sh", sentinel])
    end

    refute File.exists?(sentinel)
  end

  test "open_port/2 fails closed before spawning when auth name resolution fails" do
    sentinel = Path.join(System.tmp_dir!(), "symphony-subprocess-port-#{System.unique_integer([:positive])}")
    File.write!(Workflow.workflow_file_path(), "---\npolling:\n  interval_ms: invalid\n---\n")
    WorkflowStore.force_reload()

    assert_raise ArgumentError, fn ->
      Subprocess.open_port(
        {:spawn_executable, ~c"/bin/sh"},
        [:binary, :exit_status, args: [~c"-c", ~c"touch \"$1\"", ~c"sh", String.to_charlist(sentinel)]]
      )
    end

    refute File.exists?(sentinel)
  end

  test "Linear auth shell guard bypasses function shadowing and aborts on readonly credentials" do
    guard = Config.linear_auth_unset_command()

    assert {"unset", 0} =
             Subprocess.cmd("bash", ["-c", "unset() { :; }; export LINEAR_API_KEY=secret; #{guard}; printf '%s' \"${LINEAR_API_KEY-unset}\""])

    sentinel = Path.join(System.tmp_dir!(), "symphony-auth-guard-#{System.unique_integer([:positive])}")

    assert {_output, 126} =
             Subprocess.cmd(
               "bash",
               [
                 "-c",
                 "export LINEAR_API_KEY=secret; readonly LINEAR_API_KEY; #{guard}; touch \"$1\"",
                 "bash",
                 sentinel
               ],
               stderr_to_stdout: true
             )

    refute File.exists?(sentinel)
  end

  test "production runtime spawn primitives are owned only by Subprocess" do
    primitive_patterns = [
      ~r/System\.cmd/,
      ~r/System\.shell/,
      ~r/Port\.open/,
      ~r/:erlang\.open_port/,
      ~r/:os\.cmd/
    ]

    violations =
      "lib/symphony_elixir/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "/subprocess.ex"))
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        Enum.flat_map(primitive_patterns, fn pattern ->
          if Regex.match?(pattern, source), do: [{path, Regex.source(pattern)}], else: []
        end)
      end)

    assert violations == []
  end

  defp collect_port(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> collect_port(port, output <> data)
      {^port, {:exit_status, status}} -> {status, output}
    after
      1_000 -> flunk("timed out waiting for subprocess port")
    end
  end
end
