defmodule SymphonyElixir.ClaudeCode.StreamJsonTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.StreamJson

  test "runs the configured command in the workspace and sends a stream-json user message" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-code-stream-json-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CC")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' "$PWD" > "$SYMP_TEST_CLAUDE_TRACE"
      printf '%s\\n' "$*" >> "$SYMP_TEST_CLAUDE_TRACE"
      IFS= read -r input_line
      printf '%s\\n' "$input_line" >> "$SYMP_TEST_CLAUDE_TRACE"
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-123","model":"claude-sonnet","tools":["Read","Bash"]}'
      printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]},"session_id":"claude-session-123"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"duration_api_ms":8,"num_turns":1,"result":"done","session_id":"claude-session-123","usage":{"input_tokens":4,"output_tokens":2}}'
      """)

      File.chmod!(claude_binary, 0o755)

      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")
      on_exit(fn -> restore_env("SYMP_TEST_CLAUDE_TRACE", previous_trace) end)
      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_code_command: "#{claude_binary} --bare -p --output-format stream-json --input-format stream-json --verbose"
      )

      issue = %Issue{
        id: "issue-cc",
        identifier: "MT-CC",
        title: "Claude Code stream json",
        description: "Exercise stream-json adapter",
        state: "In Progress",
        url: "https://example.org/issues/MT-CC",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:claude_code_message, message}) end

      assert {:ok,
              %{
                result: %{"result" => "done", "subtype" => "success"},
                session_id: "claude-session-123",
                thread_id: "claude-session-123",
                turn_id: "1"
              }} = StreamJson.run(workspace, "Do the work\nwith context", issue, on_message: on_message)

      assert_receive {:claude_code_message,
                      %{
                        event: :session_started,
                        session_id: "claude-session-123",
                        claude_code_model: "claude-sonnet"
                      }}

      assert_receive {:claude_code_message,
                      %{
                        event: :turn_completed,
                        session_id: "claude-session-123",
                        usage: %{"input_tokens" => 4, "output_tokens" => 2}
                      }}

      [cwd, args, input_json] = trace_file |> File.read!() |> String.split("\n", trim: true)
      assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)
      assert cwd == expected_workspace
      assert args == "--bare -p --output-format stream-json --input-format stream-json --verbose"

      assert Jason.decode!(input_json) == %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "Do the work\nwith context"}]
               }
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "returns error result subtypes as failed turns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-code-error-result-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CC-ERR")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      IFS= read -r _input_line
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-err"}'
      printf '%s\\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"claude-session-err","num_turns":1}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_code_command: "#{claude_binary} -p --output-format stream-json --input-format stream-json"
      )

      issue = %Issue{
        id: "issue-cc-err",
        identifier: "MT-CC-ERR",
        title: "Claude Code failed turn",
        description: "Exercise stream-json failure",
        state: "In Progress",
        url: "https://example.org/issues/MT-CC-ERR",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:claude_code_message, message}) end

      assert {:error, {:claude_code_result, %{"subtype" => "error_during_execution"}}} =
               StreamJson.run(workspace, "Fail the work", issue, on_message: on_message)

      assert_receive {:claude_code_message,
                      %{
                        event: :turn_failed,
                        session_id: "claude-session-err",
                        payload: %{"subtype" => "error_during_execution"}
                      }}
    after
      File.rm_rf(test_root)
    end
  end

  test "rejects the workspace root and paths outside the configured workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-code-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{
        id: "issue-cc-guard",
        identifier: "MT-CC-GUARD",
        title: "Claude Code guard",
        description: "Validate workspace guard",
        state: "In Progress",
        url: "https://example.org/issues/MT-CC-GUARD",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               StreamJson.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               StreamJson.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end
end
