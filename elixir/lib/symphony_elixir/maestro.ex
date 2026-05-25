defmodule SymphonyElixir.Maestro do
  @moduledoc """
  Launches Maestro agent sessions for Symphony review handoff decisions.

  Maestro's judgment lives in the agent workflow/skill. This module only finds
  Human Review issues and starts a one-turn Codex app-server session through
  the existing agent runner.
  """

  alias SymphonyElixir.{AgentRunner, Tracker}
  alias SymphonyElixir.Linear.Issue

  @default_states ["Human Review"]

  defmodule ReviewComment do
    @moduledoc """
    Tracker comment metadata exposed to Maestro-capable tracker adapters.
    """

    defstruct id: nil, body: "", created_at: nil, updated_at: nil

    @type t :: %__MODULE__{
            id: String.t() | nil,
            body: String.t() | nil,
            created_at: String.t() | DateTime.t() | NaiveDateTime.t() | nil,
            updated_at: String.t() | DateTime.t() | NaiveDateTime.t() | nil
          }
  end

  defmodule ReviewAttachment do
    @moduledoc """
    Tracker attachment metadata exposed to Maestro-capable tracker adapters.
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

  defmodule ReviewContext do
    @moduledoc """
    Review inputs gathered from the tracker before a Maestro agent session starts.
    """

    defstruct issue: nil, issue_id: nil, comments: [], attachments: []

    @type t :: %__MODULE__{
            issue: Issue.t() | map() | nil,
            issue_id: String.t() | nil,
            comments: [ReviewComment.t()],
            attachments: [ReviewAttachment.t()]
          }
  end

  defmodule AgentRun do
    @moduledoc """
    Metadata returned after Symphony launches a Maestro agent session.
    """

    defstruct issue_id: nil, identifier: nil, dry_run: false

    @type t :: %__MODULE__{
            issue_id: String.t(),
            identifier: String.t() | nil,
            dry_run: boolean()
          }
  end

  @type agent_runner ::
          (Issue.t() | map(), pid() | nil, keyword() -> :ok | {:error, term()})

  @spec run_once(keyword()) :: {:ok, [AgentRun.t()]} | {:error, term()}
  def run_once(opts \\ []) when is_list(opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    states = Keyword.get(opts, :states, @default_states)

    with {:ok, contexts} <- tracker.fetch_review_contexts_by_states(states) do
      launch_agent_sessions(contexts, opts, [])
    end
  end

  @spec prompt_template(keyword()) :: String.t()
  def prompt_template(opts \\ []) when is_list(opts) do
    dry_run = Keyword.get(opts, :dry_run, false)

    """
    You are Maestro, the AI decision agent for Symphony Human Review handoffs.

    Runtime options:
    - dry_run: #{dry_run}

    Use the Maestro skill at `.agents/skills/maestro/SKILL.md` as the source of
    truth for this session. Follow it even though the issue is currently in
    Human Review; this session exists specifically to replace the human review
    decision.

    Required routes to evaluate from the latest `## Review Handoff`:
    - Status: Waiting for PR review
    - Status: Waiting for completion confirmation
    - Status: Waiting for requirement confirmation
    - Status: Waiting for plan confirmation
    - Status: Blocked

    Required evidence commands for PR handoffs include `gh pr view`,
    `gh pr diff`, and available PR checks/reviews/comments.

    Always write `## Maestro Decision` before a normal-mode state update. In
    dry_run mode, write `## Maestro Decision【试运行 · 不修改状态】`, record the
    state you would choose, and do not update Linear state.

    Allowed target states by route:
    - Waiting for PR review -> Merging or Rework
    - Waiting for completion confirmation -> Done or Rework
    - Waiting for requirement confirmation -> In Progress or Rework
    - Waiting for plan confirmation -> In Progress or Rework
    - Blocked -> In Progress or Rework, or keep blocked when human/system action is still required

    Issue context:
    Identifier: {{ issue.identifier }}
    Title: {{ issue.title }}
    Current status: {{ issue.state }}
    Labels: {{ issue.labels }}
    URL: {{ issue.url }}

    Description:
    {% if issue.description %}
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}
    """
  end

  defp launch_agent_sessions([], _opts, runs), do: {:ok, Enum.reverse(runs)}

  defp launch_agent_sessions([context | rest], opts, runs) do
    case launch_agent_session(context, opts) do
      {:ok, run} ->
        launch_agent_sessions(rest, opts, [run | runs])

      {:error, reason} ->
        {:error, {:maestro_agent_launch_failed, context_issue_id(context), reason}}
    end
  end

  defp launch_agent_session(context, opts) do
    dry_run = Keyword.get(opts, :dry_run, false)
    runner = Keyword.get(opts, :agent_runner, &AgentRunner.run/3)

    with {:ok, issue} <- context_issue(context),
         {:ok, issue_id} <- issue_id(issue, context) do
      runner_opts =
        opts
        |> Keyword.drop([:agent_runner, :states, :tracker])
        |> Keyword.put(:dry_run, dry_run)
        |> Keyword.put(:maestro, true)
        |> Keyword.put(:max_turns, 1)
        |> Keyword.put(:prompt_template, prompt_template(dry_run: dry_run))

      case safe_run_agent(runner, issue, nil, runner_opts) do
        :ok ->
          {:ok,
           %AgentRun{
             issue_id: issue_id,
             identifier: issue_identifier(issue),
             dry_run: dry_run
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp safe_run_agent(runner, issue, recipient, opts) when is_function(runner, 3) do
    case runner.(issue, recipient, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_runner_result, other}}
    end
  rescue
    error ->
      {:error, {:exception, error}}
  end

  defp context_issue(%ReviewContext{issue: nil}), do: {:error, :missing_issue}
  defp context_issue(%ReviewContext{issue: issue}), do: {:ok, issue}
  defp context_issue(%{issue: nil}), do: {:error, :missing_issue}
  defp context_issue(%{issue: issue}), do: {:ok, issue}
  defp context_issue(_context), do: {:error, :missing_issue}

  defp issue_id(issue, context) do
    case context_issue_id(context) || issue_field(issue, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_issue_id}
    end
  end

  defp context_issue_id(%ReviewContext{issue_id: issue_id}), do: normalize_id(issue_id)
  defp context_issue_id(%{issue_id: issue_id}), do: normalize_id(issue_id)
  defp context_issue_id(_context), do: nil

  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_id), do: nil

  defp issue_identifier(issue), do: issue_field(issue, :identifier)

  defp issue_field(%Issue{} = issue, field), do: Map.get(issue, field)
  defp issue_field(issue, field) when is_map(issue), do: Map.get(issue, field) || Map.get(issue, to_string(field))
  defp issue_field(_issue, _field), do: nil
end
