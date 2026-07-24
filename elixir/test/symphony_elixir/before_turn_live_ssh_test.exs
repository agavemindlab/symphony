defmodule SymphonyElixir.LiveSSHTestSupport do
  alias SymphonyElixir.SSH

  @docker_support_dir Path.expand("../support/live_e2e_docker", __DIR__)

  def with_worker(fun) when is_function(fun, 1) do
    root = Path.join([File.cwd!(), "tmp", "before-turn-live-ssh-#{System.unique_integer([:positive])}"])
    key = Path.join(root, "id_ed25519")
    config = Path.join(root, "ssh_config")
    container = "symphony-before-turn-#{System.unique_integer([:positive])}"
    previous_config = System.get_env("SYMPHONY_SSH_CONFIG")

    try do
      File.mkdir_p!(root)
      generate_key!(key)
      File.write!(config, ssh_config(key))
      System.put_env("SYMPHONY_SSH_CONFIG", config)

      image = docker!(["build", "--quiet", "."], cd: @docker_support_dir) |> String.trim()

      docker!([
        "run",
        "--detach",
        "--rm",
        "--name",
        container,
        "--publish",
        "127.0.0.1::22",
        "--volume",
        "#{key}.pub:/run/symphony/ssh/authorized_key.pub:ro",
        "--volume",
        "#{root}:#{root}",
        image
      ])

      port = docker!(["port", container, "22/tcp"]) |> String.trim() |> String.split(":") |> List.last()
      host = "localhost:#{port}"
      wait_for_ssh!(host, System.monotonic_time(:millisecond) + 60_000)
      fun.(%{host: host, root: root})
    after
      System.put_env("SYMPHONY_SSH_CONFIG", previous_config || "")
      if is_nil(previous_config), do: System.delete_env("SYMPHONY_SSH_CONFIG")
      _ = System.cmd("docker", ["rm", "--force", container], stderr_to_stdout: true)
      File.rm_rf(root)
    end
  end

  defp generate_key!(key) do
    case System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "ssh-keygen failed (#{status}): #{output}"
    end
  end

  defp ssh_config(key) do
    """
    Host localhost 127.0.0.1
      User root
      IdentityFile #{key}
      IdentitiesOnly yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    """
  end

  defp docker!(args, opts \\ []) do
    case System.cmd("docker", args, Keyword.merge([stderr_to_stdout: true], opts)) do
      {output, 0} -> output
      {output, status} -> raise "docker #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp wait_for_ssh!(host, deadline) do
    case SSH.run(host, "printf ready", stderr_to_stdout: true, batch_mode: true, connect_timeout_seconds: 2) do
      {:ok, {"ready", 0}} ->
        :ok

      result ->
        if deadline > System.monotonic_time(:millisecond) do
          Process.sleep(500)
          wait_for_ssh!(host, deadline)
        else
          raise "SSH worker did not become ready: #{inspect(result)}"
        end
    end
  end
end

