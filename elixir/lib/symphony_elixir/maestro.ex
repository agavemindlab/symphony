defmodule SymphonyElixir.Maestro do
  @moduledoc """
  Pure parser and decision engine for Maestro review handoff comments.
  """

  alias SymphonyElixir.Maestro.{Decision, ReviewAttachment, ReviewComment, ReviewContext}

  @handoff_heading "## Review Handoff"
  @audit_heading "## Maestro Decision"

  @pr_review_status "Waiting for PR review"
  @completion_status "Waiting for completion confirmation"
  @requirement_status "Waiting for requirement confirmation"
  @plan_status "Waiting for plan confirmation"
  @blocked_status "Blocked"

  defmodule ReviewContext do
    @moduledoc """
    Review inputs gathered from the tracker before Maestro makes a decision.
    """

    defstruct issue: nil, issue_id: nil, comments: [], attachments: []

    @type t :: %__MODULE__{
            issue: term(),
            issue_id: String.t() | nil,
            comments: [ReviewComment.t()],
            attachments: [ReviewAttachment.t()]
          }
  end

  defmodule ReviewComment do
    @moduledoc """
    Tracker comment candidate that may contain a Maestro review handoff.
    """

    defstruct id: nil, body: "", created_at: nil, updated_at: nil

    @type t :: %__MODULE__{
            id: String.t() | nil,
            body: String.t(),
            created_at: String.t() | DateTime.t() | NaiveDateTime.t() | nil,
            updated_at: String.t() | DateTime.t() | NaiveDateTime.t() | nil
          }
  end

  defmodule ReviewAttachment do
    @moduledoc """
    Tracker attachment metadata that can provide PR or validation evidence.
    """

    defstruct id: nil, filename: nil, title: nil, url: nil, content_type: nil, source_type: nil

    @type t :: %__MODULE__{
            id: String.t() | nil,
            filename: String.t() | nil,
            title: String.t() | nil,
            url: String.t() | nil,
            content_type: String.t() | nil,
            source_type: String.t() | nil
          }
  end

  defmodule Decision do
    @moduledoc """
    Maestro's pure decision output for the tracker integration to apply.
    """

    defstruct status: nil,
              action: :change_state,
              target_state: nil,
              reasons: [],
              audit_comment_body: ""

    @type action :: :change_state | :no_state_change

    @type t :: %__MODULE__{
            status: String.t() | nil,
            action: action(),
            target_state: String.t() | nil,
            reasons: [String.t()],
            audit_comment_body: String.t()
          }
  end

  @type handoff :: %{body: String.t(), status: String.t() | nil}

  @spec run_once(keyword()) :: {:ok, [Decision.t()]} | {:error, term()}
  def run_once(opts \\ []) when is_list(opts) do
    tracker = Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
    states = Keyword.get(opts, :states, ["Human Review"])

    with {:ok, contexts} <- tracker.fetch_review_contexts_by_states(states) do
      apply_decisions(contexts, tracker, [])
    end
  end

  @spec decide(ReviewContext.t()) :: Decision.t()
  def decide(%ReviewContext{} = context) do
    context
    |> latest_handoff()
    |> decide_handoff(context.attachments)
  end

  defp apply_decisions([], _tracker, decisions), do: {:ok, Enum.reverse(decisions)}

  defp apply_decisions([context | rest], tracker, decisions) do
    decision = decide(context)

    case apply_decision(tracker, context, decision) do
      :ok -> apply_decisions(rest, tracker, [decision | decisions])
      {:error, reason} -> {:error, {:maestro_decision_failed, context_issue_id(context), reason}}
    end
  end

  defp apply_decision(tracker, context, %Decision{} = decision) do
    with {:ok, issue_id} <- fetch_context_issue_id(context),
         :ok <- tracker.create_comment(issue_id, decision.audit_comment_body) do
      case decision do
        %Decision{action: :change_state, target_state: target_state} when is_binary(target_state) ->
          tracker.update_issue_state(issue_id, target_state)

        %Decision{action: :no_state_change} ->
          :ok
      end
    end
  end

  defp fetch_context_issue_id(context) do
    case context_issue_id(context) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_issue_id}
    end
  end

  defp context_issue_id(%ReviewContext{issue_id: issue_id}) when is_binary(issue_id), do: issue_id
  defp context_issue_id(%ReviewContext{issue: %{id: issue_id}}) when is_binary(issue_id), do: issue_id
  defp context_issue_id(_context), do: nil

  defp latest_handoff(%ReviewContext{comments: comments}) do
    comments
    |> Enum.with_index()
    |> Enum.filter(fn {%ReviewComment{body: body}, _index} -> handoff_body?(body) end)
    |> Enum.max_by(
      fn {%ReviewComment{created_at: created_at}, index} ->
        {timestamp_sort_key(created_at), index}
      end,
      fn -> nil end
    )
    |> case do
      {%ReviewComment{body: body}, _index} -> %{body: body, status: extract_status(body)}
      nil -> nil
    end
  end

  defp handoff_body?(body) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(@handoff_heading)
  end

  defp handoff_body?(_body), do: false

  defp timestamp_sort_key(%DateTime{} = created_at), do: DateTime.to_iso8601(created_at)
  defp timestamp_sort_key(%NaiveDateTime{} = created_at), do: NaiveDateTime.to_iso8601(created_at)
  defp timestamp_sort_key(created_at) when is_binary(created_at), do: created_at
  defp timestamp_sort_key(_created_at), do: ""

  defp extract_status(body) do
    body
    |> String.split(["\r\n", "\n", "\r"], trim: false)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*(?:\*\*)?Status(?:\*\*)?\s*:\s*(.+?)\s*$/, line) do
        [_, status] -> String.trim(status)
        nil -> nil
      end
    end)
  end

  defp decide_handoff(nil, _attachments) do
    build_decision(nil, :change_state, "Rework", ["未找到 `## Review Handoff` comment"])
  end

  defp decide_handoff(%{status: nil}, _attachments) do
    build_decision(nil, :change_state, "Rework", ["Review Handoff 缺少 `Status:` 行"])
  end

  defp decide_handoff(%{status: @pr_review_status, body: body}, attachments) do
    body
    |> clean_reasons()
    |> add_reason_unless(has_validation_evidence?(body, attachments), "缺少验证证据")
    |> add_reason_unless(has_pr_evidence?(body, attachments), "缺少 PR 证据")
    |> case do
      [] -> build_decision(@pr_review_status, :change_state, "Merging", [])
      reasons -> build_decision(@pr_review_status, :change_state, "Rework", reasons)
    end
  end

  defp decide_handoff(%{status: @completion_status, body: body}, attachments) do
    body
    |> clean_reasons()
    |> add_reason_unless(has_completion_evidence?(body, attachments), "缺少 merge/completion 完成证据")
    |> case do
      [] -> build_decision(@completion_status, :change_state, "Done", [])
      reasons -> build_decision(@completion_status, :change_state, "Rework", reasons)
    end
  end

  defp decide_handoff(%{status: status, body: body}, _attachments)
       when status in [@requirement_status, @plan_status] do
    body
    |> failure_or_blocker_reasons()
    |> add_reason_unless(has_recommended_option?(body), "缺少明确推荐选项")
    |> case do
      [] -> build_decision(status, :change_state, "In Progress", [])
      reasons -> build_decision(status, :change_state, "Rework", reasons)
    end
  end

  defp decide_handoff(%{status: @blocked_status}, _attachments) do
    build_decision(@blocked_status, :no_state_change, nil, ["handoff 状态为 Blocked，需要人工解除阻塞"])
  end

  defp decide_handoff(%{status: status}, _attachments) do
    build_decision(status, :change_state, "Rework", ["不支持的 handoff status: #{status}"])
  end

  defp clean_reasons(body) do
    body
    |> failure_or_blocker_reasons()
    |> add_reason_unless(!unresolved_clarification?(body), "handoff 包含未解决的 clarification marker")
  end

  defp failure_or_blocker_reasons(body) do
    []
    |> add_reason_unless(!failure_evidence?(body), "handoff 包含失败或部分通过的验证证据")
    |> add_reason_unless(!blocker_evidence?(body), "handoff 包含 blocker 风险")
  end

  defp failure_evidence?(body) do
    String.contains?(body, "❌ 失败") or String.contains?(body, "⚠️ 部分通过")
  end

  defp blocker_evidence?(body) do
    lower_body = String.downcase(body)

    String.contains?(lower_body, "🚨 blocker") or
      Regex.match?(~r/warning.*blocker|blocker.*warning/s, lower_body)
  end

  defp unresolved_clarification?(body) do
    body
    |> String.downcase()
    |> String.contains?("[needs clarification")
  end

  defp has_validation_evidence?(body, attachments) do
    evidence =
      body
      |> evidence_text(attachments)
      |> String.downcase()

    Regex.match?(~r/✅\s*验证|validation|validated|verify|verified|mix test|test(s)?\s+passed/, evidence)
  end

  defp has_pr_evidence?(body, attachments) do
    evidence =
      body
      |> evidence_text(attachments)
      |> String.downcase()

    Regex.match?(~r/github\.com\/[^\s]+\/pull\/\d+|\bpull request\b|\bpr[-_\s]#?\d+\b/, evidence)
  end

  defp has_completion_evidence?(body, attachments) do
    evidence =
      body
      |> evidence_text(attachments)
      |> String.downcase()

    Regex.match?(~r/\bmerged?\b|merge evidence|completion evidence|\bcompleted\b|\bdone\b|合并|完成/, evidence)
  end

  defp has_recommended_option?(body) do
    lower_body = String.downcase(body)
    String.contains?(lower_body, "recommended") or String.contains?(body, "推荐")
  end

  defp evidence_text(body, attachments) do
    attachment_text =
      attachments
      |> Enum.map_join("\n", fn
        %ReviewAttachment{
          filename: filename,
          title: title,
          url: url,
          content_type: content_type,
          source_type: source_type
        } ->
          Enum.join([filename, title, url, content_type, source_type], "\n")

        other ->
          inspect(other)
      end)

    body <> "\n" <> attachment_text
  end

  defp add_reason_unless(reasons, true, _reason), do: reasons
  defp add_reason_unless(reasons, false, reason), do: reasons ++ [reason]

  defp build_decision(status, action, target_state, reasons) do
    %Decision{
      status: status,
      action: action,
      target_state: target_state,
      reasons: reasons,
      audit_comment_body: audit_comment_body(status, action, target_state, reasons)
    }
  end

  defp audit_comment_body(status, action, target_state, reasons) do
    [
      @audit_heading,
      "",
      "原始 handoff status: #{status || "missing"}",
      "决策: #{decision_label(action, target_state)}",
      "目标状态: #{target_state || "no-state-change"}",
      "",
      "判断理由:",
      reason_lines(reasons)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp decision_label(:change_state, "Merging"), do: "批准进入 Merging"
  defp decision_label(:change_state, "Done"), do: "确认完成并进入 Done"
  defp decision_label(:change_state, "In Progress"), do: "确认后继续 In Progress"
  defp decision_label(:change_state, "Rework"), do: "打回 Rework"
  defp decision_label(:no_state_change, _target_state), do: "不改变状态"

  defp reason_lines([]), do: ["- 无"]
  defp reason_lines(reasons), do: Enum.map(reasons, &("- " <> &1))
end
