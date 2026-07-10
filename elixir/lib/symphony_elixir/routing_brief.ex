defmodule SymphonyElixir.RoutingBrief do
  @moduledoc """
  Deterministic pre-computation of Phase Artifact Protocol routing facts.

  `build/1` fetches the issue's tracker comments and renders a compact Chinese
  markdown block of mechanical facts — current artifact and status per phase,
  the awaiting-review phase, new thread replies, standalone comments,
  unresolved proposals, and clarification markers — injected into the
  first-turn prompt as the `routing_brief` template variable. Intent
  interpretation stays with the LLM: the brief states facts only and never
  recommends an action.

  `compute/1` and `render/1` are the pure core; `build/1` never raises and
  falls back to an "unavailable" placeholder when the tracker read fails.
  Marker and heading conventions are shared with `SymphonyElixir.PhaseEvents`.
  """

  alias SymphonyElixir.{PhaseEvents, Tracker}

  @phases ["Requirements", "Design", "Implementation", "Deployment"]
  @status_card_prefix "## 📍 状态"
  @proposal_prefix "## 建议新建 issue"
  @agent_closing_markers [:approved, :auto_advanced, :reworked, :rollback]
  @excerpt_limit 280

  @unavailable_markdown "（引擎未能获取 Linear 评论，请按原流程自行读取与判断。）"

  @type brief :: %{available: boolean(), markdown: String.t()}

  @spec build(term()) :: brief()
  def build(issue) do
    case Tracker.fetch_issue_comments(issue_id!(issue)) do
      {:ok, comments} -> %{available: true, markdown: comments |> compute() |> render()}
      {:error, _reason} -> unavailable()
    end
  rescue
    _error -> unavailable()
  catch
    _kind, _reason -> unavailable()
  end

  @doc """
  Pure fact derivation over normalized tracker comments (see
  `t:SymphonyElixir.PhaseEvents.comment/0`).
  """
  @spec compute([map()]) :: map()
  def compute(comments) when is_list(comments) do
    sorted = comments |> Enum.map(&normalize_comment/1) |> Enum.sort_by(& &1.sort_key)
    {top_level, replies} = Enum.split_with(sorted, &is_nil(&1.parent_id))
    replies_by_parent = Enum.group_by(replies, & &1.parent_id)

    phase_entries = Enum.map(@phases, &phase_entry(&1, top_level, replies_by_parent))
    {awaiting_facts, _awaiting_comment} = awaiting_entry(phase_entries)

    %{
      phases: Enum.map(phase_entries, &elem(&1, 0)),
      awaiting_phase: awaiting_facts && awaiting_facts.phase,
      needs_clarification: awaiting_facts != nil and awaiting_facts.artifact.needs_clarification,
      standalone_comments: standalone_comments(top_level),
      proposals: proposals(top_level, replies_by_parent)
    }
  end

  @doc """
  Renders computed facts as a compact Chinese markdown block. Facts only — no
  recommendations and no intent interpretation.
  """
  @spec render(map()) :: String.t()
  def render(facts) do
    [
      "（以下路由事实由引擎从 Linear 评论确定性计算，仅描述状态，不含意图判断。）",
      "",
      awaiting_lines(facts),
      phase_table(facts.phases),
      reply_section(facts.phases),
      standalone_section(facts.standalone_comments),
      proposal_section(facts.proposals)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp unavailable, do: %{available: false, markdown: @unavailable_markdown}

  defp issue_id!(%{id: id}) when is_binary(id), do: id

  # --- fact computation -----------------------------------------------------

  defp normalize_comment(comment) do
    body = comment_field(comment, :body) || ""

    %{
      id: comment_field(comment, :id),
      body: body,
      parent_id: comment_field(comment, :parent_id),
      author_name: comment_field(comment, :author_name),
      author_is_bot: comment_field(comment, :author_is_bot) == true,
      resolved?: comment_field(comment, :resolved_at) != nil,
      phase: PhaseEvents.phase_of_artifact(body),
      marker: PhaseEvents.reply_marker(body),
      sort_key: sort_key(comment_field(comment, :created_at)),
      created_at: iso_timestamp(comment_field(comment, :created_at))
    }
  end

  defp comment_field(comment, key) when is_map(comment), do: Map.get(comment, key)
  defp comment_field(_comment, _key), do: nil

  defp sort_key(%DateTime{} = created_at), do: DateTime.to_unix(created_at, :microsecond)

  defp sort_key(created_at) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _error -> 0
    end
  end

  defp sort_key(_created_at), do: 0

  defp iso_timestamp(%DateTime{} = created_at), do: DateTime.to_iso8601(created_at)
  defp iso_timestamp(created_at) when is_binary(created_at), do: created_at
  defp iso_timestamp(_created_at), do: nil

  defp phase_entry(phase, top_level, replies_by_parent) do
    artifacts = Enum.filter(top_level, &(&1.phase == phase))
    current = artifacts |> Enum.reject(& &1.resolved?) |> List.last()
    thread = (current && Map.get(replies_by_parent, current.id, [])) || []

    facts = %{
      phase: phase,
      rounds: length(artifacts),
      artifact: current && artifact_facts(current, thread)
    }

    {facts, current}
  end

  defp artifact_facts(artifact, thread) do
    closing = thread |> Enum.filter(&(&1.marker in [:approved, :auto_advanced])) |> List.last()
    last_agent_marker = thread |> Enum.filter(&(&1.marker in @agent_closing_markers)) |> List.last()

    new_replies =
      thread
      |> Enum.filter(fn reply -> last_agent_marker == nil or reply.sort_key > last_agent_marker.sort_key end)
      |> Enum.map(&reply_facts/1)

    %{
      id: artifact.id,
      created_at: artifact.created_at,
      status: artifact_status(closing),
      closed_at: closing && closing.created_at,
      needs_clarification: PhaseEvents.needs_clarification?(artifact.body),
      new_replies: new_replies
    }
  end

  defp artifact_status(nil), do: "awaiting"
  defp artifact_status(%{marker: :approved}), do: "closed_approved"
  defp artifact_status(%{marker: :auto_advanced}), do: "closed_auto"

  defp awaiting_entry(phase_entries) do
    phase_entries
    |> Enum.filter(fn {facts, _current} -> facts.artifact != nil and facts.artifact.status == "awaiting" end)
    |> Enum.max_by(fn {_facts, current} -> current.sort_key end, fn -> {nil, nil} end)
  end

  defp reply_facts(reply) do
    %{
      id: reply.id,
      author_name: reply.author_name,
      author_is_bot: reply.author_is_bot,
      maestro: maestro_reply?(reply),
      created_at: reply.created_at,
      excerpt: excerpt(reply.body)
    }
  end

  defp maestro_reply?(%{marker: :maestro_review}), do: true
  defp maestro_reply?(%{author_name: name}) when is_binary(name), do: name |> String.downcase() |> String.contains?("maestro")
  defp maestro_reply?(_reply), do: false

  defp standalone_comments(top_level) do
    top_level
    |> Enum.reject(fn comment ->
      comment.resolved? or comment.phase != nil or status_card?(comment) or proposal?(comment)
    end)
    |> Enum.map(fn comment ->
      %{
        id: comment.id,
        author_name: comment.author_name,
        author_is_bot: comment.author_is_bot,
        created_at: comment.created_at,
        excerpt: excerpt(comment.body)
      }
    end)
  end

  defp proposals(top_level, replies_by_parent) do
    top_level
    |> Enum.filter(fn comment -> proposal?(comment) and not comment.resolved? end)
    |> Enum.map(fn comment ->
      new_replies? =
        replies_by_parent
        |> Map.get(comment.id, [])
        |> Enum.any?(&(&1.sort_key > comment.sort_key))

      %{id: comment.id, title: title_line(comment.body), has_new_replies: new_replies?}
    end)
  end

  defp status_card?(comment), do: heading?(comment.body, @status_card_prefix)
  defp proposal?(comment), do: heading?(comment.body, @proposal_prefix)

  defp heading?(body, prefix), do: body |> String.trim_leading() |> String.starts_with?(prefix)

  defp title_line(body) do
    body
    |> String.trim_leading()
    |> String.split("\n", parts: 2)
    |> List.first()
    |> excerpt()
  end

  defp excerpt(body) do
    collapsed =
      body
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(collapsed) > @excerpt_limit do
      String.slice(collapsed, 0, @excerpt_limit) <> "…"
    else
      collapsed
    end
  end

  # --- rendering ------------------------------------------------------------

  defp awaiting_lines(%{awaiting_phase: nil} = facts) do
    if Enum.all?(facts.phases, &(&1.rounds == 0 and &1.artifact == nil)) do
      ["- 待审阶段：无（无未决 artifact；尚无任何 phase artifact，Requirements 尚未发布）"]
    else
      ["- 待审阶段：无（无未决 artifact 在等待审核）"]
    end
  end

  defp awaiting_lines(facts) do
    artifact =
      facts.phases
      |> Enum.find(&(&1.phase == facts.awaiting_phase))
      |> Map.fetch!(:artifact)

    lines = ["- 待审阶段：#{facts.awaiting_phase}（artifact `#{artifact.id}`，发布于 #{timestamp(artifact.created_at)}）"]

    if facts.needs_clarification do
      lines ++ ["- 待审 artifact 含未决澄清 gate"]
    else
      lines
    end
  end

  defp phase_table(phases) do
    if Enum.all?(phases, &(&1.rounds == 0 and &1.artifact == nil)) do
      []
    else
      [
        "",
        "| 阶段 | 当前 artifact | 状态 | 发布时间 | 关闭回复时间 | 累计轮次 |",
        "| --- | --- | --- | --- | --- | --- |"
      ] ++
        Enum.map(phases, &phase_row/1) ++
        ["", "状态为机械判定：awaiting = 线程无 ✅/⏩ 关闭回复；closed_approved = 有 ✅ 已批准 回复；closed_auto = 有 ⏩ 回复。已 resolve 的 artifact 属历史，仅计入轮次。"]
    end
  end

  defp phase_row(%{artifact: nil} = phase) do
    "| #{phase.phase} | — | — | — | — | #{phase.rounds} |"
  end

  defp phase_row(%{artifact: artifact} = phase) do
    closed_at = if artifact.closed_at, do: timestamp(artifact.closed_at), else: "—"

    "| #{phase.phase} | `#{artifact.id}` | #{artifact.status} | #{timestamp(artifact.created_at)} | #{closed_at} | #{phase.rounds} |"
  end

  defp reply_section(phases) do
    lines =
      for %{phase: phase, artifact: %{new_replies: replies} = artifact} <- phases,
          reply <- replies do
        "- [#{phase} `#{artifact.id}`] #{author_label(reply)}（#{timestamp(reply.created_at)}）：#{reply.excerpt}"
      end

    ["", "未决 artifact 线程中、agent 最后一条 ✅/⏩/🔧/🔄 回复之后的新回复："] ++ or_none(lines)
  end

  defp standalone_section(standalone_comments) do
    lines =
      Enum.map(standalone_comments, fn comment ->
        "- `#{comment.id}` #{author_label(comment)}（#{timestamp(comment.created_at)}）：#{comment.excerpt}"
      end)

    ["", "未 resolve 的独立顶层评论（非 phase artifact / 状态卡 / 提案）："] ++ or_none(lines)
  end

  defp proposal_section(proposals) do
    lines =
      Enum.map(proposals, fn proposal ->
        replies_note = if proposal.has_new_replies, do: "线程有新回复", else: "线程无回复"
        "- `#{proposal.id}` #{proposal.title}（#{replies_note}）"
      end)

    ["", "未 resolve 的 `## 建议新建 issue` 提案："] ++ or_none(lines)
  end

  defp or_none([]), do: ["- 无"]
  defp or_none(lines), do: lines

  defp author_label(comment) do
    name = comment.author_name || "未知作者"

    tags =
      [
        if(comment.author_is_bot, do: "[bot]"),
        if(Map.get(comment, :maestro), do: "[maestro]")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join([name | tags], " ")
  end

  defp timestamp(nil), do: "时间未知"
  defp timestamp(value), do: value
end
