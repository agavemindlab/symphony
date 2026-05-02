defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "agent runner dispatches to the configured claude code provider" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-claude-code-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_provider: "claude_code",
        prompt: "Identifier: {{ issue.identifier }}"
      )

      issue = %Issue{
        id: "issue-claude-provider",
        identifier: "MT-CLAUDE",
        title: "Use Claude Code",
        description: "Run with the Claude Code provider",
        state: "In Progress",
        url: "https://example.org/issues/MT-CLAUDE",
        labels: ["backend"]
      }

      parent = self()

      claude_code_provider = fn workspace, prompt, provider_issue, opts ->
        send(parent, {:claude_code_provider_called, workspace, prompt, provider_issue, opts})

        {:ok,
         %{
           result: %{"type" => "result", "subtype" => "success", "session_id" => "claude-session-1"},
           session_id: "claude-session-1",
           thread_id: "claude-session-1",
           turn_id: "claude-turn-1"
         }}
      end

      issue_state_fetcher = fn [issue_id] ->
        assert issue_id == "issue-claude-provider"
        {:ok, [%{issue | state: "Done"}]}
      end

      assert :ok =
               AgentRunner.run(issue, nil,
                 claude_code_provider: claude_code_provider,
                 issue_state_fetcher: issue_state_fetcher,
                 max_turns: 1
               )

      assert_receive {:claude_code_provider_called, workspace, prompt, ^issue, opts}

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(workspace_root, "MT-CLAUDE"))

      assert workspace == expected_workspace
      assert prompt =~ "Identifier: MT-CLAUDE"
      assert Keyword.has_key?(opts, :on_message)
      assert Keyword.get(opts, :worker_host) == nil
    after
      File.rm_rf(workspace_root)
    end
  end
end
