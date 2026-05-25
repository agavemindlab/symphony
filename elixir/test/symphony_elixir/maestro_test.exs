defmodule SymphonyElixir.MaestroTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Maestro

  alias SymphonyElixir.Maestro.{
    ClaudeJudge,
    CliRunner,
    Decision,
    GitHubPrContextProvider,
    JudgeRequest,
    PrContext,
    ReviewAttachment,
    ReviewComment,
    ReviewContext
  }

  alias SymphonyElixir.Workflow

  describe "decide/2" do
    test "passes issue, spec, handoff, comments, and PR context to the LLM judge" do
      context =
        context(
          [
            comment(
              "2026-05-24T08:00:00Z",
              """
              ## Spec

              Primary: Type:Feature

              验收标准（acceptance）:
              - S1: Maestro routes PR handoffs.
              """
            ),
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Waiting for PR review

              PR: https://github.com/acme/app/pull/42

              ✅ 验证:
              - mix test passed
              """
            )
          ],
          [%ReviewAttachment{title: "PR #42", url: "https://github.com/acme/app/pull/42"}]
        )

      assert %Decision{
               status: "Waiting for PR review",
               action: :change_state,
               target_state: "Merging",
               reasons: [],
               llm_summary: "PR diff and tests satisfy the handoff.",
               audit_comment_body: audit_comment
             } =
               Maestro.decide(context,
                 judge: __MODULE__.ApprovingJudge,
                 pr_context_provider: __MODULE__.FakePrContextProvider
               )

      assert_receive {:fetch_pr_contexts, "Waiting for PR review", attachments}
      assert [%ReviewAttachment{url: "https://github.com/acme/app/pull/42"}] = attachments

      assert_receive {:judge_request,
                      %JudgeRequest{
                        status: "Waiting for PR review",
                        issue: %{description: "Original issue requirements"},
                        handoff_comment: %ReviewComment{},
                        spec_comment: %ReviewComment{},
                        pr_contexts: [%PrContext{url: "https://github.com/acme/app/pull/42"}],
                        prompt: prompt
                      }}

      assert prompt =~ "Original issue requirements"
      assert prompt =~ "## Spec"
      assert prompt =~ "Status: Waiting for PR review"
      assert prompt =~ "diff --git a/lib/app.ex b/lib/app.ex"
      assert prompt =~ "+  def covered_change"
      assert prompt =~ "CI: success"

      assert audit_comment =~ "## Maestro Decision"
      assert audit_comment =~ "原始 handoff status: Waiting for PR review"
      assert audit_comment =~ "决策: 批准进入 Merging"
      assert audit_comment =~ "LLM 裁决摘要: PR diff and tests satisfy the handoff."
      assert audit_comment =~ "- 无"
    end

    test "decide/1 uses configured default judge and PR context provider" do
      Application.put_env(:symphony_elixir, :maestro_judge, __MODULE__.ApprovingJudge)
      Application.put_env(:symphony_elixir, :maestro_pr_context_provider, __MODULE__.FakePrContextProvider)

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :maestro_judge)
        Application.delete_env(:symphony_elixir, :maestro_pr_context_provider)
      end)

      assert %Decision{target_state: "Merging"} = Maestro.decide(context_for_status("Waiting for PR review"))
    end

    test "routes supported handoff statuses through the LLM judge and validates allowed targets" do
      cases = [
        {"Waiting for PR review", "Merging", :change_state},
        {"Waiting for completion confirmation", "Done", :change_state},
        {"Waiting for requirement confirmation", "In Progress", :change_state},
        {"Waiting for plan confirmation", "In Progress", :change_state},
        {"Blocked", nil, :no_state_change}
      ]

      for {status, expected_target, expected_action} <- cases do
        decision =
          status
          |> context_for_status()
          |> Maestro.decide(judge: __MODULE__.RoutingJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

        assert %Decision{
                 status: ^status,
                 action: ^expected_action,
                 target_state: ^expected_target,
                 reasons: []
               } = decision
      end
    end

    test "fails closed when LLM target state is not allowed for the handoff status" do
      decision =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.InvalidTargetJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{target_state: "Rework", reasons: reasons} = decision
      assert "LLM 输出的目标状态 `Done` 不允许用于 `Waiting for PR review`" in reasons
    end

    test "fails closed when the LLM judge errors" do
      decision =
        "Waiting for completion confirmation"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.ErrorJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{status: "Waiting for completion confirmation", target_state: "Rework", reasons: reasons} =
               decision

      assert "LLM 裁决失败: :claude_unavailable" in reasons
    end

    test "fails closed when PR context collection errors before calling the judge" do
      decision =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.ExplodingJudge, pr_context_provider: __MODULE__.ErrorPrContextProvider)

      assert %Decision{target_state: "Rework", reasons: reasons} = decision
      assert "LLM 裁决失败: {:pr_context_failed, :github_down}" in reasons
    end

    test "fails closed for malformed LLM responses" do
      bad_reasons =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.BadReasonsJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{target_state: "Rework", reasons: ["LLM 输出缺少 reasons 列表"]} = bad_reasons
      assert bad_reasons.audit_comment_body =~ "LLM 裁决摘要: 无"

      non_map =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.NonMapJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{target_state: "Rework", reasons: ["LLM 输出不是 JSON object"]} = non_map

      nil_target =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.NilTargetJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{
               target_state: "Rework",
               reasons: ["LLM 输出的目标状态 `null` 不允许用于 `Waiting for PR review`"]
             } = nil_target

      invalid_type =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.InvalidTypeTargetJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{
               target_state: "Rework",
               reasons: ["LLM 输出的目标状态 `invalid` 不允许用于 `Waiting for PR review`"]
             } = invalid_type
    end

    test "normalizes empty and string-null targets for blocked no-state-change decisions" do
      blank_target =
        "Blocked"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.BlankTargetJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{action: :no_state_change, target_state: nil, reasons: []} = blank_target

      null_target =
        "Blocked"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.NullTargetJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{action: :no_state_change, target_state: nil, reasons: []} = null_target
    end

    test "keeps blocked handoffs in place when the LLM judge errors" do
      decision =
        "Blocked"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.ErrorJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{action: :no_state_change, target_state: nil, reasons: reasons} = decision
      assert "LLM 裁决失败: :claude_unavailable" in reasons
    end

    test "supports atom-keyed stub responses in tests" do
      decision =
        "Waiting for PR review"
        |> context_for_status()
        |> Maestro.decide(judge: __MODULE__.AtomKeyJudge, pr_context_provider: __MODULE__.EmptyPrContextProvider)

      assert %Decision{target_state: "Merging", llm_summary: "atom keys accepted"} = decision
    end

    test "does not call the LLM judge for missing or unsupported handoff status" do
      no_handoff =
        context([
          %ReviewComment{body: nil, created_at: ~U[2026-05-24 08:00:00Z]},
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Regular Update

            Status: Waiting for PR review
            """
          )
        ])

      missing_status =
        context([
          comment(
            "2026-05-24T09:00:00Z",
            """
            ## Review Handoff

            Missing status.
            """
          )
        ])

      unknown_status = context_for_status("Waiting for something else")

      assert %Decision{status: nil, target_state: "Rework", reasons: ["未找到 `## Review Handoff` comment"]} =
               Maestro.decide(no_handoff, judge: __MODULE__.ExplodingJudge)

      assert %Decision{status: nil, target_state: "Rework", reasons: ["Review Handoff 缺少 `Status:` 行"]} =
               Maestro.decide(missing_status, judge: __MODULE__.ExplodingJudge)

      assert %Decision{
               status: "Waiting for something else",
               target_state: "Rework",
               reasons: ["不支持的 handoff status: Waiting for something else"]
             } = Maestro.decide(unknown_status, judge: __MODULE__.ExplodingJudge)
    end

    test "sorts DateTime and NaiveDateTime handoffs and includes sparse prompt fields" do
      context = %ReviewContext{
        issue: :issue_atom,
        comments: [
          %ReviewComment{body: "regular note", created_at: nil},
          %ReviewComment{
            body: """
            ## Review Handoff

            Status: Blocked
            """,
            created_at: nil
          },
          %ReviewComment{
            body: """
            ## Review Handoff

            Status: Blocked
            """,
            created_at: ~U[2026-05-24 09:00:00Z]
          },
          %ReviewComment{
            body: """
            ## Review Handoff

            Status: Waiting for PR review

            PR: https://github.com/acme/app/pull/42
            """,
            created_at: ~N[2026-05-24 10:00:00]
          }
        ],
        attachments: []
      }

      assert %Decision{target_state: "Merging"} =
               Maestro.decide(context,
                 judge: __MODULE__.ApprovingJudge,
                 pr_context_provider: __MODULE__.HugePrContextProvider
               )

      assert_receive {:judge_request, %JudgeRequest{prompt: prompt}}
      assert prompt =~ ":issue_atom"
      assert prompt =~ "未找到 ## Spec comment"
      assert prompt =~ "created_at: unknown"
      assert prompt =~ "created_at: 2026-05-24T09:00:00Z"
      assert prompt =~ "2026-05-24T10:00:00"
      assert prompt =~ "...[truncated]"
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

    test "writes an audit comment before changing state by default" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context_for_status("Waiting for PR review", issue_id: "issue-1")])

      assert {:ok, [%Decision{target_state: "Merging", dry_run: false}]} =
               Maestro.run_once(
                 tracker: tracker,
                 judge: __MODULE__.ApprovingJudge,
                 pr_context_provider: __MODULE__.FakePrContextProvider
               )

      assert_receive {:fetch_review_contexts_by_states, ["Human Review"]}
      assert_receive {:create_comment, "issue-1", audit_comment}
      assert String.starts_with?(audit_comment, "## Maestro Decision")
      assert_receive {:update_issue_state, "issue-1", "Merging"}
    end

    test "uses issue.id when issue_id is not set" do
      tracker = __MODULE__.FakeTracker
      context = context_for_status("Waiting for PR review")
      Process.put({tracker, :contexts}, [%{context | issue_id: nil, issue: %{id: "issue-from-map"}}])

      assert {:ok, [%Decision{target_state: "Merging"}]} =
               Maestro.run_once(
                 tracker: tracker,
                 judge: __MODULE__.ApprovingJudge,
                 pr_context_provider: __MODULE__.FakePrContextProvider
               )

      assert_receive {:create_comment, "issue-from-map", _audit_comment}
      assert_receive {:update_issue_state, "issue-from-map", "Merging"}
    end

    test "dry_run writes a marked audit comment and skips state changes" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context_for_status("Waiting for PR review", issue_id: "issue-dry")])

      assert {:ok, [%Decision{target_state: "Merging", dry_run: true, audit_comment_body: audit_comment}]} =
               Maestro.run_once(
                 tracker: tracker,
                 judge: __MODULE__.ApprovingJudge,
                 pr_context_provider: __MODULE__.FakePrContextProvider,
                 dry_run: true
               )

      assert_receive {:create_comment, "issue-dry", ^audit_comment}
      assert String.starts_with?(audit_comment, "## Maestro Decision【试运行 · 不修改状态】")
      assert audit_comment =~ "目标状态: Merging（试运行模式下不执行）"
      refute_receive {:update_issue_state, "issue-dry", _state}
    end

    test "does not update state for no-state-change LLM decisions" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context_for_status("Blocked", issue_id: "issue-blocked")])

      assert {:ok, [%Decision{action: :no_state_change, target_state: nil}]} =
               Maestro.run_once(
                 tracker: tracker,
                 judge: __MODULE__.RoutingJudge,
                 pr_context_provider: __MODULE__.EmptyPrContextProvider
               )

      assert_receive {:create_comment, "issue-blocked", audit_comment}
      assert audit_comment =~ "目标状态: no-state-change"
      refute_receive {:update_issue_state, "issue-blocked", _state}
    end

    test "stops when audit comment creation fails" do
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context_for_status("Blocked", issue_id: "issue-error")])
      Process.put({tracker, :create_comment_result}, {:error, :boom})

      assert {:error, {:maestro_decision_failed, "issue-error", :boom}} =
               Maestro.run_once(
                 tracker: tracker,
                 judge: __MODULE__.RoutingJudge,
                 pr_context_provider: __MODULE__.EmptyPrContextProvider
               )
    end

    test "stops when the review context has no issue id" do
      context = context_for_status("Blocked")
      tracker = __MODULE__.FakeTracker
      Process.put({tracker, :contexts}, [context])

      assert {:error, {:maestro_decision_failed, nil, :missing_issue_id}} =
               Maestro.run_once(
                 tracker: tracker,
                 judge: __MODULE__.RoutingJudge,
                 pr_context_provider: __MODULE__.EmptyPrContextProvider
               )
    end
  end

  describe "ClaudeJudge" do
    test "decide/1 runs the configured Claude command and parses JSON output" do
      with_fake_path(
        %{
          "fake-claude" => """
          #!/bin/sh
          printf '%s' '{"target_state":"Rework","summary":"needs fixes","reasons":["tests missing"]}'
          """
        },
        fn ->
          Application.put_env(:symphony_elixir, :maestro_claude_command, "fake-claude")
          Application.put_env(:symphony_elixir, :maestro_claude_timeout_ms, 1_000)

          on_exit(fn ->
            Application.delete_env(:symphony_elixir, :maestro_claude_command)
            Application.delete_env(:symphony_elixir, :maestro_claude_timeout_ms)
          end)

          request = %JudgeRequest{status: "Waiting for PR review", prompt: "Review this handoff."}

          assert {:ok,
                  %{
                    "target_state" => "Rework",
                    "summary" => "needs fixes",
                    "reasons" => ["tests missing"]
                  }} = ClaudeJudge.decide(request)
        end
      )
    end

    test "parse_response/1 accepts Claude wrapper shapes and reports invalid output" do
      assert {:ok, %{"target_state" => "Merging"}} =
               ClaudeJudge.parse_response(~s({"target_state":"Merging","summary":"ok","reasons":[]}))

      assert {:ok, %{"target_state" => "Done"}} =
               ClaudeJudge.parse_response(~s({"result":"Here is the decision: {\\"target_state\\":\\"Done\\",\\"summary\\":\\"ok\\",\\"reasons\\":[]}"}))

      assert {:ok, %{"target_state" => "In Progress"}} =
               ClaudeJudge.parse_response(~s({"message":{"content":[{"type":"text","text":"{\\"target_state\\":\\"In Progress\\",\\"summary\\":\\"ok\\",\\"reasons\\":[]}"}]}}))

      assert {:ok, %{"target_state" => "Rework"}} =
               ClaudeJudge.parse_response(~s({"message":{"content":[{"text":"{\\"target_state\\":\\"Rework\\",\\"summary\\":\\"ok\\",\\"reasons\\":[\\"missing\\"]}"}]}}))

      assert {:ok, %{"target_state" => "Done"}} =
               ClaudeJudge.parse_response(~s(prefix {"target_state":"Done","summary":"ok","reasons":[]} suffix))

      assert {:error, :empty_claude_response} = ClaudeJudge.parse_response("")

      assert {:error, :missing_claude_text_content} =
               ClaudeJudge.parse_response(~s({"message":{"content":[{"type":"image"}]}}))

      assert {:error, {:unexpected_claude_response, %{"unexpected" => true}}} =
               ClaudeJudge.parse_response(~s({"unexpected":true}))

      assert {:error, {:invalid_json, _reason}} = ClaudeJudge.parse_response("not-json")
    end

    test "decide/1 returns command errors" do
      Application.put_env(:symphony_elixir, :maestro_claude_command, "missing-claude-for-test")

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :maestro_claude_command)
      end)

      assert {:error, {:missing_executable, "missing-claude-for-test"}} =
               ClaudeJudge.decide(%JudgeRequest{status: "Waiting for PR review", prompt: "Review"})
    end
  end

  describe "GitHubPrContextProvider" do
    test "collects GitHub metadata and diff with gh" do
      with_fake_path(
        %{
          "gh" => """
          #!/bin/sh
          if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
            printf '%s' '{"number":42,"title":"Maestro","statusCheckRollup":[{"status":"COMPLETED"}]}'
            exit 0
          fi
          if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
            printf '%s' 'diff --git a/test.exs b/test.exs\\n+assert reviewed'
            exit 0
          fi
          exit 2
          """
        },
        fn ->
          context =
            context(
              [
                comment(
                  "2026-05-24T09:00:00Z",
                  """
                  ## Review Handoff

                  Status: Waiting for PR review
                  https://github.com/acme/app/pull/42
                  """
                )
              ],
              [%ReviewAttachment{url: "https://github.com/acme/app/pull/42"}]
            )

          assert {:ok, [%PrContext{metadata: metadata, diff: diff, error: nil}]} =
                   GitHubPrContextProvider.fetch(context, %{body: hd(context.comments).body})

          assert metadata =~ ~s("number": 42)
          assert metadata =~ ~s("status": "COMPLETED")
          assert diff =~ "+assert reviewed"
        end
      )
    end

    test "records unavailable gh context as PR context caveats" do
      with_fake_path(%{}, fn ->
        context =
          context([
            comment(
              "2026-05-24T09:00:00Z",
              """
              ## Review Handoff

              Status: Waiting for PR review
              https://github.com/acme/app/pull/42
              """
            )
          ])

        assert {:ok, [%PrContext{metadata: metadata, diff: diff, error: error}]} =
                 GitHubPrContextProvider.fetch(context, %{body: hd(context.comments).body})

        assert metadata =~ "GitHub PR metadata unavailable"
        assert diff =~ "GitHub PR diff unavailable"
        assert error =~ "missing_executable"
      end)
    end

    test "handles non-binary handoff body and non-json truncated gh output" do
      assert {:ok, []} =
               GitHubPrContextProvider.fetch(%ReviewContext{comments: [], attachments: []}, %{body: nil})

      long_output = String.duplicate("metadata-line", 2_000)
      long_diff = String.duplicate("+changed\n", 8_000)

      with_fake_path(
        %{
          "gh" => """
          #!/bin/sh
          if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
            printf '%s' '#{long_output}'
            exit 0
          fi
          if [ "$1" = "pr" ] && [ "$2" = "diff" ]; then
            printf '%s' '#{long_diff}'
            exit 0
          fi
          exit 2
          """
        },
        fn ->
          context =
            context(
              [
                comment(
                  "2026-05-24T09:00:00Z",
                  """
                  ## Review Handoff

                  Status: Waiting for PR review
                  """
                )
              ],
              [:attachment_with_no_url, %ReviewAttachment{url: "https://github.com/acme/app/pull/42"}]
            )

          assert {:ok, [%PrContext{metadata: metadata, diff: diff, error: nil}]} =
                   GitHubPrContextProvider.fetch(context, %{body: hd(context.comments).body})

          assert metadata =~ "metadata-line"
          assert metadata =~ "...[truncated]"
          assert diff =~ "+changed"
          assert diff =~ "...[truncated]"
        end
      )
    end
  end

  describe "CliRunner" do
    test "normalizes missing commands, nonzero exits, and timeouts" do
      assert {:error, {:missing_executable, "missing-maestro-command"}} =
               CliRunner.run("missing-maestro-command", [])

      with_fake_path(
        %{
          "failing-command" => """
          #!/bin/sh
          printf 'bad command'
          exit 7
          """,
          "slow-command" => """
          #!/bin/sh
          sleep 1
          printf 'done'
          """
        },
        fn ->
          assert {:error, {:exit_status, 7, "bad command"}} = CliRunner.run("failing-command", [])
          assert {:error, :timeout} = CliRunner.run("slow-command", [], timeout_ms: 1)
        end
      )
    end
  end

  defmodule ApprovingJudge do
    def decide(%JudgeRequest{} = request) do
      send(self(), {:judge_request, request})

      {:ok,
       %{
         "target_state" => "Merging",
         "reasons" => [],
         "summary" => "PR diff and tests satisfy the handoff."
       }}
    end
  end

  defmodule RoutingJudge do
    def decide(%JudgeRequest{status: "Waiting for PR review"}), do: response("Merging")
    def decide(%JudgeRequest{status: "Waiting for completion confirmation"}), do: response("Done")
    def decide(%JudgeRequest{status: "Waiting for requirement confirmation"}), do: response("In Progress")
    def decide(%JudgeRequest{status: "Waiting for plan confirmation"}), do: response("In Progress")
    def decide(%JudgeRequest{status: "Blocked"}), do: response(nil, "Blocker remains escalated.")

    defp response(target_state, summary \\ "LLM route accepted.") do
      {:ok, %{"target_state" => target_state, "reasons" => [], "summary" => summary}}
    end
  end

  defmodule InvalidTargetJudge do
    def decide(%JudgeRequest{}) do
      {:ok, %{"target_state" => "Done", "reasons" => [], "summary" => "Invalid approve."}}
    end
  end

  defmodule BadReasonsJudge do
    def decide(%JudgeRequest{}), do: {:ok, %{"target_state" => "Merging", "reasons" => "none"}}
  end

  defmodule NonMapJudge do
    def decide(%JudgeRequest{}), do: {:ok, ["not a map"]}
  end

  defmodule NilTargetJudge do
    def decide(%JudgeRequest{}), do: {:ok, %{"target_state" => nil, "summary" => "nil target", "reasons" => []}}
  end

  defmodule InvalidTypeTargetJudge do
    def decide(%JudgeRequest{}), do: {:ok, %{"target_state" => 42, "summary" => "bad target", "reasons" => []}}
  end

  defmodule BlankTargetJudge do
    def decide(%JudgeRequest{}), do: {:ok, %{"target_state" => "", "summary" => "blocked", "reasons" => []}}
  end

  defmodule NullTargetJudge do
    def decide(%JudgeRequest{}), do: {:ok, %{"target_state" => "null", "summary" => "blocked", "reasons" => []}}
  end

  defmodule AtomKeyJudge do
    def decide(%JudgeRequest{}), do: {:ok, %{target_state: "Merging", summary: "atom keys accepted", reasons: []}}
  end

  defmodule ErrorJudge do
    def decide(%JudgeRequest{}), do: {:error, :claude_unavailable}
  end

  defmodule ExplodingJudge do
    def decide(_request), do: raise("judge should not be called")
  end

  defmodule FakePrContextProvider do
    def fetch(%ReviewContext{attachments: attachments}, %{status: status}) do
      send(self(), {:fetch_pr_contexts, status, attachments})

      {:ok,
       [
         %PrContext{
           url: "https://github.com/acme/app/pull/42",
           metadata: "CI: success",
           diff: """
           diff --git a/lib/app.ex b/lib/app.ex
           +  def covered_change do
           +    :ok
           +  end
           """
         }
       ]}
    end
  end

  defmodule EmptyPrContextProvider do
    def fetch(%ReviewContext{}, _handoff), do: {:ok, []}
  end

  defmodule ErrorPrContextProvider do
    def fetch(%ReviewContext{}, _handoff), do: {:error, :github_down}
  end

  defmodule HugePrContextProvider do
    def fetch(%ReviewContext{}, _handoff) do
      {:ok,
       [
         %PrContext{
           url: "https://github.com/acme/app/pull/42",
           metadata: "CI: success",
           diff: String.duplicate("+real test coverage\n", 6_000)
         }
       ]}
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

  defp context_for_status(status, opts \\ []) do
    issue_id = Keyword.get(opts, :issue_id)

    %ReviewContext{
      issue_id: issue_id,
      issue: %{
        id: issue_id,
        identifier: "DEV-1",
        title: "Maestro review",
        state: "Human Review",
        description: "Original issue requirements"
      },
      comments: [
        comment(
          "2026-05-24T08:00:00Z",
          """
          ## Spec

          Primary: Type:Feature
          S1: Observable acceptance criterion.
          """
        ),
        comment(
          "2026-05-24T09:00:00Z",
          """
          ## Review Handoff

          Status: #{status}

          PR: https://github.com/acme/app/pull/42
          """
        )
      ],
      attachments: [%ReviewAttachment{title: "PR #42", url: "https://github.com/acme/app/pull/42"}]
    }
  end

  defp context(comments, attachments \\ []) do
    %ReviewContext{
      issue: %{
        id: "issue-context",
        identifier: "DEV-1",
        title: "Maestro review",
        state: "Human Review",
        description: "Original issue requirements"
      },
      issue_id: "issue-context",
      comments: comments,
      attachments: attachments
    }
  end

  defp comment(created_at, body) do
    %ReviewComment{created_at: created_at, body: body}
  end

  defp with_fake_path(executables, fun) when is_map(executables) and is_function(fun, 0) do
    previous_path = System.get_env("PATH") || ""
    bin_dir = Path.join(System.tmp_dir!(), "maestro-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)

    Enum.each(executables, fn {name, content} ->
      path = Path.join(bin_dir, name)
      File.write!(path, content)
      File.chmod!(path, 0o755)
    end)

    System.put_env("PATH", bin_dir)

    try do
      fun.()
    after
      System.put_env("PATH", previous_path)
      File.rm_rf(bin_dir)
    end
  end
end
