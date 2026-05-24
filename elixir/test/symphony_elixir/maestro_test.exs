defmodule SymphonyElixir.MaestroTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Maestro
  alias SymphonyElixir.Maestro.{Decision, ReviewAttachment, ReviewComment, ReviewContext}
  alias SymphonyElixir.Workflow

  describe "decide/1" do
    test "targets Merging for clean PR review handoff with PR and validation evidence" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for PR review

            PR: https://github.com/acme/app/pull/42

            ✅ 验证
            - mix test elixir/test/symphony_elixir/maestro_test.exs passed
            """
          )
        ])

      assert %Decision{
               status: "Waiting for PR review",
               action: :change_state,
               target_state: "Merging",
               reasons: [],
               audit_comment_body: audit_comment
             } = Maestro.decide(context)

      assert audit_comment =~ "## Maestro Decision"
      assert audit_comment =~ "原始 handoff status: Waiting for PR review"
      assert audit_comment =~ "决策: 批准进入 Merging"
      assert audit_comment =~ "目标状态: Merging"
      assert audit_comment =~ "- 无"
    end

    test "targets Rework for PR review handoff with failure markers" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            **Status**: Waiting for PR review

            PR: https://github.com/acme/app/pull/42

            ✅ 验证
            - mix test failed
            - ❌ 失败: targeted tests are red
            """
          )
        ])

      assert %Decision{target_state: "Rework", reasons: reasons} = Maestro.decide(context)
      assert "handoff 包含失败或部分通过的验证证据" in reasons
    end

    test "targets Rework for PR review handoff without PR or validation evidence" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for PR review

            Ready for a look.
            """
          )
        ])

      assert %Decision{target_state: "Rework", reasons: reasons} = Maestro.decide(context)
      assert "缺少验证证据" in reasons
      assert "缺少 PR 证据" in reasons
    end

    test "can use issue attachments as PR and validation evidence" do
      context =
        context(
          [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Waiting for PR review

              Evidence is attached.
              """
            )
          ],
          [
            attachment("pr-42.url", "https://github.com/acme/app/pull/42"),
            attachment("validation-log.txt", "https://linear.example/validation-log.txt")
          ]
        )

      assert %Decision{target_state: "Merging", reasons: []} = Maestro.decide(context)
    end

    test "targets Done for clean completion confirmation with merge evidence" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for completion confirmation

            Merge evidence: PR #42 merged to main.
            Completion evidence: deployed and verified.
            """
          )
        ])

      assert %Decision{
               status: "Waiting for completion confirmation",
               action: :change_state,
               target_state: "Done",
               reasons: []
             } = Maestro.decide(context)
    end

    test "targets Rework for completion confirmation without merge or completion evidence" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for completion confirmation

            Please confirm this is complete.
            """
          )
        ])

      assert %Decision{target_state: "Rework", reasons: reasons} = Maestro.decide(context)
      assert "缺少 merge/completion 完成证据" in reasons
    end

    test "targets In Progress for requirement confirmation with a recommended option" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for requirement confirmation

            Recommended: approve the clarified acceptance criteria.
            """
          )
        ])

      assert %Decision{target_state: "In Progress", reasons: []} = Maestro.decide(context)
    end

    test "targets In Progress for plan confirmation with a recommended option" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for plan confirmation

            推荐: use the smaller parser-only approach.
            """
          )
        ])

      assert %Decision{target_state: "In Progress", reasons: []} = Maestro.decide(context)
    end

    test "targets Rework for requirement or plan confirmation without a recommendation" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for plan confirmation

            Two possible approaches are listed.
            """
          )
        ])

      assert %Decision{target_state: "Rework", reasons: reasons} = Maestro.decide(context)
      assert "缺少明确推荐选项" in reasons
    end

    test "does not change state for blocked handoffs and writes an audit comment" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Blocked

            Waiting on an external decision.
            """
          )
        ])

      assert %Decision{
               status: "Blocked",
               action: :no_state_change,
               target_state: nil,
               reasons: ["handoff 状态为 Blocked，需要人工解除阻塞"],
               audit_comment_body: audit_comment
             } = Maestro.decide(context)

      assert audit_comment =~ "目标状态: no-state-change"
      assert audit_comment =~ "- handoff 状态为 Blocked，需要人工解除阻塞"
    end

    test "uses the latest review handoff comment" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Blocked
            """
          ),
          comment(
            "2026-05-24T10:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for plan confirmation

            recommended: proceed.
            """
          )
        ])

      assert %Decision{status: "Waiting for plan confirmation", target_state: "In Progress"} =
               Maestro.decide(context)
    end

    test "sorts DateTime and NaiveDateTime handoffs and ignores non-binary comment bodies" do
      context =
        context([
          %ReviewComment{body: nil, created_at: ~U[2026-05-24 08:00:00Z]},
          %ReviewComment{
            created_at: nil,
            body: """
            ## Review Handoff

            Status: Blocked
            """
          },
          %ReviewComment{
            created_at: ~N[2026-05-24 09:00:00],
            body: """
            ## Review Handoff

            Status: Blocked
            """
          },
          %ReviewComment{
            created_at: ~U[2026-05-24 10:00:00Z],
            body: """
            ## Review Handoff

            Status: Waiting for plan confirmation

            recommended: proceed.
            """
          }
        ])

      assert %Decision{status: "Waiting for plan confirmation", target_state: "In Progress"} =
               Maestro.decide(context)
    end

    test "targets Rework when review handoff is missing" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Regular Update

            Status: Waiting for PR review
            """
          )
        ])

      assert %Decision{
               status: nil,
               target_state: "Rework",
               reasons: ["未找到 `## Review Handoff` comment"]
             } = Maestro.decide(context)
    end

    test "targets Rework when status is missing or unknown" do
      missing_status =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            No status line here.
            """
          )
        ])

      unknown_status =
        context([
          comment(
            "2026-05-24T10:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for something else
            """
          )
        ])

      assert %Decision{status: nil, target_state: "Rework", reasons: ["Review Handoff 缺少 `Status:` 行"]} =
               Maestro.decide(missing_status)

      assert %Decision{
               status: "Waiting for something else",
               target_state: "Rework",
               reasons: ["不支持的 handoff status: Waiting for something else"]
             } = Maestro.decide(unknown_status)
    end

    test "audit comment includes status, action, target state, and reasons" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for PR review

            🚨 blocker: CI credentials are unavailable.
            """
          )
        ])

      assert %Decision{audit_comment_body: audit_comment} = Maestro.decide(context)

      assert String.starts_with?(audit_comment, "## Maestro Decision")
      assert audit_comment =~ "原始 handoff status: Waiting for PR review"
      assert audit_comment =~ "决策: 打回 Rework"
      assert audit_comment =~ "目标状态: Rework"
      assert audit_comment =~ "判断理由:"
      assert audit_comment =~ "- handoff 包含 blocker 风险"
    end

    test "uses inspectable attachment evidence when attachment shape is unknown" do
      context =
        context(
          [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Waiting for PR review

              Evidence is attached.
              """
            )
          ],
          [
            :validation_log,
            %ReviewAttachment{url: "https://github.com/acme/app/pull/42"}
          ]
        )

      assert %Decision{target_state: "Merging", reasons: []} = Maestro.decide(context)
    end

    test "allows requirement confirmation markers when a recommendation is present" do
      context =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Status: Waiting for requirement confirmation

            [NEEDS CLARIFICATION: choose approval scope]
            A（推荐）: approve the narrow scope.
            """
          )
        ])

      assert %Decision{target_state: "In Progress", reasons: []} = Maestro.decide(context)
    end
  end

  describe "run_once/1" do
    test "run_once/0 uses the default tracker" do
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

    test "writes an audit comment before changing state" do
      context =
        %ReviewContext{
          issue_id: "issue-1",
          comments: [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Waiting for PR review

              PR: https://github.com/acme/app/pull/42

              ✅ 验证
              - mix test passed
              """
            )
          ]
        }

      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context])

      assert {:ok, [%Decision{target_state: "Merging"}]} = Maestro.run_once(tracker: tracker)

      assert_receive {:fetch_review_contexts_by_states, ["Human Review"]}
      assert_receive {:create_comment, "issue-1", audit_comment}
      assert String.starts_with?(audit_comment, "## Maestro Decision")
      assert_receive {:update_issue_state, "issue-1", "Merging"}
    end

    test "uses issue.id when issue_id is not set" do
      context =
        %ReviewContext{
          issue: %{id: "issue-from-map"},
          comments: [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Waiting for plan confirmation

              recommended: proceed.
              """
            )
          ]
        }

      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context])

      assert {:ok, [%Decision{target_state: "In Progress"}]} = Maestro.run_once(tracker: tracker)

      assert_receive {:create_comment, "issue-from-map", _audit_comment}
      assert_receive {:update_issue_state, "issue-from-map", "In Progress"}
    end

    test "stops when audit comment creation fails" do
      context =
        %ReviewContext{
          issue_id: "issue-error",
          comments: [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Blocked
              """
            )
          ]
        }

      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context])
      Process.put({tracker, :create_comment_result}, {:error, :boom})

      assert {:error, {:maestro_decision_failed, "issue-error", :boom}} =
               Maestro.run_once(tracker: tracker)
    end

    test "stops when the review context has no issue id" do
      context =
        %ReviewContext{
          comments: [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Blocked
              """
            )
          ]
        }

      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context])

      assert {:error, {:maestro_decision_failed, nil, :missing_issue_id}} =
               Maestro.run_once(tracker: tracker)
    end

    test "does not update state for blocked handoffs" do
      context =
        %ReviewContext{
          issue_id: "issue-2",
          comments: [
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Blocked
              """
            )
          ]
        }

      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context])

      assert {:ok, [%Decision{action: :no_state_change, target_state: nil}]} =
               Maestro.run_once(tracker: tracker)

      assert_receive {:create_comment, "issue-2", audit_comment}
      assert audit_comment =~ "目标状态: no-state-change"
      refute_receive {:update_issue_state, "issue-2", _state}
    end
  end

  defmodule FakeTracker do
    def fetch_review_contexts_by_states(states) do
      send(self(), {:fetch_review_contexts_by_states, states})
      {:ok, Process.get({__MODULE__, :contexts}, [])}
    end

    def create_comment(issue_id, body) do
      send(self(), {:create_comment, issue_id, body})
      Process.get({__MODULE__, :create_comment_result}, :ok)
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:update_issue_state, issue_id, state_name})
      :ok
    end
  end

  defp context(comments, attachments \\ []) do
    %ReviewContext{comments: comments, attachments: attachments}
  end

  defp comment(created_at, body) do
    %ReviewComment{created_at: created_at, body: body}
  end

  defp attachment(filename, url) do
    %ReviewAttachment{filename: filename, url: url}
  end
end
