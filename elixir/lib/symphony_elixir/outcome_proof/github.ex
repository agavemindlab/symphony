defmodule SymphonyElixir.OutcomeProof.GitHub do
  @moduledoc false

  @spec pull_request(String.t()) :: {:ok, map()} | {:error, term()}
  def pull_request(url) when is_binary(url) do
    with {:ok, owner, repo, number} <- parse_pull_url(url),
         {:ok, token} <- token(),
         {:ok, pull_request} <- get("https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}", token),
         head_sha when is_binary(head_sha) <- get_in(pull_request, ["head", "sha"]),
         {:ok, reviews} <- get("https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/reviews", token),
         {:ok, comments} <- get("https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/comments", token),
         {:ok, checks} <- get("https://api.github.com/repos/#{owner}/#{repo}/commits/#{head_sha}/check-runs", token) do
      {:ok,
       %{
         head_sha: head_sha,
         reviews: Enum.map(List.wrap(reviews), &review/1),
         comments: Enum.map(List.wrap(comments), &comment/1),
         checks: Enum.map(Map.get(checks, "check_runs", []), &check/1)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_pull_request_payload}
    end
  end

  defp parse_pull_url(url) do
    case Regex.run(~r/github\.com\/([^\/]+)\/([^\/]+)\/pull\/(\d+)/, url) do
      [_match, owner, repo, number] -> {:ok, owner, repo, number}
      _ -> {:error, :invalid_github_pull_request_url}
    end
  end

  defp token do
    case System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_github_token}
    end
  end

  defp get(url, token) do
    case Req.get(url,
           headers: [
             {"authorization", "Bearer #{token}"},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ],
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_status, status}}
      {:error, reason} -> {:error, {:github_request, reason}}
    end
  end

  defp review(review) when is_map(review), do: %{author: author(review["user"]), state: review["state"]}
  defp comment(comment) when is_map(comment), do: %{author: author(comment["user"])}
  defp check(check) when is_map(check), do: %{sha: check["head_sha"], conclusion: check["conclusion"] || check["status"]}

  defp author(%{"login" => login, "type" => type}), do: %{login: login, type: type}
  defp author(_author), do: %{login: "", type: ""}
end
