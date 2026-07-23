defmodule SymphonyElixir.PhaseEventsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PhaseEvents
  @maestro_actor_id "maestro-app"

  test "phase_of_artifact recognizes phase headings with leading whitespace and rejects everything else" do
    assert PhaseEvents.phase_of_artifact("## Requirements\n\n目标") == "Requirements"
    assert PhaseEvents.phase_of_artifact("## Design\n\n模块拆分") == "Design"
    assert PhaseEvents.phase_of_artifact("  \n\t## Implementation\nPR: …") == "Implementation"
    assert PhaseEvents.phase_of_artifact("## Deployment") == "Deployment"

    assert PhaseEvents.phase_of_artifact("## Designs\n\n复数不算") == nil
    assert PhaseEvents.phase_of_artifact("### Design\n\n层级不对") == nil
    assert PhaseEvents.phase_of_artifact("普通评论，提到 ## Requirements 也不算") == nil
    assert PhaseEvents.phase_of_artifact("") == nil
    assert PhaseEvents.phase_of_artifact(nil) == nil
    assert PhaseEvents.reply_marker(nil) == nil
  end

  test "derives ordered events for a realistic multi-round thread regardless of input order" do
    comments = [
      comment("design-2-rework", "🔧 本轮修改：按反馈调整了模块边界。", parent_id: "design-2", created_at: "2026-07-01T14:05:00Z"),
      comment("req-1", "## Requirements\n\n### 目标\n交付分析事件解析。", created_at: "2026-07-01T10:00:00Z", author_name: "symphony-agent", author_is_bot: true),
      comment("impl-1-rollback", "🔄 反馈要求回到 Design，当前阶段暂停", parent_id: "impl-1", created_at: "2026-07-01T13:00:00Z"),
      comment("design-1-approve", "✅ 已批准，进入 Implementation（2026-07-01T11:00:00Z）", parent_id: "design-1", created_at: "2026-07-01T11:00:00Z", author_name: "Alice"),
      comment("design-2", "## Design\n\n模块拆分（第 2 版）。", created_at: "2026-07-01T14:00:00Z", author_name: "symphony-agent", author_is_bot: true),
      comment("req-1-advance", "⏩ 自动进入 Design（agent 自评通过，未经人工评审，2026-07-01T10:05:00Z）",
        parent_id: "req-1",
        created_at: "2026-07-01T10:05:00Z",
        author_name: "symphony-agent"
      ),
      comment("impl-1", "## Implementation\n\nPR: https://github.com/x/y/pull/1", created_at: "2026-07-01T12:00:00Z", author_name: "symphony-agent", author_is_bot: true),
      comment("design-1", "## Design\n\n模块拆分。",
        created_at: "2026-07-01T10:10:00Z",
        author_name: "symphony-agent",
        author_is_bot: true,
        resolved_at: "2026-07-01T13:30:00Z"
      )
    ]

    events = PhaseEvents.derive(comments)

    assert events == [
             %{
               event_type: "phase_published",
               event_id: "phase_published:req-1",
               phase: "Requirements",
               comment_id: "req-1",
               occurred_at: "2026-07-01T10:00:00Z",
               needs_clarification: false,
               author_name: "symphony-agent"
             },
             %{
               event_type: "phase_auto_advanced",
               event_id: "phase_auto_advanced:req-1-advance",
               phase: "Requirements",
               artifact_comment_id: "req-1",
               comment_id: "req-1-advance",
               occurred_at: "2026-07-01T10:05:00Z",
               author_name: "symphony-agent"
             },
             %{
               event_type: "phase_published",
               event_id: "phase_published:design-1",
               phase: "Design",
               comment_id: "design-1",
               occurred_at: "2026-07-01T10:10:00Z",
               needs_clarification: false,
               author_name: "symphony-agent"
             },
             %{
               event_type: "phase_approved",
               event_id: "phase_approved:design-1-approve",
               phase: "Design",
               artifact_comment_id: "design-1",
               comment_id: "design-1-approve",
               occurred_at: "2026-07-01T11:00:00Z",
               author_name: "Alice"
             },
             %{
               event_type: "phase_published",
               event_id: "phase_published:impl-1",
               phase: "Implementation",
               comment_id: "impl-1",
               occurred_at: "2026-07-01T12:00:00Z",
               needs_clarification: false,
               author_name: "symphony-agent"
             },
             %{
               event_type: "phase_rollback",
               event_id: "phase_rollback:impl-1-rollback",
               from_phase: "Implementation",
               target_phase: "Design",
               comment_id: "impl-1-rollback",
               occurred_at: "2026-07-01T13:00:00Z"
             },
             %{
               event_type: "phase_published",
               event_id: "phase_published:design-2",
               phase: "Design",
               comment_id: "design-2",
               occurred_at: "2026-07-01T14:00:00Z",
               needs_clarification: false,
               author_name: "symphony-agent"
             },
             %{
               event_type: "phase_reworked",
               event_id: "phase_reworked:design-2-rework",
               phase: "Design",
               artifact_comment_id: "design-2",
               comment_id: "design-2-rework",
               occurred_at: "2026-07-01T14:05:00Z"
             }
           ]

    assert PhaseEvents.derive(Enum.reverse(comments)) == events
    assert PhaseEvents.derive([]) == []
  end

  test "marks artifacts blocked on human input and keeps events for resolved artifacts" do
    comments = [
      comment(
        "req-1",
        """
        ## Requirements

        ___

        ### NEEDS CLARIFICATION

        > This needs an explicit human decision before the workflow can continue.

        Question: 哪个 Linear project 归属这项工作？

        ___
        """,
        created_at: "2026-07-01T10:00:00Z",
        resolved_at: "2026-07-02T00:00:00Z"
      ),
      comment("req-1-approve", "✅ 已批准，进入 Design（2026-07-02T09:00:00Z）", parent_id: "req-1", created_at: "2026-07-02T09:00:00Z", author_name: "Bob")
    ]

    assert [published, approved] = PhaseEvents.derive(comments)
    assert published.needs_clarification == true
    assert published.event_type == "phase_published"

    assert approved == %{
             event_type: "phase_approved",
             event_id: "phase_approved:req-1-approve",
             phase: "Requirements",
             artifact_comment_id: "req-1",
             comment_id: "req-1-approve",
             occurred_at: "2026-07-02T09:00:00Z",
             author_name: "Bob"
           }
  end

  test "needs_clarification? keeps legacy bracket marker compatibility" do
    assert PhaseEvents.needs_clarification?("## Design\n\n### NEEDS CLARIFICATION\n\nQuestion: 选哪个？")
    assert PhaseEvents.needs_clarification?("## Design\n\n[NEEDS CLARIFICATION: 选哪个？]")
    refute PhaseEvents.needs_clarification?("## Design\n\nQuestion: 选哪个？")
    refute PhaseEvents.needs_clarification?(nil)
  end

  test "tolerates leading whitespace and markdown decoration around markers" do
    comments = [
      comment("design-1", "\n   ## Design\n\n内容", created_at: "2026-07-01T10:00:00Z"),
      comment("quoted-approve", "> ✅ 已批准，进入 Implementation（2026-07-01T11:00:00Z）", parent_id: "design-1", created_at: "2026-07-01T11:00:00Z"),
      comment("bold-advance", "**⏩ 自动进入 Implementation（agent 自评通过，未经人工评审）**", parent_id: "design-1", created_at: "2026-07-01T12:00:00Z"),
      comment("dashed-rework", "- 🔧 本轮修改：小改", parent_id: "design-1", created_at: "2026-07-01T13:00:00Z")
    ]

    assert ["phase_published", "phase_approved", "phase_auto_advanced", "phase_reworked"] =
             comments |> PhaseEvents.derive() |> Enum.map(& &1.event_type)
  end

  test "rollback target parsing tolerates brackets and falls back to nil when unparseable" do
    events =
      PhaseEvents.derive([
        comment("impl-1", "## Implementation\n\nPR", created_at: "2026-07-01T10:00:00Z"),
        comment("rollback-bracketed", "🔄 反馈要求回到 [Requirements]，当前阶段暂停", parent_id: "impl-1", created_at: "2026-07-01T11:00:00Z"),
        comment("rollback-unparseable", "🔄 反馈要求回到上一阶段，当前阶段暂停", parent_id: "impl-1", created_at: "2026-07-01T12:00:00Z")
      ])

    assert [_published, bracketed, unparseable] = events
    assert %{event_type: "phase_rollback", from_phase: "Implementation", target_phase: "Requirements"} = bracketed
    assert %{event_type: "phase_rollback", from_phase: "Implementation", target_phase: nil} = unparseable
  end

  test "ignores plain replies, replies outside artifact threads, and non-artifact top-level comments" do
    comments = [
      comment("chatter", "大家注意一下这个 issue 的范围。", created_at: "2026-07-01T09:00:00Z"),
      comment("req-1", "## Requirements\n\n目标", created_at: "2026-07-01T10:00:00Z"),
      comment("human-reply", "看起来不错，我再想想。", parent_id: "req-1", created_at: "2026-07-01T11:00:00Z"),
      comment("orphan-approve", "✅ 已批准，进入 Design（2026-07-01T12:00:00Z）", parent_id: "chatter", created_at: "2026-07-01T12:00:00Z"),
      comment("nested-reply", "✅ 已批准，进入 Design（2026-07-01T13:00:00Z）", parent_id: "human-reply", created_at: "2026-07-01T13:00:00Z")
    ]

    assert [%{event_type: "phase_published", comment_id: "req-1"}] = PhaseEvents.derive(comments)
  end

  test "parses maestro reviews with slash confidence and approve recommendation" do
    event =
      derive_maestro_event("""
      🤖 Maestro 预审核: 本轮 Implementation 交付可以接受。

      建议回复方式: approve
      置信度 8/10，测试齐全、PR 描述完整。
      """)

    assert event == %{
             event_type: "maestro_review",
             event_id: "maestro_review:maestro-reply",
             phase: "Implementation",
             artifact_comment_id: "impl-1",
             recommendation: "approve",
             confidence: 8.0,
             auto: false,
             comment_id: "maestro-reply",
             occurred_at: "2026-07-01T11:00:00Z"
           }
  end

  test "parses maestro labeled confidence, request changes normalization, and auto marker" do
    event =
      derive_maestro_event("""
      🤖 Maestro 预审核（🤖 auto）

      **建议回复方式**：request changes，理由如下。
      置信度：7
      """)

    assert %{recommendation: "request_changes", confidence: 7.0, auto: true} = event

    assert %{recommendation: "request_changes"} = derive_maestro_event("🤖 Maestro 预审核\n建议回复方式: request_changes / rework")
  end

  test "parses each maestro recommendation value and handles missing confidence" do
    for {line, recommendation} <- [
          {"建议回复方式: approve", "approve"},
          {"建议回复方式: request changes", "request_changes"},
          {"建议回复方式: ask clarification", "ask_clarification"},
          {"建议回复方式: merge nudge", "merge_nudge"},
          {"建议回复方式: completion confirmation", "completion_confirmation"},
          {"建议回复方式：**no reply yet**（等待人工）", "no_reply_yet"}
        ] do
      event = derive_maestro_event("🤖 Maestro 预审核:\n#{line}")
      assert event.recommendation == recommendation
      assert event.confidence == nil
      assert event.auto == false
    end
  end

  test "parses ESCALATED convergence cards and their human-action routing fields" do
    event = derive_maestro_event(render_card(continue_card_fields(), "- **", "**"))

    assert %{
             recommendation: "continue_implementation",
             target_phase: "Implementation",
             target_status: "In Progress",
             execution_state: "awaiting_human_action",
             auto: false
           } = event

    assert %{recommendation: "continue_implementation"} =
             derive_maestro_event(render_card(continue_card_fields(), "> **", "**"))

    assert %{recommendation: "continue_implementation"} =
             derive_maestro_event(
               render_card(continue_card_fields()) <>
                 "\n建议回复方式: continue implementation"
             )

    assert %{recommendation: "rework_design", target_phase: "Design", target_status: "Rework"} =
             derive_maestro_event(render_card(rework_card_fields()))

    assert %{recommendation: "ask_clarification", target_phase: "Implementation", target_status: "unchanged"} =
             derive_maestro_event(render_card(clarification_card_fields()))

    assert %{recommendation: "unknown", target_phase: nil, target_status: nil} =
             derive_maestro_event("""
             🤖 Maestro 预审核
             收敛判断: continue implementation
             建议 target phase: unknown
             建议 issue status: unknown
             """)

    assert %{recommendation: "unknown", target_phase: nil, target_status: nil, execution_state: nil} =
             derive_maestro_event("""
             🤖 Maestro 预审核
             收敛判断: continue implementation
             建议 target phase: Design or Implementation
             建议 issue status: Rework or In Progress
             执行状态: not awaiting human action
             """)

    assert %{recommendation: "unknown", target_phase: nil, target_status: nil} =
             derive_maestro_event("""
             🤖 Maestro 预审核
             收敛判断: continue implementation
             收敛判断: rework design
             建议 target phase: Implementation
             建议 target phase: Design
             建议 issue status: In Progress
             建议 issue status: Rework
             执行状态: awaiting human action
             """)
  end

  test "parses every judgment label in plain, single-emphasis, and double-emphasis forms" do
    fields = continue_card_fields()

    expected = %{
      recommendation: "continue_implementation",
      target_phase: "Implementation",
      target_status: "In Progress",
      execution_state: "awaiting_human_action"
    }

    for {selected_label, _value} <- fields, wrapper <- [& &1, &"*#{&1}*", &"**#{&1}**"] do
      body =
        fields
        |> Enum.map_join("\n", fn {label, value} ->
          rendered_label = if label == selected_label, do: wrapper.(label), else: label
          "#{rendered_label}: #{value}"
        end)

      event = derive_maestro_event("🤖 Maestro 预审核\n#{body}")
      assert ^expected = Map.take(event, Map.keys(expected))
    end
  end

  test "accepts either artifact id label but rejects both together" do
    reviewed_fields =
      Enum.map(continue_card_fields(), fn
        {"Implementation artifact id", value} -> {"Reviewed Implementation artifact id", value}
        field -> field
      end)

    assert %{recommendation: "continue_implementation"} =
             derive_maestro_event(render_card(reviewed_fields))

    assert %{recommendation: "continue_implementation"} =
             derive_maestro_event(
               render_card(
                 Enum.map(continue_card_fields(), fn
                   {"Implementation artifact id", value} ->
                     {"Implementation artifact id", "`#{value}`"}

                   field ->
                     field
                 end)
               )
             )

    assert %{recommendation: "unknown"} =
             derive_maestro_event(
               render_card(
                 continue_card_fields() ++
                   [{"Reviewed Implementation artifact id", "impl-1"}]
               )
             )

    assert %{recommendation: "unknown"} =
             derive_maestro_event(
               render_card(
                 Enum.map(continue_card_fields(), fn
                   {"Implementation artifact id", _value} ->
                     {"Implementation artifact id", "impl-stale"}

                   field ->
                     field
                 end)
               )
             )
  end

  test "rejects non-exact, fenced, empty, contradictory, and duplicate convergence fields" do
    valid_fields = [
      {"收敛判断", "continue implementation", "rework design"},
      {"建议 target phase", "Implementation", "Design"},
      {"建议 issue status", "In Progress", "Rework"},
      {"执行状态", "awaiting human action", "completed"}
    ]

    for {selected_label, value, contradictory_value} <- valid_fields,
        replacement <- [
          "***#{selected_label}***: #{value}",
          "\\*#{selected_label}\\*: #{value}",
          "*#{selected_label}: #{value}",
          "* #{selected_label} *: #{value}",
          "```\n#{selected_label}: #{value}\n```",
          "#{selected_label}:",
          "#{selected_label}: #{value}\n#{selected_label}: #{contradictory_value}",
          "#{selected_label}: #{value}\n*#{selected_label}*: #{value}\n**#{selected_label}**: #{value}"
        ] do
      fields =
        valid_fields
        |> Enum.map_join("\n", fn
          {^selected_label, _value, _contradictory_value} -> replacement
          {label, field_value, _contradictory_value} -> "#{label}: #{field_value}"
        end)
        |> Kernel.<>(
          "\n" <>
            (continue_card_fields()
             |> Enum.drop(4)
             |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{value}" end))
        )

      assert %{recommendation: "unknown"} = derive_maestro_event("🤖 Maestro 预审核\n#{fields}")
    end
  end

  test "rejects convergence cards with missing, duplicate, or empty base detail fields" do
    required_details = [
      "Implementation artifact id",
      "PR Head",
      "判断理由",
      "下一轮建议方向"
    ]

    for selected_label <- required_details,
        fields <- [
          Enum.reject(continue_card_fields(), &match?({^selected_label, _value}, &1)),
          continue_card_fields() ++ [{selected_label, "duplicate"}],
          Enum.map(continue_card_fields(), fn
            {^selected_label, _value} -> {selected_label, ""}
            field -> field
          end)
        ] do
      assert %{recommendation: "unknown"} = derive_maestro_event(render_card(fields))
    end
  end

  test "rejects convergence cards with incomplete decision-specific details" do
    for {fields, required_details} <- [
          {rework_card_fields(),
           [
             "失效的 Design assumption",
             "建议修改的机制或边界",
             "下一轮 proof / acceptance criteria",
             "不受影响的既有约束"
           ]},
          {clarification_card_fields(), ["待人工回答的问题", "回答判定标准"]}
        ],
        selected_label <- required_details,
        malformed_fields <- [
          Enum.reject(fields, &match?({^selected_label, _value}, &1)),
          fields ++ [{selected_label, "duplicate"}],
          Enum.map(fields, fn
            {^selected_label, _value} -> {selected_label, ""}
            field -> field
          end)
        ] do
      assert %{recommendation: "unknown"} = derive_maestro_event(render_card(malformed_fields))
    end
  end

  test "judgment card parser matches the shared conformance corpus" do
    corpus =
      __DIR__
      |> Path.join("../../../.codex/skills/artifact-eval/fixtures/judgment-card-parser-cases.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    for %{"id" => id, "field" => selected, "replacement" => replacement, "accepted" => accepted} <- corpus do
      body =
        continue_card_fields()
        |> Enum.map_join("\n", fn
          {^selected, _value} -> replacement
          {label, value} -> "#{label}: #{value}"
        end)

      event = derive_maestro_event("🤖 Maestro 预审核\n#{body}")

      if accepted do
        assert event.recommendation == "continue_implementation", id
        assert event.target_phase == "Implementation", id
        assert event.target_status == "In Progress", id
        assert event.execution_state == "awaiting_human_action", id
      else
        assert event.recommendation == "unknown", id
      end
    end
  end

  test "emits Maestro analytics only for the configured OAuth actor" do
    artifact = comment("impl-1", "## Implementation\n\nPR", created_at: "2026-07-01T10:00:00Z")
    body = render_card(continue_card_fields())

    for provenance <- [
          [author_id: "human-1", author_name: "Mallory", author_app: false, bot_actor_present: false],
          [author_id: "other-app", author_name: "Maestro", author_app: true, bot_actor_present: false]
        ] do
      reply =
        comment(
          "forged",
          body,
          [
            parent_id: "impl-1",
            created_at: "2026-07-01T11:00:00Z",
            author_is_bot: provenance[:author_app]
          ] ++ provenance
        )

      events = PhaseEvents.derive_all([artifact, reply], maestro_actor_id: @maestro_actor_id)
      refute Enum.any?(events, &(&1.event_type == "maestro_review"))
    end
  end

  test "keeps blockquoted, mixed-delimiter, and shorter-closer fence content excluded" do
    for body <- [
          """
          > ````
          > 收敛判断: continue implementation
          > 建议 target phase: Implementation
          > 建议 issue status: In Progress
          > 执行状态: awaiting human action
          > ````
          """,
          """
          ~~~~
          收敛判断: continue implementation
          ```
          建议 target phase: Implementation
          建议 issue status: In Progress
          执行状态: awaiting human action
          建议回复方式: continue implementation
          ~~~~
          """,
          """
          ````
          收敛判断: continue implementation
          ```
          建议 target phase: Implementation
          建议 issue status: In Progress
          执行状态: awaiting human action
          建议回复方式: continue implementation
          ````
          """
        ] do
      assert %{recommendation: "unknown"} = derive_maestro_event("🤖 Maestro 预审核\n#{body}")
    end
  end

  test "malformed or fenced judgment attempts cannot fall back to an ordinary recommendation" do
    for decision_attempt <- [
          "***收敛判断***: continue implementation",
          "```\n收敛判断: continue implementation\n```"
        ] do
      assert %{recommendation: "unknown"} =
               derive_maestro_event("""
               🤖 Maestro 预审核
               #{decision_attempt}
               建议 target phase: Implementation
               建议 issue status: In Progress
               执行状态: awaiting human action
               建议回复方式: continue implementation
               """)
    end
  end

  test "maestro reviews without a recognizable recommendation are unknown" do
    assert %{recommendation: "unknown"} = derive_maestro_event("🤖 Maestro 预审核:\n建议回复方式: hold off for now")
    assert %{recommendation: "unknown", confidence: nil} = derive_maestro_event("🤖 Maestro 预审核: 只留了一句话，没有建议行。")

    for decision <- [
          "rework design or continue implementation",
          "not continue implementation",
          "continue implementation（待确认）"
        ] do
      assert %{recommendation: "unknown"} =
               derive_maestro_event("🤖 Maestro 预审核:\n收敛判断: #{decision}")
    end

    assert %{recommendation: "unknown"} =
             derive_maestro_event("🤖 Maestro 预审核:\n理由里提到收敛判断，但没有字段。")
  end

  test "derive_all adds one human_comment event per non-bot comment, thread replies included" do
    comments = [
      comment("chatter", "先讨论一下范围。", created_at: "2026-07-01T09:00:00Z", author_name: "Bob"),
      comment("req-1", "## Requirements\n\n目标", created_at: "2026-07-01T10:00:00Z", author_name: "symphony-agent", author_is_bot: true),
      comment("req-1-approve", "✅ 已批准，进入 Design", parent_id: "req-1", created_at: "2026-07-01T11:00:00Z", author_name: "Alice"),
      comment("req-1-reply", "补充一个细节。", parent_id: "req-1", created_at: "2026-07-01T12:00:00Z", author_name: "Alice")
    ]

    events = PhaseEvents.derive_all(comments)

    assert Enum.map(events, & &1.event_id) == [
             "human-comment-chatter",
             "phase_published:req-1",
             "phase_approved:req-1-approve",
             "human-comment-req-1-approve",
             "human-comment-req-1-reply"
           ]

    assert %{
             event_type: "human_comment",
             event_id: "human-comment-chatter",
             occurred_at: "2026-07-01T09:00:00Z",
             author_name: "Bob"
           } == hd(events)

    # derive/1 keeps its phase-events-only contract for existing consumers.
    assert Enum.map(PhaseEvents.derive(comments), & &1.event_id) == [
             "phase_published:req-1",
             "phase_approved:req-1-approve"
           ]

    assert PhaseEvents.derive_all([]) == []
  end

  test "event ids are stable and deterministic across repeated derivations" do
    comments = [
      comment("req-1", "## Requirements\n\n目标", created_at: "2026-07-01T10:00:00Z"),
      comment("req-1-advance", "⏩ 自动进入 Design（agent 自评通过）", parent_id: "req-1", created_at: "2026-07-01T10:05:00Z")
    ]

    first = PhaseEvents.derive(comments)
    assert PhaseEvents.derive(comments) == first
    assert Enum.map(first, & &1.event_id) == ["phase_published:req-1", "phase_auto_advanced:req-1-advance"]
  end

  test "sorts DateTime timestamps chronologically and emits ISO 8601 occurred_at" do
    comments = [
      comment("design-1", "## Design\n\n跨月排序。", created_at: DateTime.new!(~D[2026-02-01], ~T[00:01:00], "Etc/UTC")),
      comment("req-1", "## Requirements\n\n先发布。", created_at: DateTime.new!(~D[2026-01-31], ~T[23:59:00], "Etc/UTC")),
      comment("req-1-approve", "✅ 已批准，进入 Design（缺时间戳）", parent_id: "req-1", created_at: nil)
    ]

    events = PhaseEvents.derive(comments)

    assert Enum.map(events, &{&1.event_type, &1.occurred_at}) == [
             {"phase_approved", nil},
             {"phase_published", "2026-01-31T23:59:00Z"},
             {"phase_published", "2026-02-01T00:01:00Z"}
           ]
  end

  defp derive_maestro_event(reply_body) do
    comments = [
      comment("impl-1", "## Implementation\n\nPR", created_at: "2026-07-01T10:00:00Z"),
      comment("maestro-reply", reply_body,
        parent_id: "impl-1",
        created_at: "2026-07-01T11:00:00Z",
        author_id: @maestro_actor_id,
        author_name: "Maestro",
        author_app: true,
        bot_actor_present: false,
        author_is_bot: true
      )
    ]

    assert [_published, event] = PhaseEvents.derive(comments, maestro_actor_id: @maestro_actor_id)
    event
  end

  defp continue_card_fields do
    [
      {"收敛判断", "continue implementation"},
      {"建议 target phase", "Implementation"},
      {"建议 issue status", "In Progress"},
      {"执行状态", "awaiting human action"},
      {"Implementation artifact id", "impl-1"},
      {"PR Head", "head-1"},
      {"判断理由", "finding family 已收敛"},
      {"下一轮建议方向", "继续修复剩余 finding"}
    ]
  end

  defp rework_card_fields do
    [
      {"收敛判断", "rework design"},
      {"建议 target phase", "Design"},
      {"建议 issue status", "Rework"},
      {"执行状态", "awaiting human action"},
      {"Implementation artifact id", "impl-1"},
      {"PR Head", "head-1"},
      {"判断理由", "同一 finding family 未收敛"},
      {"下一轮建议方向", "先修正 Design 边界"},
      {"失效的 Design assumption", "单一 session 可代表所有 review"},
      {"建议修改的机制或边界", "按 session 绑定状态动作"},
      {"下一轮 proof / acceptance criteria", "覆盖多 session actor"},
      {"不受影响的既有约束", "ESCALATED 仍由人类决策"}
    ]
  end

  defp clarification_card_fields do
    [
      {"收敛判断", "ask clarification"},
      {"建议 target phase", "Implementation"},
      {"建议 issue status", "unchanged"},
      {"执行状态", "awaiting human action"},
      {"Implementation artifact id", "impl-1"},
      {"PR Head", "head-1"},
      {"判断理由", "两条人工要求冲突"},
      {"下一轮建议方向", "按人工答案继续"},
      {"待人工回答的问题", "应采用哪个状态动作？"},
      {"回答判定标准", "明确选择 In Progress 或 Rework"}
    ]
  end

  defp render_card(fields, label_prefix \\ "", label_suffix \\ "") do
    "🤖 Maestro 预审核\n" <>
      Enum.map_join(fields, "\n", fn {label, value} ->
        "#{label_prefix}#{label}#{label_suffix}: #{value}"
      end)
  end

  defp comment(id, body, opts) do
    %{
      id: id,
      body: body,
      created_at: Keyword.fetch!(opts, :created_at),
      parent_id: Keyword.get(opts, :parent_id),
      author_name: Keyword.get(opts, :author_name),
      author_id: Keyword.get(opts, :author_id),
      author_app: Keyword.get(opts, :author_app, :unknown),
      bot_actor_present: Keyword.get(opts, :bot_actor_present, :unknown),
      author_is_bot: Keyword.get(opts, :author_is_bot, false),
      resolved_at: Keyword.get(opts, :resolved_at)
    }
  end
end
