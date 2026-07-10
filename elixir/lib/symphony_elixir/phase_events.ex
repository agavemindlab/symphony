defmodule SymphonyElixir.PhaseEvents do
  @moduledoc """
  Pure derivation of analytics events from Phase Artifact Protocol comments.

  A phase artifact is a top-level issue comment whose body starts with one of
  the phase headings (`## Requirements`, `## Design`, `## Implementation`,
  `## Deployment`). Closing replies, rework/rollback markers, and Maestro
  pre-review replies live in the artifact's thread. `derive/1` turns a list of
  normalized comments into event maps ready to merge into
  `SymphonyElixir.Analytics.record_event/2` payloads. No side effects.
  """

  @artifact_heading_regex ~r/\A\s*##\s+(Requirements|Design|Implementation|Deployment)\b/u
  @rollback_target_regex ~r/回到[\s\[（(`「]*(Requirements|Design|Implementation|Deployment)/u
  @confidence_ratio_regex ~r/(?<![\d.])(10|\d(?:\.\d+)?)\s*\/\s*10/u
  @confidence_label_regex ~r/置信度\s*[:：]?\s*(\d+(?:\.\d+)?)/u
  @marker_decoration_regex ~r/\A[\s>#*_`~-]+/u
  @needs_clarification_regex ~r/(?:\A|\n)\s*###\s+NEEDS CLARIFICATION\b|\[NEEDS CLARIFICATION/iu

  @recommendation_markers [
    {"request changes", "request_changes"},
    {"clarification", "ask_clarification"},
    {"merge nudge", "merge_nudge"},
    {"completion confirmation", "completion_confirmation"},
    {"no reply yet", "no_reply_yet"},
    {"approve", "approve"}
  ]

  @type comment :: %{
          id: String.t(),
          body: String.t(),
          created_at: DateTime.t() | String.t() | nil,
          parent_id: String.t() | nil,
          author_name: String.t() | nil,
          author_is_bot: boolean(),
          resolved_at: DateTime.t() | String.t() | nil
        }
  @type event :: map()

  @spec derive([comment()]) :: [event()]
  def derive(comments) when is_list(comments) do
    derive_sorted(comments, &comment_events/2)
  end

  @doc """
  `derive/1` plus a `human_comment` event for every comment authored by a
  human (`author_is_bot == false`), including thread replies. Kept separate
  from `derive/1`, whose phase-events-only contract other consumers
  (routing brief, agreement stats) rely on.
  """
  @spec derive_all([comment()]) :: [event()]
  def derive_all(comments) when is_list(comments) do
    derive_sorted(comments, fn comment, artifact_phases ->
      comment_events(comment, artifact_phases) ++ human_comment_events(comment)
    end)
  end

  defp derive_sorted(comments, events_fun) do
    sorted = Enum.sort_by(comments, &comment_sort_key/1)
    artifact_phases = artifact_phases(sorted)
    Enum.flat_map(sorted, &events_fun.(&1, artifact_phases))
  end

  @spec phase_of_artifact(String.t() | nil) :: String.t() | nil
  def phase_of_artifact(body) when is_binary(body) do
    case Regex.run(@artifact_heading_regex, body, capture: :all_but_first) do
      [phase] -> phase
      nil -> nil
    end
  end

  def phase_of_artifact(_body), do: nil

  @spec needs_clarification?(String.t() | nil) :: boolean()
  def needs_clarification?(body) when is_binary(body) do
    Regex.match?(@needs_clarification_regex, body)
  end

  def needs_clarification?(_body), do: false

  @doc false
  @spec reply_marker(String.t() | nil) ::
          :maestro_review | :approved | :auto_advanced | :reworked | :rollback | nil
  def reply_marker(body) when is_binary(body) do
    marker_body = String.replace(body, @marker_decoration_regex, "")

    cond do
      String.starts_with?(marker_body, "🤖 Maestro 预审核") -> :maestro_review
      String.starts_with?(marker_body, "✅ 已批准") -> :approved
      String.starts_with?(marker_body, "⏩ 自动进入") -> :auto_advanced
      String.starts_with?(marker_body, "🔧 本轮修改") -> :reworked
      String.starts_with?(marker_body, "🔄 反馈要求回到") -> :rollback
      true -> nil
    end
  end

  def reply_marker(_body), do: nil

  defp comment_sort_key(%{created_at: %DateTime{} = created_at}),
    do: DateTime.to_unix(created_at, :microsecond)

  defp comment_sort_key(%{created_at: created_at}) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, parsed, _offset} -> DateTime.to_unix(parsed, :microsecond)
      _error -> 0
    end
  end

  defp comment_sort_key(_comment), do: 0

  defp occurred_at(%DateTime{} = created_at), do: DateTime.to_iso8601(created_at)
  defp occurred_at(created_at) when is_binary(created_at), do: created_at
  defp occurred_at(_created_at), do: nil

  defp artifact_phases(comments) do
    for %{id: id, parent_id: nil, body: body} <- comments,
        phase = phase_of_artifact(body),
        into: %{},
        do: {id, phase}
  end

  defp comment_events(%{parent_id: nil} = comment, _artifact_phases) do
    case phase_of_artifact(comment.body) do
      nil -> []
      phase -> [published_event(comment, phase)]
    end
  end

  defp comment_events(%{parent_id: parent_id} = comment, artifact_phases) do
    case Map.fetch(artifact_phases, parent_id) do
      {:ok, phase} -> reply_events(comment, phase)
      :error -> []
    end
  end

  defp reply_events(comment, phase) do
    case reply_marker(comment.body) do
      :maestro_review -> [maestro_review_event(comment, phase)]
      :approved -> [closing_event(comment, phase, "phase_approved")]
      :auto_advanced -> [closing_event(comment, phase, "phase_auto_advanced")]
      :reworked -> [rework_event(comment, phase)]
      :rollback -> [rollback_event(comment, phase)]
      nil -> []
    end
  end

  defp human_comment_events(%{author_is_bot: false} = comment) do
    [
      %{
        event_type: "human_comment",
        event_id: "human-comment-" <> comment.id,
        occurred_at: occurred_at(comment.created_at),
        author_name: comment.author_name
      }
    ]
  end

  defp human_comment_events(_comment), do: []

  defp published_event(comment, phase) do
    %{
      event_type: "phase_published",
      event_id: "phase_published:" <> comment.id,
      phase: phase,
      comment_id: comment.id,
      occurred_at: occurred_at(comment.created_at),
      needs_clarification: needs_clarification?(comment.body),
      author_name: comment.author_name
    }
  end

  defp closing_event(comment, phase, event_type) do
    %{
      event_type: event_type,
      event_id: event_type <> ":" <> comment.id,
      phase: phase,
      artifact_comment_id: comment.parent_id,
      comment_id: comment.id,
      occurred_at: occurred_at(comment.created_at),
      author_name: comment.author_name
    }
  end

  defp rework_event(comment, phase) do
    %{
      event_type: "phase_reworked",
      event_id: "phase_reworked:" <> comment.id,
      phase: phase,
      artifact_comment_id: comment.parent_id,
      comment_id: comment.id,
      occurred_at: occurred_at(comment.created_at)
    }
  end

  defp rollback_event(comment, from_phase) do
    %{
      event_type: "phase_rollback",
      event_id: "phase_rollback:" <> comment.id,
      from_phase: from_phase,
      target_phase: rollback_target(comment.body),
      comment_id: comment.id,
      occurred_at: occurred_at(comment.created_at)
    }
  end

  defp rollback_target(body) do
    case Regex.run(@rollback_target_regex, body, capture: :all_but_first) do
      [phase] -> phase
      nil -> nil
    end
  end

  defp maestro_review_event(comment, phase) do
    %{
      event_type: "maestro_review",
      event_id: "maestro_review:" <> comment.id,
      phase: phase,
      artifact_comment_id: comment.parent_id,
      recommendation: maestro_recommendation(comment.body),
      confidence: maestro_confidence(comment.body),
      auto: String.contains?(comment.body, "🤖 auto"),
      comment_id: comment.id,
      occurred_at: occurred_at(comment.created_at)
    }
  end

  defp maestro_recommendation(body) do
    body
    |> String.split("\n")
    |> Enum.find_value("unknown", &recommendation_from_line/1)
  end

  defp recommendation_from_line(line) do
    if String.contains?(line, "建议回复方式") do
      line |> String.downcase() |> String.replace(~r/[_\/-]/u, " ") |> match_recommendation()
    end
  end

  defp match_recommendation(normalized) do
    Enum.find_value(@recommendation_markers, "unknown", fn {marker, recommendation} ->
      if String.contains?(normalized, marker), do: recommendation
    end)
  end

  defp maestro_confidence(body) do
    case Regex.run(@confidence_ratio_regex, body, capture: :all_but_first) do
      [value] -> parse_confidence(value)
      nil -> labeled_confidence(body)
    end
  end

  defp labeled_confidence(body) do
    case Regex.run(@confidence_label_regex, body, capture: :all_but_first) do
      [value] -> parse_confidence(value)
      nil -> nil
    end
  end

  defp parse_confidence(value) do
    {confidence, _rest} = Float.parse(value)
    confidence
  end
end
