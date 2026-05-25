defmodule SymphonyElixir.Maestro do
  @moduledoc """
  LLM-backed reviewer for Symphony review handoff comments.
  """

  alias SymphonyElixir.Maestro.{
    ClaudeJudge,
    Decision,
    GitHubPrContextProvider,
    JudgeRequest,
    PrContext,
    ReviewAttachment,
    ReviewComment,
    ReviewContext
  }

  @handoff_heading "## Review Handoff"
  @spec_heading "## Spec"
  @audit_heading "## Maestro Decision"
  @dry_run_audit_heading "## Maestro Decision【试运行 · 不修改状态】"

  @pr_review_status "Waiting for PR review"
  @completion_status "Waiting for completion confirmation"
  @requirement_status "Waiting for requirement confirmation"
  @plan_status "Waiting for plan confirmation"
  @blocked_status "Blocked"

  @supported_statuses [
    @pr_review_status,
    @completion_status,
    @requirement_status,
    @plan_status,
    @blocked_status
  ]

  @prompt_section_limit 24_000
  @prompt_total_limit 80_000

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
    Tracker attachment metadata that can point Maestro at PR evidence.
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

  defmodule PrContext do
    @moduledoc """
    GitHub PR evidence collected before the LLM judge evaluates a handoff.
    """

    defstruct url: nil, metadata: "", diff: "", error: nil

    @type t :: %__MODULE__{
            url: String.t() | nil,
            metadata: String.t(),
            diff: String.t(),
            error: String.t() | nil
          }
  end

  defmodule JudgeRequest do
    @moduledoc """
    Fully materialized request sent to the LLM judge.
    """

    defstruct status: nil,
              issue: nil,
              handoff_comment: nil,
              spec_comment: nil,
              comments: [],
              attachments: [],
              pr_contexts: [],
              prompt: ""

    @type t :: %__MODULE__{
            status: String.t(),
            issue: term(),
            handoff_comment: ReviewComment.t(),
            spec_comment: ReviewComment.t() | nil,
            comments: [ReviewComment.t()],
            attachments: [ReviewAttachment.t()],
            pr_contexts: [PrContext.t()],
            prompt: String.t()
          }
  end

  defmodule Decision do
    @moduledoc """
    Maestro's decision output for tracker integration to apply.
    """

    defstruct status: nil,
              action: :change_state,
              target_state: nil,
              reasons: [],
              llm_summary: "",
              dry_run: false,
              audit_comment_body: ""

    @type action :: :change_state | :no_state_change

    @type t :: %__MODULE__{
            status: String.t() | nil,
            action: action(),
            target_state: String.t() | nil,
            reasons: [String.t()],
            llm_summary: String.t(),
            dry_run: boolean(),
            audit_comment_body: String.t()
          }
  end

  @type handoff :: %{body: String.t(), status: String.t() | nil, comment: ReviewComment.t()}
  @type judge_response :: map()

  @spec run_once(keyword()) :: {:ok, [Decision.t()]} | {:error, term()}
  def run_once(opts \\ []) when is_list(opts) do
    tracker = Keyword.get(opts, :tracker, SymphonyElixir.Tracker)
    states = Keyword.get(opts, :states, ["Human Review"])

    with {:ok, contexts} <- tracker.fetch_review_contexts_by_states(states) do
      apply_decisions(contexts, tracker, opts, [])
    end
  end

  @spec decide(ReviewContext.t()) :: Decision.t()
  def decide(%ReviewContext{} = context), do: decide(context, [])

  @spec decide(ReviewContext.t(), keyword()) :: Decision.t()
  def decide(%ReviewContext{} = context, opts) when is_list(opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    case latest_handoff(context) do
      nil ->
        build_decision(nil, :change_state, "Rework", ["未找到 `## Review Handoff` comment"], dry_run: dry_run)

      %{status: nil} ->
        build_decision(nil, :change_state, "Rework", ["Review Handoff 缺少 `Status:` 行"], dry_run: dry_run)

      %{status: status} = handoff when status in @supported_statuses ->
        decide_with_judge(context, handoff, opts, dry_run)

      %{status: status} ->
        build_decision(status, :change_state, "Rework", ["不支持的 handoff status: #{status}"], dry_run: dry_run)
    end
  end

  defp apply_decisions([], _tracker, _opts, decisions), do: {:ok, Enum.reverse(decisions)}

  defp apply_decisions([context | rest], tracker, opts, decisions) do
    decision = decide(context, opts)

    case apply_decision(tracker, context, decision) do
      :ok -> apply_decisions(rest, tracker, opts, [decision | decisions])
      {:error, reason} -> {:error, {:maestro_decision_failed, context_issue_id(context), reason}}
    end
  end

  defp apply_decision(tracker, context, %Decision{} = decision) do
    with {:ok, issue_id} <- fetch_context_issue_id(context),
         :ok <- tracker.create_comment(issue_id, decision.audit_comment_body) do
      cond do
        decision.dry_run ->
          :ok

        decision.action == :change_state and is_binary(decision.target_state) ->
          tracker.update_issue_state(issue_id, decision.target_state)

        true ->
          :ok
      end
    end
  end

  defp decide_with_judge(context, handoff, opts, dry_run) do
    judge = Keyword.get(opts, :judge, Application.get_env(:symphony_elixir, :maestro_judge, ClaudeJudge))

    pr_context_provider =
      Keyword.get(
        opts,
        :pr_context_provider,
        Application.get_env(:symphony_elixir, :maestro_pr_context_provider, GitHubPrContextProvider)
      )

    pr_context_provider.fetch(context, handoff)
    |> case do
      {:ok, pr_contexts} ->
        request = build_judge_request(context, handoff, pr_contexts)

        case judge.decide(request) do
          {:ok, response} -> decision_from_judge_response(handoff.status, response, dry_run)
          {:error, reason} -> judge_error_decision(handoff.status, reason, dry_run)
        end

      {:error, reason} ->
        judge_error_decision(handoff.status, {:pr_context_failed, reason}, dry_run)
    end
  end

  defp decision_from_judge_response(status, response, dry_run) when is_map(response) do
    summary = response |> response_value("summary") |> normalize_summary()
    reasons = response |> response_value("reasons") |> normalize_reasons()
    target_state = response |> response_value("target_state") |> normalize_target_state()

    cond do
      not is_list(reasons) ->
        build_decision(status, :change_state, fail_closed_target(status), ["LLM 输出缺少 reasons 列表"],
          dry_run: dry_run,
          llm_summary: summary
        )

      allowed_target?(status, target_state) ->
        action = if is_nil(target_state), do: :no_state_change, else: :change_state
        build_decision(status, action, target_state, reasons, dry_run: dry_run, llm_summary: summary)

      true ->
        reason = "LLM 输出的目标状态 `#{inspect_target(target_state)}` 不允许用于 `#{status}`"

        build_decision(status, :change_state, fail_closed_target(status), [reason],
          dry_run: dry_run,
          llm_summary: summary
        )
    end
  end

  defp decision_from_judge_response(status, _response, dry_run) do
    build_decision(status, :change_state, fail_closed_target(status), ["LLM 输出不是 JSON object"], dry_run: dry_run)
  end

  defp judge_error_decision(status, reason, dry_run) do
    build_decision(
      status,
      fail_closed_action(status),
      fail_closed_target(status),
      [
        "LLM 裁决失败: #{inspect(reason)}"
      ],
      dry_run: dry_run
    )
  end

  defp build_judge_request(context, handoff, pr_contexts) do
    spec_comment = latest_comment_with_heading(context.comments, @spec_heading)

    request = %JudgeRequest{
      status: handoff.status,
      issue: context.issue,
      handoff_comment: handoff.comment,
      spec_comment: spec_comment,
      comments: context.comments,
      attachments: context.attachments,
      pr_contexts: pr_contexts
    }

    %{request | prompt: build_prompt(request)}
  end

  defp build_prompt(%JudgeRequest{} = request) do
    [
      """
      You are Maestro, the AI reviewer for Symphony Review Handoff decisions.

      Decide whether the latest handoff is acceptable. Use the issue description, Spec,
      handoff, Linear comments, PR metadata, PR diff, tests, and CI/check evidence.
      This is a quality judgment, not a Markdown format check.

      Return JSON only:
      {
        "target_state": "Merging | Rework | Done | In Progress | null",
        "summary": "one concise Chinese audit summary",
        "reasons": ["specific Chinese reason; empty array only when fully approved"]
      }

      Allowed target states:
      - Waiting for PR review -> Merging or Rework
      - Waiting for completion confirmation -> Done or Rework
      - Waiting for requirement confirmation -> In Progress or Rework
      - Waiting for plan confirmation -> In Progress or Rework
      - Blocked -> null or Rework

      Fail closed to Rework when evidence is missing, tests are superficial, PR diff
      does not match the handoff, checks are failing/unknown in a risky way, or you
      cannot confidently approve.
      """,
      section("Matched handoff status", request.status),
      section("Issue", inspect_issue(request.issue)),
      section("Spec comment", comment_body(request.spec_comment) || "未找到 ## Spec comment"),
      section("Latest Review Handoff", comment_body(request.handoff_comment)),
      section("Recent Linear comments", comments_text(request.comments)),
      section("Attachments", attachments_text(request.attachments)),
      section("GitHub PR context", pr_contexts_text(request.pr_contexts))
    ]
    |> Enum.join("\n\n")
    |> truncate(@prompt_total_limit)
  end

  defp section(title, body) do
    """
    ## #{title}
    #{truncate(to_string(body || ""), @prompt_section_limit)}
    """
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
    |> latest_comment()
    |> case do
      %ReviewComment{body: body} = comment -> %{body: body, status: extract_status(body), comment: comment}
      nil -> nil
    end
  end

  defp latest_comment_with_heading(comments, heading) do
    comments
    |> Enum.with_index()
    |> Enum.filter(fn {%ReviewComment{body: body}, _index} -> body_starts_with?(body, heading) end)
    |> latest_comment()
  end

  defp latest_comment(comment_entries) do
    comment_entries
    |> Enum.max_by(
      fn {%ReviewComment{created_at: created_at}, index} ->
        {timestamp_sort_key(created_at), index}
      end,
      fn -> nil end
    )
    |> case do
      {%ReviewComment{} = comment, _index} -> comment
      nil -> nil
    end
  end

  defp handoff_body?(body), do: body_starts_with?(body, @handoff_heading)

  defp body_starts_with?(body, heading) when is_binary(body) do
    body
    |> String.trim_leading()
    |> String.starts_with?(heading)
  end

  defp body_starts_with?(_body, _heading), do: false

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

  defp allowed_target?(@pr_review_status, target), do: target in ["Merging", "Rework"]
  defp allowed_target?(@completion_status, target), do: target in ["Done", "Rework"]
  defp allowed_target?(@requirement_status, target), do: target in ["In Progress", "Rework"]
  defp allowed_target?(@plan_status, target), do: target in ["In Progress", "Rework"]
  defp allowed_target?(@blocked_status, target), do: is_nil(target) or target == "Rework"

  defp fail_closed_target(@blocked_status), do: nil
  defp fail_closed_target(_status), do: "Rework"

  defp fail_closed_action(@blocked_status), do: :no_state_change
  defp fail_closed_action(_status), do: :change_state

  defp response_value(response, key) do
    Map.get(response, key) || Map.get(response, String.to_atom(key))
  end

  defp normalize_summary(summary) when is_binary(summary), do: String.trim(summary)
  defp normalize_summary(_summary), do: ""

  defp normalize_reasons(reasons) when is_list(reasons) do
    reasons
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_reasons(_reasons), do: :invalid

  defp normalize_target_state(nil), do: nil

  defp normalize_target_state(target_state) when is_binary(target_state) do
    case String.trim(target_state) do
      "" -> nil
      "null" -> nil
      normalized -> normalized
    end
  end

  defp normalize_target_state(_target_state), do: :invalid

  defp inspect_target(nil), do: "null"
  defp inspect_target(target), do: to_string(target)

  defp build_decision(status, action, target_state, reasons, opts) do
    llm_summary = Keyword.get(opts, :llm_summary, "")
    dry_run = Keyword.get(opts, :dry_run, false)

    %Decision{
      status: status,
      action: action,
      target_state: target_state,
      reasons: reasons,
      llm_summary: llm_summary,
      dry_run: dry_run,
      audit_comment_body: audit_comment_body(status, action, target_state, reasons, llm_summary, dry_run)
    }
  end

  defp audit_comment_body(status, action, target_state, reasons, llm_summary, dry_run) do
    [
      if(dry_run, do: @dry_run_audit_heading, else: @audit_heading),
      "",
      "原始 handoff status: #{status || "missing"}",
      "决策: #{decision_label(action, target_state)}",
      target_state_line(target_state, dry_run),
      "dry_run: #{dry_run}",
      "LLM 裁决摘要: #{summary_line(llm_summary)}",
      "",
      "判断理由:",
      reason_lines(reasons)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp target_state_line(target_state, true) do
    "目标状态: #{target_state || "no-state-change"}（试运行模式下不执行）"
  end

  defp target_state_line(target_state, false), do: "目标状态: #{target_state || "no-state-change"}"

  defp decision_label(:change_state, "Merging"), do: "批准进入 Merging"
  defp decision_label(:change_state, "Done"), do: "确认完成并进入 Done"
  defp decision_label(:change_state, "In Progress"), do: "确认后继续 In Progress"
  defp decision_label(:change_state, "Rework"), do: "打回 Rework"
  defp decision_label(:no_state_change, _target_state), do: "不改变状态"

  defp reason_lines([]), do: ["- 无"]
  defp reason_lines(reasons), do: Enum.map(reasons, &("- " <> &1))

  defp summary_line(""), do: "无"
  defp summary_line(summary), do: summary

  defp inspect_issue(%{identifier: identifier, title: title, description: description, state: state}) do
    """
    identifier: #{identifier}
    title: #{title}
    state: #{state}
    description:
    #{description}
    """
  end

  defp inspect_issue(%{} = issue) do
    issue
    |> Map.take([:id, :identifier, :title, :description, :state, "id", "identifier", "title", "description", "state"])
    |> inspect(pretty: true)
  end

  defp inspect_issue(issue), do: inspect(issue, pretty: true)

  defp comment_body(%ReviewComment{body: body}) when is_binary(body), do: body
  defp comment_body(_comment), do: nil

  defp comments_text(comments) do
    comments
    |> Enum.map_join("\n\n---\n\n", fn
      %ReviewComment{id: id, created_at: created_at, body: body} ->
        """
        comment_id: #{id || "unknown"}
        created_at: #{format_timestamp(created_at)}
        #{body}
        """
    end)
  end

  defp attachments_text(attachments) do
    attachments
    |> Enum.map_join("\n", fn
      %ReviewAttachment{} = attachment ->
        [
          "id=#{attachment.id}",
          "title=#{attachment.title}",
          "filename=#{attachment.filename}",
          "url=#{attachment.url}",
          "source_type=#{attachment.source_type}",
          "content_type=#{attachment.content_type}"
        ]
        |> Enum.join(" ")
    end)
  end

  defp pr_contexts_text([]), do: "无 GitHub PR context"

  defp pr_contexts_text(pr_contexts) do
    pr_contexts
    |> Enum.map_join("\n\n---\n\n", fn
      %PrContext{} = context ->
        """
        PR URL: #{context.url || "unknown"}
        Error: #{context.error || "none"}

        Metadata:
        #{context.metadata}

        Diff:
        #{context.diff}
        """
    end)
  end

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp format_timestamp(_timestamp), do: "unknown"

  defp truncate(text, limit) when is_binary(text) and byte_size(text) > limit do
    text
    |> String.slice(0, limit)
    |> Kernel.<>("\n...[truncated]")
  end

  defp truncate(text, _limit), do: text
end
