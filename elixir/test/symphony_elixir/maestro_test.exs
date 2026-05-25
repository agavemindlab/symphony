defmodule SymphonyElixir.MaestroTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Maestro
  alias SymphonyElixir.Workflow

  alias SymphonyElixir.Maestro.{
    AgentRun,
    ReviewAttachment,
    ReviewComment,
    ReviewContext
  }

  describe "run_once/1" do
    test "run_once/0 uses the default tracker and handles an empty Human Review queue" do
      workflow_path = Path.join(System.tmp_dir!(), "maestro-memory-#{System.unique_integer([:positive])}.md")
      previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)

      File.write!(workflow_path, """
      ---
      tracker:
        kind: memory
      ---
      """)

      Workflow.set_workflow_file_path(workflow_path)
      Application.put_env(:symphony_elixir, :memory_tracker_review_contexts, [])

      on_exit(fn ->
        if is_nil(previous_workflow_path) do
          Application.delete_env(:symphony_elixir, :workflow_file_path)
        else
          Application.put_env(:symphony_elixir, :workflow_file_path, previous_workflow_path)
        end

        Application.delete_env(:symphony_elixir, :memory_tracker_review_contexts)
        File.rm(workflow_path)
      end)

      assert {:ok, []} = Maestro.run_once()
    end

    test "handles an empty Human Review queue with an injected tracker" do
      assert {:ok, []} = Maestro.run_once(tracker: __MODULE__.EmptyTracker, agent_runner: fn _, _, _ -> flunk("unexpected runner call") end)
    end

    test "launches one Maestro agent session per Human Review context" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context(issue_id: "issue-1", identifier: "DEV-1")])

      runner = fn issue, recipient, opts ->
        send(self(), {:run_agent, issue, recipient, opts})
        :ok
      end

      assert {:ok, [%AgentRun{issue_id: "issue-1", identifier: "DEV-1", dry_run: false}]} =
               Maestro.run_once(tracker: tracker, agent_runner: runner)

      assert_receive {:fetch_review_contexts_by_states, ["Human Review"]}
      assert_receive {:run_agent, %Issue{id: "issue-1", identifier: "DEV-1"}, nil, opts}

      assert opts[:max_turns] == 1
      assert opts[:maestro] == true
      assert opts[:dry_run] == false
      assert opts[:prompt_template] =~ "You are Maestro"
      assert opts[:prompt_template] =~ "dry_run: false"
      assert opts[:prompt_template] =~ ".agents/skills/maestro/SKILL.md"

      refute_received {:create_comment, _, _}
      refute_received {:update_issue_state, _, _}
    end

    test "passes dry_run into the Maestro prompt without changing issue state in Elixir" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context(issue_id: "issue-dry", identifier: "DEV-DRY")])

      runner = fn issue, _recipient, opts ->
        send(self(), {:run_agent, issue, opts})
        :ok
      end

      assert {:ok, [%AgentRun{issue_id: "issue-dry", dry_run: true}]} =
               Maestro.run_once(tracker: tracker, agent_runner: runner, dry_run: true)

      assert_receive {:run_agent, %Issue{id: "issue-dry"}, opts}

      assert opts[:dry_run] == true
      assert opts[:prompt_template] =~ "dry_run: true"
      assert opts[:prompt_template] =~ "## Maestro Decision【试运行 · 不修改状态】"

      refute_received {:create_comment, _, _}
      refute_received {:update_issue_state, _, _}
    end

    test "uses issue.id when review context issue_id is not populated" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [%{context(issue_id: nil, identifier: "DEV-MAP") | issue_id: nil}])

      runner = fn issue, _recipient, _opts ->
        send(self(), {:run_agent, issue})
        :ok
      end

      assert {:ok, [%AgentRun{issue_id: "issue-1", identifier: "DEV-MAP"}]} =
               Maestro.run_once(tracker: tracker, agent_runner: runner)

      assert_receive {:run_agent, %Issue{id: "issue-1", identifier: "DEV-MAP"}}
    end

    test "launches from map-shaped review contexts" do
      tracker = __MODULE__.FakeTracker

      Process.put(
        {tracker, :contexts},
        [
          %{
            issue_id: "issue-map",
            issue: %{
              "id" => "issue-map",
              "identifier" => "DEV-MAP",
              "title" => "Map issue",
              "state" => "Human Review"
            }
          }
        ]
      )

      runner = fn issue, _recipient, _opts ->
        send(self(), {:run_agent, issue})
        :ok
      end

      assert {:ok, [%AgentRun{issue_id: "issue-map", identifier: "DEV-MAP"}]} =
               Maestro.run_once(tracker: tracker, agent_runner: runner)

      assert_receive {:run_agent, %{"id" => "issue-map"}}
    end

    test "keeps running when identifier is unavailable on non-map issue terms" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [%{issue_id: "issue-term", issue: :issue_term}])

      runner = fn issue, _recipient, _opts ->
        send(self(), {:run_agent, issue})
        :ok
      end

      assert {:ok, [%AgentRun{issue_id: "issue-term", identifier: nil}]} =
               Maestro.run_once(tracker: tracker, agent_runner: runner)

      assert_receive {:run_agent, :issue_term}
    end

    test "stops when a review context cannot identify an issue" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [%ReviewContext{}])

      assert {:error, {:maestro_agent_launch_failed, nil, :missing_issue}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> :ok end)
    end

    test "stops when a map-shaped review context has no issue" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [%{issue: nil, issue_id: "issue-missing"}])

      assert {:error, {:maestro_agent_launch_failed, "issue-missing", :missing_issue}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> :ok end)
    end

    test "stops when a non-context value is returned by the tracker" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [:bad_context])

      assert {:error, {:maestro_agent_launch_failed, nil, :missing_issue}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> :ok end)
    end

    test "stops when the issue itself has no id" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [%ReviewContext{issue: %Issue{id: nil, identifier: "DEV-NO-ID"}}])

      assert {:error, {:maestro_agent_launch_failed, nil, :missing_issue_id}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> :ok end)
    end

    test "returns runner failures with the target issue id" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context(issue_id: "issue-boom", identifier: "DEV-BOOM")])

      assert {:error, {:maestro_agent_launch_failed, "issue-boom", :runner_down}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> {:error, :runner_down} end)
    end

    test "returns unexpected runner results with the target issue id" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context(issue_id: "issue-weird", identifier: "DEV-WEIRD")])

      assert {:error, {:maestro_agent_launch_failed, "issue-weird", {:unexpected_runner_result, :weird}}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> :weird end)
    end

    test "captures runner exceptions with the target issue id" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context(issue_id: "issue-raise", identifier: "DEV-RAISE")])

      assert {:error, {:maestro_agent_launch_failed, "issue-raise", {:exception, %RuntimeError{message: "boom"}}}} =
               Maestro.run_once(tracker: tracker, agent_runner: fn _, _, _ -> raise "boom" end)
    end
  end

  describe "prompt_template/1" do
    test "defaults to a normal-mode prompt" do
      assert Maestro.prompt_template() =~ "dry_run: false"
    end

    test "documents the Maestro workflow contract that the agent session owns" do
      prompt = Maestro.prompt_template(dry_run: true)

      assert prompt =~ "Status: Waiting for PR review"
      assert prompt =~ "Status: Waiting for completion confirmation"
      assert prompt =~ "Status: Waiting for requirement confirmation"
      assert prompt =~ "Status: Waiting for plan confirmation"
      assert prompt =~ "Status: Blocked"
      assert prompt =~ "gh pr view"
      assert prompt =~ "gh pr diff"
      assert prompt =~ "## Maestro Decision"
      assert prompt =~ "Merging"
      assert prompt =~ "Rework"
      assert prompt =~ "Done"
      assert prompt =~ "In Progress"
    end
  end

  defmodule EmptyTracker do
    @spec fetch_review_contexts_by_states([String.t()]) :: {:ok, []}
    def fetch_review_contexts_by_states(states) do
      send(self(), {:fetch_review_contexts_by_states, states})
      {:ok, []}
    end
  end

  defmodule FakeTracker do
    @spec fetch_review_contexts_by_states([String.t()]) :: {:ok, [term()]}
    def fetch_review_contexts_by_states(states) do
      send(self(), {:fetch_review_contexts_by_states, states})
      {:ok, Process.get({__MODULE__, :contexts}, [])}
    end

    @spec create_comment(String.t(), String.t()) :: :ok
    def create_comment(issue_id, body) do
      send(self(), {:create_comment, issue_id, body})
      :ok
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok
    def update_issue_state(issue_id, state) do
      send(self(), {:update_issue_state, issue_id, state})
      :ok
    end
  end

  defp context(opts) do
    issue_id = Keyword.fetch!(opts, :issue_id)
    identifier = Keyword.fetch!(opts, :identifier)

    %ReviewContext{
      issue_id: issue_id,
      issue: %Issue{
        id: issue_id || "issue-1",
        identifier: identifier,
        title: "Review handoff",
        description: "A Maestro review target",
        state: "Human Review",
        url: "https://linear.app/example/issue/#{identifier}"
      },
      comments: [
        %ReviewComment{
          id: "comment-1",
          body: "## Review Handoff\n\nStatus: Waiting for PR review",
          created_at: ~U[2026-05-25 08:00:00Z]
        }
      ],
      attachments: [
        %ReviewAttachment{
          id: "attachment-1",
          title: "PR #8",
          url: "https://github.com/agavemindlab/symphony/pull/8",
          source_type: "github"
        }
      ]
    }
  end
end
