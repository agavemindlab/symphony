defmodule SymphonyElixir.RunRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{DispatchControl, RunRegistry}

  test "run registry upserts, updates, and deletes durable entries" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-run-registry-#{System.unique_integer([:positive])}")

    previous_registry_file = Application.get_env(:symphony_elixir, :run_registry_file)

    on_exit(fn ->
      restore_app_env(:run_registry_file, previous_registry_file)
      File.rm_rf(test_root)
    end)

    registry_file = Path.join(test_root, "registry.json")
    Application.put_env(:symphony_elixir, :run_registry_file, registry_file)

    entry = %{
      issue_id: "issue-1",
      identifier: "MT-1",
      issue_url: "https://example.org/issues/MT-1",
      workspace_path: "/workspaces/MT-1",
      worker_host: nil,
      thread_id: "thread-1",
      session_id: nil,
      attempt: 0,
      started_at: DateTime.utc_now(),
      project: %{id: "project-id", slug_id: "project", name: "Project"}
    }

    assert RunRegistry.load() == []
    assert :ok = RunRegistry.upsert(entry)

    assert [
             %{
               issue_id: "issue-1",
               identifier: "MT-1",
               thread_id: "thread-1",
               session_id: nil,
               workspace_path: "/workspaces/MT-1"
             }
           ] = RunRegistry.load()

    assert :ok = RunRegistry.upsert(%{entry | session_id: "thread-1-turn-1"})
    assert [%{session_id: "thread-1-turn-1"}] = RunRegistry.load()

    assert :ok = RunRegistry.delete("issue-1")
    assert RunRegistry.load() == []
  end

  test "dispatch control pause marker survives process restarts" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-dispatch-control-#{System.unique_integer([:positive])}")

    previous_control_file = Application.get_env(:symphony_elixir, :dispatch_control_file)

    on_exit(fn ->
      restore_app_env(:dispatch_control_file, previous_control_file)
      File.rm_rf(test_root)
    end)

    control_file = Path.join(test_root, "dispatch-paused.json")
    Application.put_env(:symphony_elixir, :dispatch_control_file, control_file)

    refute DispatchControl.paused?()
    assert %{paused: false, path: ^control_file} = DispatchControl.state()

    assert :ok = DispatchControl.pause("restart rollout")
    assert DispatchControl.paused?()

    assert %{paused: true, reason: "restart rollout", path: ^control_file, paused_at: paused_at} =
             DispatchControl.state()

    assert is_binary(paused_at)

    assert :ok = DispatchControl.resume()
    refute DispatchControl.paused?()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
