defmodule SymphonyElixir.SSHTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SSH

  @auth_names [
    "LINEAR_API_KEY",
    "LINEAR_CLIENT_ID",
    "LINEAR_CLIENT_SECRET",
    "CUSTOM_LINEAR_API_KEY",
    "CUSTOM_LINEAR_CLIENT_ID",
    "CUSTOM_LINEAR_CLIENT_SECRET"
  ]

  test "run/3 clears protected auth after caller env while preserving ordinary context" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-auth-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous = Map.new(@auth_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      restore_env("PATH", previous_path)
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf(test_root)
    end)

    Enum.each(@auth_names, &System.put_env(&1, "parent-#{&1}"))
    write_custom_auth_workflow!()

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf '%s|%s|%s|%s|%s|%s|%s' \
      "${LINEAR_API_KEY-unset}" \
      "${LINEAR_CLIENT_ID-unset}" \
      "${LINEAR_CLIENT_SECRET-unset}" \
      "${CUSTOM_LINEAR_API_KEY-unset}" \
      "${CUSTOM_LINEAR_CLIENT_ID-unset}" \
      "${CUSTOM_LINEAR_CLIENT_SECRET-unset}" \
      "${SAFE_CONTEXT-unset}" > "#{trace_file}"
    """)

    caller_env = Enum.map(@auth_names, &{&1, "caller-#{&1}"}) ++ [{"SAFE_CONTEXT", "kept"}]

    assert {:ok, {"", 0}} = SSH.run("worker", "printf ok", env: caller_env)
    assert File.read!(trace_file) == "unset|unset|unset|unset|unset|unset|kept"
  end

  test "start_port/3 clears protected auth after caller env while preserving ordinary context" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-auth-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous = Map.new(@auth_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      restore_env("PATH", previous_path)
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      File.rm_rf(test_root)
    end)

    Enum.each(@auth_names, &System.put_env(&1, "parent-#{&1}"))
    write_custom_auth_workflow!()

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf '%s|%s|%s|%s|%s|%s|%s' \
      "${LINEAR_API_KEY-unset}" \
      "${LINEAR_CLIENT_ID-unset}" \
      "${LINEAR_CLIENT_SECRET-unset}" \
      "${CUSTOM_LINEAR_API_KEY-unset}" \
      "${CUSTOM_LINEAR_CLIENT_ID-unset}" \
      "${CUSTOM_LINEAR_CLIENT_SECRET-unset}" \
      "${SAFE_CONTEXT-unset}" > "#{trace_file}"
    """)

    caller_env = Enum.map(@auth_names, &{&1, "caller-#{&1}"}) ++ [{"SAFE_CONTEXT", "kept"}]

    assert {:ok, port} = SSH.start_port("worker", "printf ok", env: caller_env)
    assert is_port(port)
    wait_for_trace!(trace_file)
    assert File.read!(trace_file) == "unset|unset|unset|unset|unset|unset|kept"
  end

  test "remote command clears login environment before executing the intended payload" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-remote-auth-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    write_custom_auth_workflow!()

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    remote_command=
    for arg do remote_command="$arg"; done
    export LINEAR_API_KEY=remote
    export LINEAR_CLIENT_ID=remote
    export LINEAR_CLIENT_SECRET=remote
    export CUSTOM_LINEAR_API_KEY=remote
    export CUSTOM_LINEAR_CLIENT_ID=remote
    export CUSTOM_LINEAR_CLIENT_SECRET=remote
    exec /bin/sh -c "$remote_command"
    """)

    payload =
      "printf '%s|%s|%s|%s|%s|%s' " <>
        Enum.map_join(@auth_names, " ", &"\"\${#{&1}-unset}\"")

    assert {:ok, {"unset|unset|unset|unset|unset|unset", 0}} =
             SSH.run("worker", payload, stderr_to_stdout: true)
  end

  test "run/3 uses one supplied auth-name snapshot for local and remote scrubbing" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-snapshot-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_secret = System.get_env("SNAPSHOT_LINEAR_SECRET")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SNAPSHOT_LINEAR_SECRET", previous_secret)
      File.rm_rf(test_root)
    end)

    System.put_env("SNAPSHOT_LINEAR_SECRET", "local-secret")

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    remote_command=
    for arg do remote_command="$arg"; done
    printf 'LOCAL:%s\n' "${SNAPSHOT_LINEAR_SECRET-unset}" > "#{trace_file}"
    export SNAPSHOT_LINEAR_SECRET=remote-secret
    exec /bin/sh -c "$remote_command"
    """)

    assert {:ok, {"REMOTE:unset", 0}} =
             SSH.run(
               "worker",
               ~s(printf 'REMOTE:%s' "${SNAPSHOT_LINEAR_SECRET-unset}"),
               linear_auth_env_names: ["SNAPSHOT_LINEAR_SECRET"]
             )

    assert File.read!(trace_file) == "LOCAL:unset\n"
  end

  test "run/3 keeps bracketed IPv6 host:port targets intact" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@[::1]:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@[::1] bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 leaves unbracketed IPv6-style targets unchanged" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-ipv6-raw-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("::1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T ::1:2200 bash -lc"
    refute trace =~ "-p 2200"
  end

  test "run/3 passes host:port targets through ssh -p" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)
    System.put_env("SYMPHONY_SSH_CONFIG", "/tmp/symphony-test-ssh-config")

    assert {:ok, {"", 0}} =
             SSH.run("localhost:2222", "echo ready", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-F /tmp/symphony-test-ssh-config"
    assert trace =~ "-T -p 2222 localhost bash -lc"
    assert trace =~ "echo ready"
  end

  test "run/3 keeps the user prefix when parsing user@host:port targets" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-user-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file)

    assert {:ok, {"", 0}} =
             SSH.run("root@127.0.0.1:2200", "printf ok", stderr_to_stdout: true)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2200 root@127.0.0.1 bash -lc"
    assert trace =~ "printf ok"
  end

  test "run/3 returns an error when ssh is unavailable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-missing-test-#{System.unique_integer([:positive])}")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root)

    assert {:error, :ssh_not_found} = SSH.run("localhost", "printf ok")
  end

  test "start_port/3 supports binary output without line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    System.delete_env("SYMPHONY_SSH_CONFIG")

    assert {:ok, port} = SSH.start_port("localhost", "printf ok")
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T localhost bash -lc"
    refute trace =~ " -F "
  end

  test "start_port/3 supports line mode" do
    test_root = Path.join(System.tmp_dir!(), "symphony-ssh-line-port-test-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    install_fake_ssh!(test_root, trace_file, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf 'ready\\n'
    exit 0
    """)

    assert {:ok, port} = SSH.start_port("localhost:2222", "printf ok", line: 256)
    assert is_port(port)
    wait_for_trace!(trace_file)

    trace = File.read!(trace_file)
    assert trace =~ "-T -p 2222 localhost bash -lc"
  end

  test "remote_shell_command/1 escapes embedded single quotes" do
    command = SSH.remote_shell_command("printf 'hello'")

    assert command =~ "command unset LINEAR_API_KEY LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET || exit 126\n"
    assert command =~ "printf '\"'\"'hello'\"'\"'"
  end

  defp install_fake_ssh!(test_root, trace_file, script \\ nil) do
    fake_bin_dir = Path.join(test_root, "bin")
    fake_ssh = Path.join(fake_bin_dir, "ssh")

    File.mkdir_p!(fake_bin_dir)

    File.write!(
      fake_ssh,
      script ||
        """
        #!/bin/sh
        printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
        exit 0
        """
    )

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin_dir <> ":" <> (System.get_env("PATH") || ""))
  end

  defp wait_for_trace!(trace_file, attempts \\ 120)
  defp wait_for_trace!(trace_file, 0), do: flunk("timed out waiting for fake ssh trace at #{trace_file}")

  defp wait_for_trace!(trace_file, attempts) do
    if File.exists?(trace_file) and File.read!(trace_file) != "" do
      :ok
    else
      Process.sleep(25)
      wait_for_trace!(trace_file, attempts - 1)
    end
  end

  defp write_custom_auth_workflow! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$CUSTOM_LINEAR_API_KEY",
      tracker_client_id: "$CUSTOM_LINEAR_CLIENT_ID",
      tracker_client_secret: "$CUSTOM_LINEAR_CLIENT_SECRET"
    )
  end
end
