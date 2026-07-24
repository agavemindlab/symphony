defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @linear_auth_env_names ["LINEAR_API_KEY", "LINEAR_CLIENT_ID", "LINEAR_CLIENT_SECRET"]

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @doc """
  Base URLs of the OTHER Symphony instances whose dashboards this instance
  should surface. The configuration semantic is "the other instances" — no
  self-exclusion logic is applied.
  """
  @spec peer_dashboards() :: [String.t()]
  def peer_dashboards do
    case Application.get_env(:symphony_elixir, :peer_dashboards) do
      urls when is_list(urls) ->
        urls

      _unset ->
        "SYMPHONY_PEER_DASHBOARDS"
        |> System.get_env("")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  GitHub repositories (`OWNER/NAME`) whose merged PRs feed the analytics
  store via `mix symphony.events.github`. Resolution order: the
  `:github_repos` app env list override, then the comma-separated
  `SYMPHONY_GITHUB_REPOS` environment variable, then `[]`.
  """
  @spec github_repos() :: [String.t()]
  def github_repos do
    case Application.get_env(:symphony_elixir, :github_repos) do
      repos when is_list(repos) ->
        repos

      _unset ->
        "SYMPHONY_GITHUB_REPOS"
        |> System.get_env("")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  Optional floor date for the analytics event store. Events whose time axis
  (`occurred_at || recorded_at`) falls before this UTC date are dropped at
  write time, so backfill/scanner sweeps over old comment history cannot
  reintroduce pre-era events. Resolution order: the `:analytics_epoch` app
  env `Date` override, then the `SYMPHONY_ANALYTICS_EPOCH` environment
  variable (`YYYY-MM-DD`), then nil (no floor).
  """
  @spec analytics_epoch() :: Date.t() | nil
  def analytics_epoch do
    case Application.get_env(:symphony_elixir, :analytics_epoch) do
      %Date{} = date ->
        date

      _unset ->
        with value when is_binary(value) <- System.get_env("SYMPHONY_ANALYTICS_EPOCH"),
             {:ok, date} <- Date.from_iso8601(String.trim(value)) do
          date
        else
          _absent_or_invalid -> nil
        end
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec linear_auth() ::
          {:ok, {:api_key, String.t()} | {:client_credentials, String.t(), String.t()}}
          | {:error, term()}
  def linear_auth, do: settings!().tracker |> linear_auth()

  @spec linear_auth(Schema.Tracker.t()) ::
          {:ok, {:api_key, String.t()} | {:client_credentials, String.t(), String.t()}}
          | {:error, term()}
  def linear_auth(%Schema.Tracker{api_key: api_key}) when is_binary(api_key), do: {:ok, {:api_key, api_key}}

  def linear_auth(%Schema.Tracker{client_id: client_id, client_secret: client_secret}) do
    case {client_id, client_secret} do
      {client_id, client_secret} when is_binary(client_id) and is_binary(client_secret) ->
        {:ok, {:client_credentials, client_id, client_secret}}

      {client_id, _} when is_binary(client_id) ->
        {:error, {:missing_linear_auth_variable, "LINEAR_CLIENT_SECRET"}}

      {_, client_secret} when is_binary(client_secret) ->
        {:error, {:missing_linear_auth_variable, "LINEAR_CLIENT_ID"}}

      _ ->
        {:error, :missing_linear_auth}
    end
  end

  @spec linear_auth_env_names() :: [String.t()]
  def linear_auth_env_names, do: linear_auth_env_names(settings!())

  @spec linear_auth_env_names(Schema.t()) :: [String.t()]
  def linear_auth_env_names(%Schema{} = settings),
    do: Enum.uniq(@linear_auth_env_names ++ settings.tracker.auth_env_names)

  @spec linear_auth_unset_command() :: String.t()
  def linear_auth_unset_command, do: linear_auth_unset_command(linear_auth_env_names())

  @spec linear_auth_unset_command([String.t()]) :: String.t()
  def linear_auth_unset_command(auth_names), do: "command unset " <> Enum.join(auth_names, " ") <> " || exit 126"

  @spec configured_project_slugs() :: {:ok, [String.t()]} | {:error, term()}
  def configured_project_slugs, do: Schema.configured_project_slugs(settings!().tracker)

  @spec configured_project_slugs(Schema.Tracker.t()) :: {:ok, [String.t()]} | {:error, term()}
  def configured_project_slugs(%Schema.Tracker{} = tracker), do: Schema.configured_project_slugs(tracker)

  @spec configured_project_names() :: {:ok, [String.t()]} | {:error, term()}
  def configured_project_names, do: Schema.configured_project_names(settings!().tracker)

  @spec configured_project_names(Schema.Tracker.t()) :: {:ok, [String.t()]} | {:error, term()}
  def configured_project_names(%Schema.Tracker{} = tracker), do: Schema.configured_project_names(tracker)

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" ->
        validate_linear_tracker_semantics(settings.tracker)

      true ->
        :ok
    end
  end

  defp validate_linear_tracker_semantics(tracker) do
    with {:ok, _auth} <- linear_auth(tracker),
         {:ok, project_slugs} <- configured_project_slugs(tracker),
         {:ok, project_names} <- configured_project_names(tracker) do
      validate_linear_project_scope(project_slugs, project_names)
    end
  end

  defp validate_linear_project_scope(project_slugs, project_names) do
    cond do
      project_slugs != [] and project_names != [] -> {:error, :conflicting_linear_project_scope_config}
      project_slugs == [] and project_names == [] -> {:error, :missing_linear_project_scope}
      true -> :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
