defmodule SymphonyElixir.Maestro.GitHubPrContextProvider do
  @moduledoc """
  Collects GitHub PR metadata and diff context for Maestro's LLM judge.
  """

  alias SymphonyElixir.Maestro.{CliRunner, PrContext, ReviewAttachment, ReviewContext}

  @github_pr_url ~r/https:\/\/github\.com\/[^\s\)>\]]+\/pull\/\d+/i
  @diff_limit 50_000
  @metadata_limit 16_000

  @spec fetch(ReviewContext.t(), map()) :: {:ok, [PrContext.t()]} | {:error, term()}
  def fetch(%ReviewContext{} = context, handoff) when is_map(handoff) do
    urls =
      context
      |> pr_urls_from_context(handoff)
      |> Enum.uniq()

    {:ok, Enum.map(urls, &fetch_pr_context/1)}
  end

  defp pr_urls_from_context(%ReviewContext{attachments: attachments}, %{body: body}) do
    (urls_from_text(body) ++ urls_from_attachments(attachments))
    |> Enum.reject(&is_nil/1)
  end

  defp urls_from_attachments(attachments) do
    Enum.flat_map(attachments, fn
      %ReviewAttachment{url: url, title: title, filename: filename} ->
        urls_from_text(Enum.join([url, title, filename], "\n"))

      other ->
        urls_from_text(inspect(other))
    end)
  end

  defp urls_from_text(text) when is_binary(text) do
    @github_pr_url
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&Regex.replace(~r/[\.,;]+$/, &1, ""))
  end

  defp urls_from_text(_text), do: []

  defp fetch_pr_context(url) do
    metadata_result =
      CliRunner.run("gh", [
        "pr",
        "view",
        url,
        "--json",
        "number,title,url,state,mergeStateStatus,reviewDecision,statusCheckRollup,files,comments,reviews"
      ])

    diff_result = CliRunner.run("gh", ["pr", "diff", url, "--color", "never"])

    %PrContext{
      url: url,
      metadata: metadata_text(metadata_result),
      diff: diff_text(diff_result),
      error: error_text([metadata_result, diff_result])
    }
  end

  defp metadata_text({:ok, output}) do
    output
    |> normalize_json_output()
    |> truncate(@metadata_limit)
  end

  defp metadata_text({:error, reason}), do: "GitHub PR metadata unavailable: #{inspect(reason)}"

  defp diff_text({:ok, output}), do: truncate(output, @diff_limit)
  defp diff_text({:error, reason}), do: "GitHub PR diff unavailable: #{inspect(reason)}"

  defp error_text(results) do
    errors =
      results
      |> Enum.flat_map(fn
        {:ok, _output} -> []
        {:error, reason} -> [inspect(reason)]
      end)

    case errors do
      [] -> nil
      _ -> Enum.join(errors, "; ")
    end
  end

  defp normalize_json_output(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      {:error, _reason} -> output
    end
  end

  defp truncate(text, limit) when is_binary(text) and byte_size(text) > limit do
    text
    |> String.slice(0, limit)
    |> Kernel.<>("\n...[truncated]")
  end

  defp truncate(text, _limit), do: text
end
