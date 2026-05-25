defmodule SymphonyElixir.Maestro.ClaudeJudge do
  @moduledoc """
  Default Maestro judge that asks Claude for a constrained JSON decision.
  """

  alias SymphonyElixir.Maestro.{CliRunner, JudgeRequest}

  @default_timeout_ms 120_000

  @schema %{
    type: "object",
    additionalProperties: false,
    required: ["target_state", "summary", "reasons"],
    properties: %{
      target_state: %{
        anyOf: [
          %{type: "string", enum: ["Merging", "Rework", "Done", "In Progress"]},
          %{type: "null"}
        ]
      },
      summary: %{type: "string"},
      reasons: %{type: "array", items: %{type: "string"}}
    }
  }

  @spec decide(JudgeRequest.t()) :: {:ok, map()} | {:error, term()}
  def decide(%JudgeRequest{prompt: prompt}) when is_binary(prompt) do
    command = Application.get_env(:symphony_elixir, :maestro_claude_command, "claude")
    timeout_ms = Application.get_env(:symphony_elixir, :maestro_claude_timeout_ms, @default_timeout_ms)

    args = [
      "--print",
      "--output-format",
      "json",
      "--tools",
      "",
      "--json-schema",
      Jason.encode!(@schema),
      prompt
    ]

    case CliRunner.run(command, args, timeout_ms: timeout_ms) do
      {:ok, output} -> parse_response(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_response(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_response(output) when is_binary(output) do
    output
    |> String.trim()
    |> decode_json_response()
  end

  defp decode_json_response(""), do: {:error, :empty_claude_response}

  defp decode_json_response(output) do
    case Jason.decode(output) do
      {:ok, %{"target_state" => _target_state} = decision} ->
        {:ok, decision}

      {:ok, %{"result" => result}} when is_binary(result) ->
        parse_embedded_json(result)

      {:ok, %{"message" => %{"content" => content}}} when is_list(content) ->
        content
        |> Enum.find_value(&text_content/1)
        |> case do
          nil -> {:error, :missing_claude_text_content}
          text -> parse_embedded_json(text)
        end

      {:ok, other} ->
        {:error, {:unexpected_claude_response, other}}

      {:error, reason} ->
        parse_embedded_json_or_error(output, reason)
    end
  end

  defp parse_embedded_json_or_error(output, original_reason) do
    case parse_embedded_json(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:invalid_json, original_reason}}
    end
  end

  defp parse_embedded_json(text) when is_binary(text) do
    text
    |> extract_json_object()
    |> case do
      nil -> {:error, :missing_json_object}
      json -> Jason.decode(json)
    end
  end

  defp extract_json_object(text) do
    start = :binary.match(text, "{")
    stop = :binary.matches(text, "}") |> List.last()

    case {start, stop} do
      {{start_index, _}, {stop_index, _}} when stop_index >= start_index ->
        binary_part(text, start_index, stop_index - start_index + 1)

      _ ->
        nil
    end
  end

  defp text_content(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp text_content(%{"text" => text}) when is_binary(text), do: text
  defp text_content(_content), do: nil
end
