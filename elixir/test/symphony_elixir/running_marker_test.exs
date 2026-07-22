defmodule SymphonyElixir.RunningMarkerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Auth, RunningMarker}

  setup do
    previous = Map.new(["LINEAR_API_KEY", "LINEAR_CLIENT_ID", "LINEAR_CLIENT_SECRET"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      Auth.reset_for_test()
    end)

    :ok
  end

  test "OAuth-only running and stopped events add and remove the marker label" do
    oauth_only!()
    state = start_state!(team_label: %{"id" => "label-1", "name" => RunningMarker.label_name()})
    token_calls = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))
    opts = oauth_opts(state, token_calls)

    assert :ok = RunningMarker.update(:running, issue(), opts)
    assert Agent.get(state, & &1.attached) == [%{"id" => "label-1", "name" => RunningMarker.label_name()}]
    assert :ok = RunningMarker.update(:stopped, issue(), opts)
    assert Agent.get(state, & &1.attached) == []
    assert Agent.get(token_calls, & &1) == 1
  end

  test "an expired OAuth token refreshes once and replays the marker request once" do
    oauth_only!()
    state = start_state!(team_label: %{"id" => "label-1", "name" => RunningMarker.label_name()}, first_401: true)
    token_calls = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    assert :ok = RunningMarker.update(:running, issue(), oauth_opts(state, token_calls))
    assert Agent.get(token_calls, & &1) == 2
    assert Agent.get(state, & &1.graphql_calls) == 4
    assert Agent.get(state, & &1.attached) != []
  end

  test "a second OAuth 401 stops without a third request or sensitive log output" do
    oauth_only!()
    state = start_state!(always_401: true)
    token_calls = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    log =
      capture_log(fn ->
        assert {:error, :issue_labels_query_failed} =
                 RunningMarker.update(:running, issue(), oauth_opts(state, token_calls))
      end)

    assert Agent.get(token_calls, & &1) == 2
    assert Agent.get(state, & &1.graphql_calls) == 2
    refute log =~ "client-secret-probe"
    refute log =~ "token-"
  end

  test "API-key auth remains compatible and never exchanges OAuth credentials" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "api-key-probe")
    state = start_state!(team_label: %{"id" => "label-1", "name" => RunningMarker.label_name()})

    assert :ok =
             RunningMarker.update(:running, issue(),
               request_fun: marker_request_fun(state),
               auth_opts: [request_fun: fn _, _ -> flunk("OAuth exchange must not run") end]
             )

    assert Agent.get(state, & &1.authorizations) |> Enum.uniq() == ["api-key-probe"]
    assert Agent.get(state, & &1.attached) != []
  end

  test "running marker follows team-label pagination and uses atomic add" do
    System.put_env("LINEAR_API_KEY", "api-key-probe")

    state =
      start_state!(
        team_pages: %{
          nil => {[%{"id" => "other", "name" => "other"}], %{"hasNextPage" => true, "endCursor" => "next"}},
          "next" => {[%{"id" => "label-2", "name" => RunningMarker.label_name()}], %{"hasNextPage" => false, "endCursor" => nil}}
        }
      )

    assert :ok = RunningMarker.update(:running, issue(), request_fun: marker_request_fun(state))

    assert Agent.get(state, & &1.operations) == [
             "RunningMarkerIssueLabels",
             "RunningMarkerTeamLabels",
             "RunningMarkerTeamLabels",
             "RunningMarkerAddLabel"
           ]

    assert Agent.get(state, & &1.attached) == [%{"id" => "label-2", "name" => RunningMarker.label_name()}]
  end

  test "running creates a missing team label and stopped is idempotent when unattached" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "api-key-probe")
    state = start_state!([])

    assert :ok = RunningMarker.update(:stopped, issue(), request_fun: marker_request_fun(state))
    assert Agent.get(state, & &1.operations) == ["RunningMarkerIssueLabels"]

    assert :ok = RunningMarker.update(:running, issue(), request_fun: marker_request_fun(state))

    assert Agent.get(state, & &1.operations) |> Enum.take(-4) == [
             "RunningMarkerIssueLabels",
             "RunningMarkerTeamLabels",
             "RunningMarkerCreateLabel",
             "RunningMarkerAddLabel"
           ]
  end

  test "attached-label pagination short-circuits running without another mutation" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "api-key-probe")

    state =
      start_state!(
        issue_pages: %{
          nil => {[%{"id" => "other", "name" => "other"}], %{"hasNextPage" => true, "endCursor" => "next"}},
          "next" => {[%{"id" => "attached", "name" => RunningMarker.label_name()}], %{"hasNextPage" => false, "endCursor" => nil}}
        }
      )

    assert :ok = RunningMarker.update(:running, issue(), request_fun: marker_request_fun(state))
    assert Agent.get(state, & &1.operations) == ["RunningMarkerIssueLabels", "RunningMarkerIssueLabels"]
  end

  test "marker maps malformed pages, creates, and mutations to safe errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "api-key-probe")

    assert {:error, :invalid_running_marker_input} = RunningMarker.update(:unsupported, issue(), [])

    missing_issue = start_state!(issue_missing: true)
    assert :ok = RunningMarker.update(:stopped, issue(), request_fun: marker_request_fun(missing_issue))

    invalid_issue_page = start_state!(issue_page_info: %{"hasNextPage" => true, "endCursor" => nil})

    assert {:error, :issue_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(invalid_issue_page))

    blank_issue_cursor = start_state!(issue_page_info: %{"hasNextPage" => true, "endCursor" => ""})

    assert {:error, :issue_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(blank_issue_cursor))

    assert Agent.get(blank_issue_cursor, & &1.graphql_calls) == 1

    malformed_issue_page =
      start_state!(
        issue_pages: %{
          nil => {[], %{"hasNextPage" => true, "endCursor" => "next"}},
          "next" => {[], %{"hasNextPage" => false, "endCursor" => nil}}
        },
        malformed_on_call: %{"RunningMarkerIssueLabels" => 2}
      )

    assert {:error, :issue_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(malformed_issue_page))

    malformed_team = start_state!(malformed_on_call: %{"RunningMarkerTeamLabels" => 1})

    assert {:error, :team_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(malformed_team))

    invalid_team_page = start_state!(team_page_info: %{"hasNextPage" => true, "endCursor" => nil})

    assert {:error, :team_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(invalid_team_page))

    blank_team_cursor = start_state!(team_page_info: %{"hasNextPage" => true, "endCursor" => ""})

    assert {:error, :team_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(blank_team_cursor))

    assert Agent.get(blank_team_cursor, & &1.graphql_calls) == 2

    create_failure =
      start_state!(
        create_failure: true,
        team_pages: %{nil => {[nil], %{"hasNextPage" => false, "endCursor" => nil}}}
      )

    assert {:error, :label_create_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(create_failure))

    add_failure =
      start_state!(
        team_label: %{"id" => "label-1", "name" => RunningMarker.label_name()},
        mutation_failures: MapSet.new(["RunningMarkerAddLabel"])
      )

    assert {:error, :label_add_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(add_failure))

    remove_failure =
      start_state!(
        attached: [%{"id" => "label-1", "name" => RunningMarker.label_name()}],
        mutation_failures: MapSet.new(["RunningMarkerRemoveLabel"])
      )

    assert {:error, :label_remove_failed} =
             RunningMarker.update(:stopped, issue(), request_fun: marker_request_fun(remove_failure))
  end

  test "marker rejects pagination cursors that do not advance" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "api-key-probe")

    issue_pages = %{
      nil => {[], %{"hasNextPage" => true, "endCursor" => "same"}},
      "same" => {[], %{"hasNextPage" => true, "endCursor" => "same"}}
    }

    issue_state = start_state!(issue_pages: issue_pages)

    assert {:error, :issue_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(issue_state))

    assert Agent.get(issue_state, & &1.graphql_calls) == 2

    team_pages = %{
      nil => {[], %{"hasNextPage" => true, "endCursor" => "same"}},
      "same" => {[], %{"hasNextPage" => true, "endCursor" => "same"}}
    }

    team_state = start_state!(team_pages: team_pages)

    assert {:error, :team_labels_query_failed} =
             RunningMarker.update(:running, issue(), request_fun: marker_request_fun(team_state))

    assert Agent.get(team_state, & &1.graphql_calls) == 3
  end

  test "native marker failure does not block a custom hook and custom hooks receive no Linear auth" do
    marker = Path.join(System.tmp_dir!(), "running-marker-custom-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)
    System.put_env("LINEAR_API_KEY", "api-key-probe")
    System.put_env("LINEAR_CLIENT_ID", "client-id-probe")
    System.put_env("LINEAR_CLIENT_SECRET", "client-secret-probe")
    previous_custom_secret = System.get_env("CUSTOM_LINEAR_SECRET")
    System.put_env("CUSTOM_LINEAR_SECRET", "custom-secret-probe")
    on_exit(fn -> restore_env("CUSTOM_LINEAR_SECRET", previous_custom_secret) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_client_secret: "$CUSTOM_LINEAR_SECRET",
      hook_linear_running_marker: true,
      hook_issue_running: "printf '%s|%s|%s|%s' \"${LINEAR_API_KEY-unset}\" \"${LINEAR_CLIENT_ID-unset}\" \"${LINEAR_CLIENT_SECRET-unset}\" \"${CUSTOM_LINEAR_SECRET-unset}\" > #{marker}"
    )

    log =
      capture_log(fn ->
        assert :ok =
                 SymphonyElixir.IssueRunHook.run(:running, issue(),
                   marker_opts: [
                     api_key: "api-key-probe",
                     request_fun: fn _, _ -> {:ok, %{status: 503, body: "client-secret-probe"}} end
                   ]
                 )
      end)

    assert File.read!(marker) == "unset|unset|unset|unset"
    assert log =~ "action=linear_running_marker"
    refute log =~ "client-secret-probe"
    assert_hook_failed("linear_running_marker")
  end

  test "custom hooks clear Linear auth reintroduced by shell initialization" do
    test_root = Path.join(System.tmp_dir!(), "running-marker-shell-auth-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(test_root, "bin")
    marker = Path.join(test_root, "auth-env.txt")
    previous_path = System.get_env("PATH")

    File.mkdir_p!(fake_bin)

    File.write!(Path.join(fake_bin, "sh"), """
    #!/bin/sh
    export LINEAR_API_KEY=reintroduced
    export LINEAR_CLIENT_ID=reintroduced
    export LINEAR_CLIENT_SECRET=reintroduced
    export CUSTOM_LINEAR_SECRET=reintroduced
    exec /bin/sh "$@"
    """)

    File.chmod!(Path.join(fake_bin, "sh"), 0o755)
    System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_client_secret: "$CUSTOM_LINEAR_SECRET",
      hook_issue_running: "printf '%s|%s|%s|%s' \"${LINEAR_API_KEY-unset}\" \"${LINEAR_CLIENT_ID-unset}\" \"${LINEAR_CLIENT_SECRET-unset}\" \"${CUSTOM_LINEAR_SECRET-unset}\" > #{marker}"
    )

    assert :ok = SymphonyElixir.IssueRunHook.run(:running, issue())
    assert File.read!(marker) == "unset|unset|unset|unset"
  end

  test "a native marker timeout still gives the custom hook its own timeout budget" do
    marker = Path.join(System.tmp_dir!(), "running-marker-timeout-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(marker) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      hook_linear_running_marker: true,
      hook_issue_running: "printf custom > #{marker}",
      hook_timeout_ms: 100
    )

    log =
      capture_log(fn ->
        assert :ok =
                 SymphonyElixir.IssueRunHook.run(:running, issue(),
                   marker_opts: [
                     api_key: "api-key-probe",
                     request_fun: fn _, _ -> Process.sleep(500) end
                   ]
                 )
      end)

    assert File.read!(marker) == "custom"
    assert log =~ "action=linear_running_marker"
    assert log =~ "timed out"
    assert_hook_failed("linear_running_marker")
  end

  test "custom hook failure records its action" do
    write_workflow_file!(Workflow.workflow_file_path(), hook_issue_running: "exit 17")
    assert :ok = SymphonyElixir.IssueRunHook.run(:running, issue())
    assert_hook_failed("custom")
  end

  test "explicitly null native marker is disabled safely" do
    write_workflow_file!(Workflow.workflow_file_path(), hook_linear_running_marker: nil)
    refute SymphonyElixir.IssueRunHook.configured?(:running)
    assert :ok = SymphonyElixir.IssueRunHook.run(:running, issue())
  end

  test "issue hook reports native marker success and task exit safely" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "api-key-probe",
      hook_linear_running_marker: true
    )

    assert SymphonyElixir.IssueRunHook.configured?(:running)
    success = start_state!(attached: [%{"id" => "label-1", "name" => RunningMarker.label_name()}])

    success_log =
      capture_log(fn ->
        assert :ok =
                 SymphonyElixir.IssueRunHook.run(:running, issue(), marker_opts: [request_fun: marker_request_fun(success)])
      end)

    assert success_log =~ "Issue run hook completed"

    exit_log =
      capture_log(fn ->
        assert :ok =
                 SymphonyElixir.IssueRunHook.run(:running, issue(), marker_opts: [request_fun: fn _, _ -> exit(:marker_task_exit) end])
      end)

    assert exit_log =~ "reason=:task_exit"

    rescue_log =
      capture_log(fn ->
        assert :ok =
                 SymphonyElixir.IssueRunHook.run(:running, issue(), marker_opts: [request_fun: fn _, _ -> raise "request failed" end])
      end)

    assert rescue_log =~ "reason=:task_exit"
  end

  test "explicit running label overrides the generated default" do
    previous = System.get_env("SYMPHONY_RUNNING_LABEL")
    on_exit(fn -> restore_env("SYMPHONY_RUNNING_LABEL", previous) end)
    System.put_env("SYMPHONY_RUNNING_LABEL", "custom-running-label")
    assert RunningMarker.label_name() == "custom-running-label"
  end

  defp issue, do: %Issue{id: "issue-1", identifier: "DEV-5518", title: "Marker", state: "In Progress"}

  defp oauth_only! do
    System.delete_env("LINEAR_API_KEY")
    System.put_env("LINEAR_CLIENT_ID", "client-id-probe")
    System.put_env("LINEAR_CLIENT_SECRET", "client-secret-probe")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    Auth.reset_for_test()
  end

  defp oauth_opts(state, token_calls) do
    [
      request_fun: marker_request_fun(state),
      auth_opts: [
        request_fun: fn _, _ ->
          call = Agent.get_and_update(token_calls, &{&1 + 1, &1 + 1})
          {:ok, %{status: 200, body: %{"access_token" => "token-#{call}"}}}
        end
      ]
    ]
  end

  defp start_state!(overrides) do
    defaults = %{
      attached: [],
      team_label: nil,
      team_pages: nil,
      issue_pages: nil,
      issue_page_info: nil,
      team_page_info: nil,
      issue_missing: false,
      malformed_on_call: %{},
      create_failure: false,
      mutation_failures: MapSet.new(),
      graphql_calls: 0,
      first_401: false,
      always_401: false,
      authorizations: [],
      operations: []
    }

    start_supervised!(Supervisor.child_spec({Agent, fn -> Map.merge(defaults, Map.new(overrides)) end}, id: make_ref()))
  end

  defp marker_request_fun(state) do
    fn payload, headers ->
      authorization = headers |> Enum.into(%{}) |> Map.fetch!("Authorization")
      operation = payload["operationName"]

      snapshot =
        Agent.get_and_update(state, fn current ->
          next = %{
            current
            | graphql_calls: current.graphql_calls + 1,
              authorizations: current.authorizations ++ [authorization],
              operations: current.operations ++ [operation]
          }

          {next, next}
        end)

      operation_call = Enum.count(snapshot.operations, &(&1 == operation))

      cond do
        snapshot.always_401 -> {:ok, %{status: 401, body: "token-probe"}}
        snapshot.first_401 and snapshot.graphql_calls == 1 -> {:ok, %{status: 401, body: "token-probe"}}
        Map.get(snapshot.malformed_on_call, operation) == operation_call -> ok(%{})
        true -> marker_response(state, operation, payload["variables"])
      end
    end
  end

  defp marker_response(state, "RunningMarkerIssueLabels", variables) do
    snapshot = Agent.get(state, & &1)

    if snapshot.issue_missing do
      ok(%{"data" => %{"issue" => nil}})
    else
      marker_issue_labels_response(snapshot, variables)
    end
  end

  defp marker_response(state, "RunningMarkerTeamLabels", variables) do
    snapshot = Agent.get(state, & &1)
    cursor = variables[:after]

    {nodes, page_info} =
      if snapshot.team_pages do
        Map.fetch!(snapshot.team_pages, cursor)
      else
        {List.wrap(snapshot.team_label), snapshot.team_page_info || %{"hasNextPage" => false, "endCursor" => nil}}
      end

    ok(%{"data" => %{"team" => %{"labels" => %{"nodes" => nodes, "pageInfo" => page_info}}}})
  end

  defp marker_response(state, "RunningMarkerCreateLabel", variables) do
    if Agent.get(state, & &1.create_failure) do
      ok(%{"data" => %{"issueLabelCreate" => %{"success" => false}}})
    else
      label = %{"id" => "created-label", "name" => variables[:name]}
      Agent.update(state, &%{&1 | team_label: label})
      ok(%{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => label}}})
    end
  end

  defp marker_response(state, "RunningMarkerAddLabel", variables) do
    if Agent.get(state, &MapSet.member?(&1.mutation_failures, "RunningMarkerAddLabel")) do
      ok(%{"data" => %{"issueAddLabel" => %{"success" => false}}})
    else
      snapshot = Agent.get(state, & &1)
      labels = [snapshot.team_label || %{"id" => variables[:labelId], "name" => RunningMarker.label_name()}]
      Agent.update(state, &%{&1 | attached: labels})
      ok(%{"data" => %{"issueAddLabel" => %{"success" => true}}})
    end
  end

  defp marker_response(state, "RunningMarkerRemoveLabel", _variables) do
    if Agent.get(state, &MapSet.member?(&1.mutation_failures, "RunningMarkerRemoveLabel")) do
      ok(%{"data" => %{"issueRemoveLabel" => %{"success" => false}}})
    else
      Agent.update(state, &%{&1 | attached: []})
      ok(%{"data" => %{"issueRemoveLabel" => %{"success" => true}}})
    end
  end

  defp marker_issue_labels_response(snapshot, variables) do
    {attached, page_info} =
      if snapshot.issue_pages do
        Map.fetch!(snapshot.issue_pages, variables[:after])
      else
        {snapshot.attached, snapshot.issue_page_info || %{"hasNextPage" => false, "endCursor" => nil}}
      end

    ok(%{
      "data" => %{
        "issue" => %{
          "team" => %{"id" => "team-1"},
          "labels" => %{
            "nodes" => attached,
            "pageInfo" => page_info
          }
        }
      }
    })
  end

  defp ok(body), do: {:ok, %{status: 200, body: body}}

  defp assert_hook_failed(action) do
    %{events: events} = SymphonyElixir.Analytics.read_events()

    assert Enum.count(events, fn event ->
             event["event_type"] == "hook_failed" and
               event["hook"] == "issue_running" and
               event["action"] == action and
               event["issue_id"] == "issue-1"
           end) == 1
  end
end
