defmodule SymphonyElixir.BeforeTurnTest do
  use SymphonyElixir.TestSupport

  test "local and SSH workers run before_turn before first and continuation turns" do
    with_fake_ssh(fn ->
      for worker_host <- [nil, "worker-test"] do
        root = tmp_dir("before-turn-success")

        try do
          %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            worker_ssh_hosts: List.wrap(worker_host),
            codex_command: "#{codex} app-server",
            hook_before_turn: "n=$(cat .before-turn-count 2>/dev/null || echo 0); n=$((n + 1)); echo $n > .before-turn-count; printf 'HOOK:%s\\n' \"$n\" >> #{trace}",
            max_turns: 2
          )

          issue = issue("SUCCESS-#{worker_host || "local"}")
          Process.delete({:fetches, worker_host})

          fetcher = fn [_id] ->
            count = Process.get({:fetches, worker_host}, 0) + 1
            Process.put({:fetches, worker_host}, count)
            {:ok, [%{issue | state: if(count == 1, do: "In Progress", else: "Done")}]}
          end

          assert :ok = AgentRunner.run(issue, nil, worker_host: worker_host, issue_state_fetcher: fetcher)

          lines = File.read!(trace) |> String.split("\n", trim: true)
          assert Enum.at(lines, 0) == "HOOK:1"
          assert Enum.count(lines, &(&1 == "HOOK:2")) == 1

          turn_starts =
            lines
            |> Enum.with_index()
            |> Enum.filter(fn {line, _index} -> String.contains?(line, "\"method\":\"turn/start\"") end)
            |> Enum.map(&elem(&1, 1))

          assert Enum.find_index(lines, &(&1 == "HOOK:2")) >
                   hd(turn_starts)

          assert Enum.find_index(lines, &(&1 == "HOOK:2")) < List.last(turn_starts)
          assert length(turn_starts) == 2
        after
          File.rm_rf(root)
        end
      end
    end)
  end

  test "local and SSH continuation hook failures prevent the next turn" do
    with_fake_ssh(fn ->
      for worker_host <- [nil, "worker-test"] do
        root = tmp_dir("before-turn-failure")

        try do
          %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)
          after_run = Path.join(root, "after-run.trace")

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            worker_ssh_hosts: List.wrap(worker_host),
            codex_command: "#{codex} app-server",
            hook_before_turn: "n=$(cat .before-turn-count 2>/dev/null || echo 0); n=$((n + 1)); echo $n > .before-turn-count; [ $n -lt 2 ] || exit 17",
            hook_after_run: "printf 'after\\n' >> #{after_run}",
            max_turns: 2
          )

          issue = issue("FAIL-#{worker_host || "local"}")
          fetcher = fn [_id] -> {:ok, [issue]} end

          assert_raise RuntimeError, ~r/workspace_hook_failed.*before_turn.*17/, fn ->
            AgentRunner.run(issue, nil, worker_host: worker_host, issue_state_fetcher: fetcher)
          end

          assert File.read!(trace)
                 |> String.split("\n", trim: true)
                 |> Enum.count(&String.contains?(&1, "\"method\":\"turn/start\"")) == 1

          assert File.read!(after_run) == "after\n"
        after
          File.rm_rf(root)
        end
      end
    end)
  end

  test "local and SSH first-turn hook failures prevent Codex startup" do
    with_fake_ssh(fn ->
      for worker_host <- [nil, "worker-test"] do
        root = tmp_dir("before-turn-first-failure")

        try do
          %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)
          after_run = Path.join(root, "after-run.trace")

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            worker_ssh_hosts: List.wrap(worker_host),
            codex_command: "#{codex} app-server",
            hook_before_turn: "exit 17",
            hook_after_run: "printf 'after\\n' >> #{after_run}"
          )

          assert_raise RuntimeError, ~r/workspace_hook_failed.*before_turn.*17/, fn ->
            AgentRunner.run(issue("FIRST-FAILURE-#{worker_host || "local"}"), nil, worker_host: worker_host)
          end

          refute File.exists?(trace)
          assert File.read!(after_run) == "after\n"
        after
          File.rm_rf(root)
        end
      end
    end)
  end

  test "local and SSH hook exit 124 is reported as a failure rather than a timeout" do
    with_fake_ssh(fn ->
      for worker_host <- [nil, "worker-test"] do
        root = tmp_dir("before-turn-exit-124")

        try do
          %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            worker_ssh_hosts: List.wrap(worker_host),
            codex_command: "#{codex} app-server",
            hook_before_turn: "exit 124"
          )

          assert_raise RuntimeError, ~r/workspace_hook_failed.*before_turn.*124/, fn ->
            AgentRunner.run(issue("EXIT-124-#{worker_host || "local"}"), nil, worker_host: worker_host)
          end

          refute File.exists?(trace)
        after
          File.rm_rf(root)
        end
      end
    end)
  end

  test "local and SSH first-turn hook timeouts prevent Codex startup" do
    with_fake_ssh(fn ->
      for worker_host <- [nil, "worker-test"] do
        root = tmp_dir("before-turn-timeout")

        try do
          %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            worker_ssh_hosts: List.wrap(worker_host),
            codex_command: "#{codex} app-server",
            hook_before_turn: "sleep 1; printf late > late-marker",
            hook_timeout_ms: 500
          )

          assert_raise RuntimeError, ~r/workspace_hook_timeout.*before_turn.*500/, fn ->
            AgentRunner.run(issue("TIMEOUT-#{worker_host || "local"}"), nil, worker_host: worker_host)
          end

          refute File.exists?(trace)
          Process.sleep(1_100)
          assert Path.wildcard(Path.join(workspace_root, "**/late-marker")) == []
        after
          File.rm_rf(root)
        end
      end
    end)
  end

  test "local and SSH continuation hook timeouts prevent the next turn" do
    with_fake_ssh(fn ->
      for worker_host <- [nil, "worker-test"] do
        root = tmp_dir("before-turn-continuation-timeout")

        try do
          %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)

          write_workflow_file!(Workflow.workflow_file_path(),
            workspace_root: workspace_root,
            worker_ssh_hosts: List.wrap(worker_host),
            codex_command: "#{codex} app-server",
            hook_before_turn: "n=$(cat .before-turn-count 2>/dev/null || echo 0); n=$((n + 1)); echo $n > .before-turn-count; [ $n -lt 2 ] || { sleep 1; printf late > late-marker; }",
            hook_timeout_ms: 500,
            max_turns: 2
          )

          issue = issue("CONTINUATION-TIMEOUT-#{worker_host || "local"}")
          fetcher = fn [_id] -> {:ok, [issue]} end

          assert_raise RuntimeError, ~r/workspace_hook_timeout.*before_turn.*500/, fn ->
            AgentRunner.run(issue, nil, worker_host: worker_host, issue_state_fetcher: fetcher)
          end

          assert File.read!(trace)
                 |> String.split("\n", trim: true)
                 |> Enum.count(&String.contains?(&1, "\"method\":\"turn/start\"")) == 1

          Process.sleep(1_100)
          assert Path.wildcard(Path.join(workspace_root, "**/late-marker")) == []
        after
          File.rm_rf(root)
        end
      end
    end)
  end

  test "SSH timeout waits for remote TERM-resistant hook termination" do
    with_fake_ssh(fn ->
      root = tmp_dir("before-turn-ssh-term-resistant")

      try do
        %{codex: codex, trace: trace, workspace_root: workspace_root} = fixture!(root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          worker_ssh_hosts: ["worker-test"],
          codex_command: "#{codex} app-server",
          hook_before_turn: "(trap '' TERM; sleep 10; printf late > late-marker) & child=$!; trap 'exit 0' TERM; wait $child",
          hook_timeout_ms: 500
        )

        started_at = System.monotonic_time(:millisecond)

        assert_raise RuntimeError, ~r/workspace_hook_timeout.*before_turn.*500/, fn ->
          AgentRunner.run(issue("SSH-TERM-RESISTANT"), nil, worker_host: "worker-test")
        end

        assert System.monotonic_time(:millisecond) - started_at >= 5_000
        refute File.exists?(trace)
        Process.sleep(1_100)
        assert Path.wildcard(Path.join(workspace_root, "**/late-marker")) == []
      after
        File.rm_rf(root)
      end
    end)
  end

  defp fixture!(root) do
    workspace_root = Path.join(root, "workspaces")
    codex = Path.join(root, "fake-codex")
    trace = Path.join(root, "codex.trace")
    File.mkdir_p!(workspace_root)

    File.write!(codex, """
    #!/bin/sh
    trace=#{trace}
    printf 'PROCESS\n' >> "$trace"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\n' "$line" >> "$trace"
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-before-turn"}}}' ;;
        4) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'; printf '%s\n' '{"method":"turn/completed"}' ;;
        5) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-2"}}}'; printf '%s\n' '{"method":"turn/completed"}' ;;
      esac
    done
    """)

    File.chmod!(codex, 0o755)
    %{codex: codex, trace: trace, workspace_root: workspace_root}
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

  defp with_fake_ssh(fun) do
    root = tmp_dir("fake-ssh")
    fake_ssh = Path.join(root, "ssh")
    previous_path = System.get_env("PATH")
    File.mkdir_p!(root)

    File.write!(fake_ssh, """
    #!/bin/sh
    for arg in "$@"; do command="$arg"; done
    exec sh -c "$command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))

    try do
      fun.()
    after
      restore_env("PATH", previous_path)
      File.rm_rf(root)
    end
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
  end
end
