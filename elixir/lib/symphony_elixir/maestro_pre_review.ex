defmodule SymphonyElixir.MaestroPreReview do
  @moduledoc """
  Runs an isolated Maestro pre-review after a Symphony issue reaches Human Review.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Linear.Issue, SSH, Tracker, Workspace}

  @workspace_suffix "-maestro"

  @spec run(Issue.t(), keyword()) :: :ok | {:error, term()}
  def run(%Issue{} = issue, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    workspace_issue = %{issue | identifier: workspace_identifier(issue)}

    Logger.info("Maestro pre-review started for #{issue_context(issue)} worker_host=#{worker_host || "local"}")

    result =
      case Workspace.create_for_issue(workspace_issue, worker_host) do
        {:ok, workspace} ->
          try do
            with :ok <- prepare_main_branch(workspace, worker_host),
                 {:ok, _turn} <-
                   AppServer.run(workspace, build_prompt(issue), issue,
                     worker_host: worker_host,
                     on_message: on_message
                   ) do
              :ok
            end
          after
            Workspace.remove(workspace, worker_host, workspace_issue)
          end

        {:error, reason} ->
          {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        record_no_action_reason(issue, reason)
        error
    end
  end

  @doc false
  @spec build_prompt_for_test(Issue.t()) :: String.t()
  def build_prompt_for_test(%Issue{} = issue), do: build_prompt(issue)

  @doc false
  @spec workspace_identifier_for_test(Issue.t()) :: String.t()
  def workspace_identifier_for_test(%Issue{} = issue), do: workspace_identifier(issue)

  @doc false
  @spec prepare_main_branch_command_for_test() :: String.t()
  def prepare_main_branch_command_for_test, do: prepare_main_branch_command()

  defp prepare_main_branch(workspace, nil) do
    case System.cmd("sh", ["-lc", prepare_main_branch_command()],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:maestro_main_branch_prepare_failed, status, output}}
    end
  end

  defp prepare_main_branch(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "cd #{shell_escape(workspace)}",
        prepare_main_branch_command()
      ]
      |> Enum.join("\n")

    case SSH.run(worker_host, script, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:maestro_main_branch_prepare_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_main_branch_command do
    """
    set -e
    base_branch="${SYMPHONY_BASE_BRANCH:-main}"
    git rev-parse --is-inside-work-tree >/dev/null
    if git remote get-url upstream >/dev/null 2>&1; then
      git fetch upstream "$base_branch" --prune
      git checkout -B "$base_branch" "upstream/$base_branch"
    else
      git checkout "$base_branch"
      git pull --ff-only origin "$base_branch"
    fi
    """
  end

  defp build_prompt(%Issue{} = issue) do
    identifier = issue.identifier || issue.id || "unknown"

    """
    You are the isolated Maestro pre-review session for #{identifier}.

    This is a fresh Codex session launched after the working agent handed the issue to `Human Review`.
    Do not reuse the working agent, do not rely on any prior conversation, and do not edit repository files.

    First invoke `$maestro #{identifier}` to obtain the read-only Maestro recommendation.
    Then act on that recommendation using Linear tools under these DEV-5316 rules:

    1. Before mutating anything, re-read the issue. If it is no longer in `Human Review`, stop without commenting or changing state.
    2. Identify the current awaiting-review phase artifact. If that artifact thread already contains a Maestro pre-review reply for the same current artifact/head, stop without adding another reply.
    3. If Maestro recommends `request changes`, `request changes / rework`, or equivalent rework, reply in the awaiting artifact thread with the Maestro review and move the issue to `Rework`. Do not write any phase-closing approval reply.
    4. If Maestro recommends `approve`, reply in the awaiting artifact thread with the Maestro review plus a confidence score in `0-10` format and a short text description. Keep the issue in `Human Review`. Do not move it to `In Progress`, `Merging`, `Done`, or any other state.
    5. If Maestro recommends clarification, no reply yet, merge nudge, completion confirmation, or if the pre-review evidence is unavailable, record a short no-action reason in the awaiting artifact thread when safe, keep the issue in `Human Review`, and do not advance or rework.

    The reply must start with `🤖 Maestro 预审核:` so future sessions can detect that this handoff was already reviewed.
    """
  end

  defp workspace_identifier(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "" do
    identifier <> @workspace_suffix
  end

  defp workspace_identifier(%Issue{id: id}) when is_binary(id) and id != "" do
    id <> @workspace_suffix
  end

  defp workspace_identifier(_issue), do: "issue" <> @workspace_suffix

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{identifier || "n/a"}"
  end

  defp record_no_action_reason(%Issue{id: issue_id} = issue, reason)
       when is_binary(issue_id) and issue_id != "" do
    body = """
    🤖 Maestro 预审核: 未自动执行

    预审核会话未能启动或完成：#{safe_failure_reason(reason)}。
    Issue 保持 `Human Review`，未写入 approve/rework 结论。
    """

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, comment_reason} ->
        Logger.warning("Maestro pre-review failure comment failed for #{issue_context(issue)}: #{inspect(comment_reason)}")
        :ok
    end
  end

  defp record_no_action_reason(issue, reason) do
    Logger.warning("Maestro pre-review could not record no-action reason for #{issue_context(issue)}: #{inspect(reason)}")
    :ok
  end

  defp safe_failure_reason({:maestro_main_branch_prepare_failed, status, _output}) do
    "main 分支准备失败（exit #{status}）"
  end

  defp safe_failure_reason({:workspace_prepare_failed, _worker_host, status, _output}) do
    "workspace 准备失败（exit #{status}）"
  end

  defp safe_failure_reason({:invalid_workspace_cwd, reason, _path}) do
    "workspace 路径不可用（#{reason}）"
  end

  defp safe_failure_reason({:invalid_workspace_cwd, reason, _path, _root}) do
    "workspace 路径不可用（#{reason}）"
  end

  defp safe_failure_reason(reason) when is_atom(reason), do: "`#{reason}`"
  defp safe_failure_reason(_reason), do: "预审核会话启动失败"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
