defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"
  @project_env_marker "__SYMPHONY_PROJECT_ENV__"
  @project_env_keys [
    "SYMPHONY_WORKFLOW_DIR",
    "SYMPHONY_LINEAR_PROJECT_ID",
    "SYMPHONY_LINEAR_PROJECT_SLUG",
    "SYMPHONY_LINEAR_PROJECT_NAME",
    "SYMPHONY_PROJECT_DIR",
    "SYMPHONY_PROJECT_SLUG",
    "SYMPHONY_REPO",
    "SYMPHONY_BASE_BRANCH",
    "SYMPHONY_PROFILE",
    "SYMPHONY_ACCEPTANCE_USER_EMAIL_ENV",
    "SYMPHONY_ACCEPTANCE_USER_CODE_ENV",
    "SYMPHONY_ACCEPTANCE_USER_PURPOSE"
  ]

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type resolved_project_env :: %{
          workflow_file: Path.t(),
          workflow_dir: Path.t(),
          env: %{String.t() => String.t()}
        }

  @spec resolve_project_env(map() | String.t() | nil) :: {:ok, resolved_project_env()} | {:error, term()}
  def resolve_project_env(issue_or_context) do
    workflow_file = workflow_file_path()
    workflow_dir = Path.dirname(workflow_file)
    project = issue_project(issue_or_context)
    base_env = base_project_env(workflow_dir, project)
    selector = Path.join(workflow_dir, "project-for-linear-project.sh")

    if File.regular?(selector) do
      resolve_project_env_from_selector(workflow_file, workflow_dir, base_env)
    else
      {:ok,
       %{
         workflow_file: workflow_file,
         workflow_dir: workflow_dir,
         env: merge_process_project_env(base_env)
       }}
    end
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ["\r\n", "\n", "\r"], trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end

  defp resolve_project_env_from_selector(workflow_file, workflow_dir, base_env) do
    script =
      [
        "set -eu",
        unset_project_env_exports(),
        Enum.map_join(base_env, "\n", fn {key, value} -> env_export(key, value) end),
        ~s(. "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh"),
        project_env_prints()
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case System.cmd("sh", ["-lc", script], cd: workflow_dir, stderr_to_stdout: true) do
      {output, 0} ->
        with {:ok, env} <- parse_project_env_output(output) do
          {:ok, %{workflow_file: workflow_file, workflow_dir: workflow_dir, env: Map.merge(base_env, env)}}
        end

      {output, status} ->
        {:error, {:project_env_resolve_failed, status, output}}
    end
  end

  defp base_project_env(workflow_dir, project) do
    %{
      "SYMPHONY_WORKFLOW_DIR" => workflow_dir,
      "SYMPHONY_PROJECT_DIR" => workflow_dir
    }
    |> maybe_put_env("SYMPHONY_LINEAR_PROJECT_ID", Map.get(project || %{}, :id))
    |> maybe_put_env("SYMPHONY_LINEAR_PROJECT_SLUG", Map.get(project || %{}, :slug_id))
    |> maybe_put_env("SYMPHONY_LINEAR_PROJECT_NAME", Map.get(project || %{}, :name))
  end

  defp merge_process_project_env(base_env) do
    linear_project_slug = Map.get(base_env, "SYMPHONY_LINEAR_PROJECT_SLUG")
    process_project_slug = System.get_env("SYMPHONY_PROJECT_SLUG")

    if compatible_process_project_env?(linear_project_slug, process_project_slug) do
      merge_compatible_process_project_env(base_env)
    else
      base_env
    end
  end

  defp merge_compatible_process_project_env(base_env) do
    Enum.reduce(@project_env_keys, base_env, fn key, env ->
      put_process_project_env(env, key, System.get_env(key))
    end)
  end

  defp put_process_project_env(env, key, value) when is_binary(value) and value != "" do
    Map.put_new(env, key, value)
  end

  defp put_process_project_env(env, _key, _value), do: env

  defp compatible_process_project_env?(nil, _process_project_slug), do: true
  defp compatible_process_project_env?("", _process_project_slug), do: true
  defp compatible_process_project_env?(_linear_project_slug, nil), do: true
  defp compatible_process_project_env?(_linear_project_slug, ""), do: true

  defp compatible_process_project_env?(linear_project_slug, process_project_slug) do
    linear_project_slug == process_project_slug
  end

  defp maybe_put_env(env, _key, nil), do: env
  defp maybe_put_env(env, key, value) when is_binary(value), do: Map.put(env, key, value)
  defp maybe_put_env(env, key, value), do: Map.put(env, key, to_string(value))

  defp unset_project_env_exports do
    project_env =
      @project_env_keys
      |> Enum.reject(&(&1 in ["SYMPHONY_WORKFLOW_DIR", "SYMPHONY_LINEAR_PROJECT_ID", "SYMPHONY_LINEAR_PROJECT_SLUG", "SYMPHONY_LINEAR_PROJECT_NAME"]))
      |> Enum.join(" ")

    "unset #{project_env}"
  end

  defp project_env_prints do
    Enum.map_join(@project_env_keys, "\n", fn key ->
      ~s(printf '%s\\t%s\\t%s\\n' '#{@project_env_marker}' '#{key}' "${#{key}:-}")
    end)
  end

  defp parse_project_env_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, &parse_project_env_line/2)
  end

  defp parse_project_env_line(line, {:ok, env}) do
    case String.split(line, "\t", parts: 3) do
      [@project_env_marker, key, value] -> put_project_env_line(env, key, value)
      _ -> {:cont, {:ok, env}}
    end
  end

  defp put_project_env_line(env, key, value) do
    if safe_env_value?(value) do
      {:cont, {:ok, Map.put(env, key, value)}}
    else
      {:halt, {:error, {:invalid_project_env_value, key}}}
    end
  end

  defp safe_env_value?(value) when is_binary(value) do
    not String.contains?(value, ["\n", "\r", <<0>>])
  end

  defp issue_project(%{project: project}) when is_map(project) do
    %{
      id: Map.get(project, :id) || Map.get(project, "id"),
      slug_id: Map.get(project, :slug_id) || Map.get(project, "slugId") || Map.get(project, "slug_id"),
      name: Map.get(project, :name) || Map.get(project, "name")
    }
  end

  defp issue_project(%{"project" => project}) when is_map(project) do
    issue_project(%{project: project})
  end

  defp issue_project(_issue), do: nil

  defp env_export(name, value) when is_binary(value), do: "export #{name}=#{shell_escape(value)}"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
