defmodule SymphonyElixir.RoutingBriefTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RoutingBrief

  defmodule ErrorLinearClient do
    def fetch_issue_comments(_issue_id), do: {:error, :comment_fetch_failed}
  end

  defmodule RaisingLinearClient do
    def fetch_issue_comments(_issue_id), do: raise("linear exploded")
  end

  defmodule ThrowingLinearClient do
    def fetch_issue_comments(_issue_id), do: throw(:linear_exited)
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  defp realistic_thread do
    [
      comment("status-card", "## 📍 状态\n- 当前阶段：Implementation · 等待人工审核",
        created_at: "2026-07-01T09:00:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("req-1", "## Requirements\n\n目标 v1",
        created_at: "2026-07-01T10:00:00Z",
        author_name: "symphony-agent",
        author_is_bot: true,
        resolved_at: "2026-07-01T12:10:00Z"
      ),
      comment("req-2", "## Requirements\n\n目标 v2",
        created_at: "2026-07-01T12:10:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("req-2-rework", "🔧 本轮修改：按反馈收紧了范围。",
        parent_id: "req-2",
        created_at: "2026-07-01T12:11:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("req-2-early", "先看一眼", parent_id: "req-2", created_at: "2026-07-01T12:30:00Z", author_name: "Alice"),
      comment("req-2-approve", "✅ 已批准，进入 Design（2026-07-01T13:00:00Z）",
        parent_id: "req-2",
        created_at: "2026-07-01T13:00:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("design-1", "## Design\n\n模块拆分",
        created_at: "2026-07-01T13:30:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("design-1-advance", "⏩ 自动进入 Implementation（agent 自评通过，未经人工评审，2026-07-01T13:35:00Z）",
        parent_id: "design-1",
        created_at: "2026-07-01T13:35:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment(
        "impl-1",
        """
        ## Implementation

        PR: https://github.com/x/y/pull/1

        ___

        ### NEEDS CLARIFICATION

        > This needs an explicit human decision before the workflow can continue.

        Question: 部署到哪个环境？

        ___
        """,
        created_at: "2026-07-01T14:00:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("req-2-late", "另外记得更新文档", parent_id: "req-2", created_at: "2026-07-01T15:00:00Z", author_name: "Alice"),
      comment("standalone-1", "整体方向 OK，注意兼容旧版本", created_at: "2026-07-01T15:30:00Z", author_name: "Bob"),
      comment("standalone-resolved", "旧的讨论，已处理",
        created_at: "2026-07-01T15:35:00Z",
        author_name: "Bob",
        resolved_at: "2026-07-01T15:40:00Z"
      ),
      comment("proposal-1", "## 建议新建 issue：抽出 X 模块\n\n理由：越界工作。",
        created_at: "2026-07-01T15:45:00Z",
        author_name: "symphony-agent",
        author_is_bot: true
      ),
      comment("impl-1-q", "staging 环境即可", parent_id: "impl-1", created_at: "2026-07-01T16:00:00Z", author_name: "Alice"),
      comment("impl-1-maestro", "🤖 Maestro 预审核: 建议回复方式: approve\n置信度 8/10",
        parent_id: "impl-1",
        created_at: "2026-07-01T16:05:00Z",
        author_name: "Maestro",
        author_is_bot: true
      ),
      comment("proposal-1-consent", "同意，创建吧", parent_id: "proposal-1", created_at: "2026-07-01T16:10:00Z", author_name: "Alice")
    ]
  end

  test "compute derives per-phase artifacts, awaiting phase, new replies, standalone comments, and proposals" do
    facts = RoutingBrief.compute(realistic_thread())

    assert facts == %{
             phases: [
               %{
                 phase: "Requirements",
                 rounds: 2,
                 artifact: %{
                   id: "req-2",
                   created_at: "2026-07-01T12:10:00Z",
                   status: "closed_approved",
                   closed_at: "2026-07-01T13:00:00Z",
                   needs_clarification: false,
                   new_replies: [
                     %{
                       id: "req-2-late",
                       author_name: "Alice",
                       author_is_bot: false,
                       maestro: false,
                       created_at: "2026-07-01T15:00:00Z",
                       excerpt: "另外记得更新文档"
                     }
                   ]
                 }
               },
               %{
                 phase: "Design",
                 rounds: 1,
                 artifact: %{
                   id: "design-1",
                   created_at: "2026-07-01T13:30:00Z",
                   status: "closed_auto",
                   closed_at: "2026-07-01T13:35:00Z",
                   needs_clarification: false,
                   new_replies: []
                 }
               },
               %{
                 phase: "Implementation",
                 rounds: 1,
                 artifact: %{
                   id: "impl-1",
                   created_at: "2026-07-01T14:00:00Z",
                   status: "awaiting",
                   closed_at: nil,
                   needs_clarification: true,
                   new_replies: [
                     %{
                       id: "impl-1-q",
                       author_name: "Alice",
                       author_is_bot: false,
                       maestro: false,
                       created_at: "2026-07-01T16:00:00Z",
                       excerpt: "staging 环境即可"
                     },
                     %{
                       id: "impl-1-maestro",
                       author_name: "Maestro",
                       author_is_bot: true,
                       maestro: true,
                       created_at: "2026-07-01T16:05:00Z",
                       excerpt: "🤖 Maestro 预审核: 建议回复方式: approve 置信度 8/10"
                     }
                   ]
                 }
               },
               %{phase: "Deployment", rounds: 0, artifact: nil}
             ],
             awaiting_phase: "Implementation",
             needs_clarification: true,
             standalone_comments: [
               %{
                 id: "standalone-1",
                 author_name: "Bob",
                 author_is_bot: false,
                 created_at: "2026-07-01T15:30:00Z",
                 excerpt: "整体方向 OK，注意兼容旧版本"
               }
             ],
             proposals: [%{id: "proposal-1", title: "## 建议新建 issue：抽出 X 模块", has_new_replies: true}]
           }

    assert RoutingBrief.compute(Enum.reverse(realistic_thread())) == facts
  end

  test "render turns the realistic facts into a compact factual brief" do
    markdown = realistic_thread() |> RoutingBrief.compute() |> RoutingBrief.render()

    assert markdown =~ "确定性计算"
    assert markdown =~ "- 待审阶段：Implementation（artifact `impl-1`，发布于 2026-07-01T14:00:00Z）"
    assert markdown =~ "- 待审 artifact 含未决澄清 gate"
    assert markdown =~ "| Requirements | `req-2` | closed_approved | 2026-07-01T12:10:00Z | 2026-07-01T13:00:00Z | 2 |"
    assert markdown =~ "| Design | `design-1` | closed_auto | 2026-07-01T13:30:00Z | 2026-07-01T13:35:00Z | 1 |"
    assert markdown =~ "| Implementation | `impl-1` | awaiting | 2026-07-01T14:00:00Z | — | 1 |"
    assert markdown =~ "| Deployment | — | — | — | — | 0 |"
    assert markdown =~ "- [Requirements `req-2`] Alice（2026-07-01T15:00:00Z）：另外记得更新文档"
    assert markdown =~ "- [Implementation `impl-1`] Alice（2026-07-01T16:00:00Z）：staging 环境即可"
    assert markdown =~ "- [Implementation `impl-1`] Maestro [bot] [maestro]（2026-07-01T16:05:00Z）：🤖 Maestro 预审核: 建议回复方式: approve 置信度 8/10"
    assert markdown =~ "- `standalone-1` Bob（2026-07-01T15:30:00Z）：整体方向 OK，注意兼容旧版本"
    assert markdown =~ "- `proposal-1` ## 建议新建 issue：抽出 X 模块（线程有新回复）"

    refute markdown =~ "req-2-early"
    refute markdown =~ "status-card"
    refute markdown =~ "standalone-resolved"

    assert markdown |> String.split("\n") |> length() <= 40
  end

  test "a fresh awaiting artifact without clarification markers keeps the flag off" do
    facts =
      RoutingBrief.compute([
        comment("req-1", "## Requirements\n\n目标", created_at: "2026-07-01T10:00:00Z", author_is_bot: true)
      ])

    assert facts.awaiting_phase == "Requirements"
    assert facts.needs_clarification == false
    assert [%{phase: "Requirements", rounds: 1, artifact: %{status: "awaiting", new_replies: []}} | _rest] = facts.phases
  end

  test "a proposal without replies reports has_new_replies false" do
    facts =
      RoutingBrief.compute([
        comment("proposal-1", "## 建议新建 issue：只提案没人理", created_at: "2026-07-01T10:00:00Z", author_is_bot: true)
      ])

    assert facts.proposals == [%{id: "proposal-1", title: "## 建议新建 issue：只提案没人理", has_new_replies: false}]
  end

  test "excerpts collapse whitespace and truncate to 280 characters" do
    long_body = String.duplicate("很长的一段反馈\n带换行 ", 40)

    facts =
      RoutingBrief.compute([
        comment("standalone-long", long_body, created_at: "2026-07-01T10:00:00Z", author_name: "Alice")
      ])

    assert [%{excerpt: excerpt}] = facts.standalone_comments
    assert String.length(excerpt) == 281
    assert String.ends_with?(excerpt, "…")
    refute excerpt =~ "\n"
  end

  test "empty comment lists render an explicit no-artifact brief" do
    markdown = [] |> RoutingBrief.compute() |> RoutingBrief.render()

    assert markdown =~ "无未决 artifact"
    assert markdown =~ "Requirements 尚未发布"
    refute markdown =~ "| 阶段 |"
    assert markdown =~ "新回复：\n- 无"
  end

  test "compute tolerates malformed comments and timestamps" do
    facts =
      RoutingBrief.compute([
        :not_a_comment,
        %{id: "req-1", body: "## Requirements\n\n目标", created_at: "not-a-timestamp"},
        %{id: "req-1-reply", body: "普通回复", parent_id: "req-1"}
      ])

    assert facts.awaiting_phase == "Requirements"

    assert facts.standalone_comments == [
             %{id: nil, author_name: nil, author_is_bot: false, created_at: nil, excerpt: ""}
           ]

    markdown = RoutingBrief.render(facts)
    assert markdown =~ "- [Requirements `req-1`] 未知作者（时间未知）：普通回复"
    assert markdown =~ "- `` 未知作者（时间未知）："
  end

  test "build with the memory tracker and no comments is available with a no-artifact brief" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert %{available: true, markdown: markdown} = RoutingBrief.build(%Issue{id: "issue-empty", identifier: "MT-1"})
    assert markdown =~ "无未决 artifact"
  end

  test "build with the memory tracker renders configured comments" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-77" => [
        comment("req-1", "## Requirements\n\n目标", created_at: ~U[2026-07-01 10:00:00Z], author_is_bot: true)
      ]
    })

    assert %{available: true, markdown: markdown} = RoutingBrief.build(%Issue{id: "issue-77", identifier: "MT-77"})
    assert markdown =~ "- 待审阶段：Requirements（artifact `req-1`，发布于 2026-07-01T10:00:00Z）"
  end

  test "build reports unavailable when the tracker errors, raises, or the issue has no id" do
    unavailable = %{available: false, markdown: "（引擎未能获取 Linear 评论，请按原流程自行读取与判断。）"}

    Application.put_env(:symphony_elixir, :linear_client_module, ErrorLinearClient)
    assert RoutingBrief.build(%Issue{id: "issue-1", identifier: "MT-1"}) == unavailable

    Application.put_env(:symphony_elixir, :linear_client_module, RaisingLinearClient)
    assert RoutingBrief.build(%Issue{id: "issue-1", identifier: "MT-1"}) == unavailable

    Application.put_env(:symphony_elixir, :linear_client_module, ThrowingLinearClient)
    assert RoutingBrief.build(%Issue{id: "issue-1", identifier: "MT-1"}) == unavailable

    assert RoutingBrief.build(%Issue{id: nil, identifier: "MT-1"}) == unavailable
  end

  defp comment(id, body, opts) do
    %{
      id: id,
      body: body,
      created_at: Keyword.fetch!(opts, :created_at),
      parent_id: Keyword.get(opts, :parent_id),
      author_name: Keyword.get(opts, :author_name),
      author_is_bot: Keyword.get(opts, :author_is_bot, false),
      resolved_at: Keyword.get(opts, :resolved_at)
    }
  end
end