defmodule SymphonyElixir.BeforeTurnLiveSSHTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LiveSSHTestSupport, SSH}

  @moduletag :live_ssh
  @moduletag timeout: 300_000
  @live_ssh_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_SSH") != "1",
                          do: "set SYMPHONY_RUN_LIVE_SSH=1 to enable the Docker OpenSSH test"
                        )
  @moduletag skip: @live_ssh_skip_reason

  test "real OpenSSH workers gate first and continuation turns without corrupting snapshots" do
    LiveSSHTestSupport.with_worker(fn worker ->
      assert_successful_turn_refresh!(worker)

      for phase <- [:first, :continuation], failure <- [:nonzero, :timeout] do
        assert_failed_turn_isolated!(worker, phase, failure)
      end
    end)
  end

  defp assert_successful_turn_refresh!(worker) do
    fixture = fixture!(worker.root, "success")

    write_workflow!(worker, fixture,
      hook_before_turn: snapshot_hook(fixture),
      max_turns: 2
    )

    issue = issue("LIVE-SSH-SUCCESS")
    fetch_key = {:live_ssh_fetches, fixture.canonical_repo}
    Process.delete(fetch_key)

    fetcher = fn [_id] ->
      count = Process.get(fetch_key, 0) + 1
      Process.put(fetch_key, count)
      if count == 1, do: commit_skill!(fixture.canonical_repo, "B")
      {:ok, [%{issue | state: if(count == 1, do: "In Progress", else: "Done")}]}
    end

    assert :ok = AgentRunner.run(issue, nil, worker_host: worker.host, issue_state_fetcher: fetcher)

    trace = File.read!(fixture.trace)
    assert trace =~ "SNAPSHOT:A"
    assert trace =~ "SNAPSHOT:B"
    assert count_turn_starts(trace) == 2
  end

  defp assert_failed_turn_isolated!(worker, phase, failure) do
    fixture = fixture!(worker.root, "#{phase}-#{failure}")
    issue = issue("LIVE-SSH-#{phase}-#{failure}")

    write_workflow!(worker, fixture,
      hook_before_turn: failing_snapshot_hook(fixture, phase, failure),
      hook_timeout_ms: 500,
      max_turns: 2
    )

    fetcher = fn [_id] -> {:ok, [issue]} end
    expected_error = if failure == :nonzero, do: ~r/workspace_hook_failed.*17/, else: ~r/workspace_hook_timeout.*500/

    assert_raise RuntimeError, expected_error, fn ->
      AgentRunner.run(issue, nil, worker_host: worker.host, issue_state_fetcher: fetcher)
    end

    workspace = Path.join(fixture.workspace_root, issue.identifier)
    snapshot = Path.join(workspace, ".agents/skills/demo/SKILL.md")

    if phase == :first do
      refute File.exists?(fixture.trace)
      refute File.exists?(snapshot)
    else
      assert count_turn_starts(File.read!(fixture.trace)) == 1
      assert File.read!(snapshot) == "A\n"
    end

    if failure == :timeout do
      pid_file = Path.join(workspace, "timeout-child.pid")

      assert {:ok, {_output, 0}} =
               SSH.run(worker.host, "pid=$(cat #{shell_escape(pid_file)}); ! kill -0 \"$pid\" 2>/dev/null",
                 stderr_to_stdout: true,
                 batch_mode: true,
                 connect_timeout_seconds: 2
               )

      Process.sleep(1_100)
      refute File.exists?(Path.join(workspace, "late-marker"))
    end
  end

  defp fixture!(root, name) do
    scenario_root = Path.join(root, name)
    canonical_repo = Path.join(scenario_root, "canonical")
    workspace_root = Path.join(scenario_root, "workspaces")
    codex = Path.join(scenario_root, "fake-codex")
    trace = Path.join(scenario_root, "codex.trace")
    helper = Path.join(canonical_repo, "snapshot-shared-skills.sh")

    File.mkdir_p!(Path.join(canonical_repo, "skills/demo"))
    File.mkdir_p!(workspace_root)
    File.cp!(Path.expand("../../../workflows/agavemindlab/snapshot-shared-skills.sh", __DIR__), helper)
    File.chmod!(helper, 0o755)
    git!(canonical_repo, ["init", "-q"])
    git!(canonical_repo, ["config", "user.email", "live-ssh@example.invalid"])
    git!(canonical_repo, ["config", "user.name", "Live SSH Test"])
    commit_skill!(canonical_repo, "A")

    File.write!(codex, fake_codex_script(trace))
    File.chmod!(codex, 0o755)

    %{
      canonical_repo: canonical_repo,
      codex: codex,
      helper: helper,
      skills: Path.join(canonical_repo, "skills"),
      trace: trace,
      workspace_root: workspace_root
    }
  end

  defp write_workflow!(worker, fixture, overrides) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: fixture.workspace_root,
          worker_ssh_hosts: [worker.host],
          codex_command: "#{fixture.codex} app-server",
          hook_after_create: "git init -q"
        ],
        overrides
      )
    )
  end

  defp snapshot_hook(fixture) do
    "#{shell_escape(fixture.helper)} #{shell_escape(fixture.skills)}"
  end

  defp failing_snapshot_hook(fixture, phase, failure) do
    failure_turn = if phase == :first, do: 1, else: 2

    """
    n=$(cat .before-turn-count 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > .before-turn-count
    if [ "$n" -eq #{failure_turn} ]; then #{failure_command(failure)}; fi
    #{snapshot_hook(fixture)}
    """
  end

  defp failure_command(:nonzero), do: "exit 17"

  defp failure_command(:timeout) do
    "(trap '' TERM; sleep 10; printf late > late-marker) & child=$!; echo \"$child\" > timeout-child.pid; trap 'exit 0' TERM; wait $child"
  end

  defp commit_skill!(repo, version) do
    File.write!(Path.join(repo, "skills/demo/SKILL.md"), version <> "\n")
    git!(repo, ["add", "skills/demo/SKILL.md"])
    git!(repo, ["commit", "-qm", "skill #{version}"])
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp fake_codex_script(trace) do
    """
    #!/bin/sh
    trace=#{shell_escape(trace)}
    printf 'PROCESS\n' >> "$trace"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\n' "$line" >> "$trace"
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-live-ssh"}}}' ;;
        4) printf 'SNAPSHOT:' >> "$trace"; cat .agents/skills/demo/SKILL.md >> "$trace"; printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'; printf '%s\n' '{"method":"turn/completed"}' ;;
        5) printf 'SNAPSHOT:' >> "$trace"; cat .agents/skills/demo/SKILL.md >> "$trace"; printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-2"}}}'; printf '%s\n' '{"method":"turn/completed"}' ;;
      esac
    done
    """
  end

  defp count_turn_starts(trace) do
    trace
    |> String.split("\n", trim: true)
    |> Enum.count(&String.contains?(&1, "\"method\":\"turn/start\""))
  end

  defp issue(suffix) do
    %Issue{
      id: "issue-#{suffix}",
      identifier: "MT-#{suffix}",
      title: "before turn #{suffix}",
      state: "In Progress",
      labels: []
    }
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
