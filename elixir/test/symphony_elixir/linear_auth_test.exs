defmodule SymphonyElixir.LinearAuthTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Auth

  defmodule LinearStub do
    import Plug.Conn

    def init(parent), do: parent

    def call(%{request_path: "/oauth/token"} = conn, parent) do
      {:ok, body, conn} = read_body(conn)
      params = URI.decode_query(body)
      send(parent, {:token_exchange, params})
      token = params["client_id"] <> "-access-token"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"access_token" => token}))
    end

    def call(%{request_path: "/graphql"} = conn, parent) do
      {:ok, body, conn} = read_body(conn)
      authorization = get_req_header(conn, "authorization") |> List.first()
      send(parent, {:graphql_read, authorization, Jason.decode!(body)})
      viewer = authorization |> String.replace_prefix("Bearer ", "") |> String.replace_suffix("-access-token", "")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"data" => %{"viewer" => %{"id" => viewer}}}))
    end
  end

  setup do
    previous_client_id = System.get_env("LINEAR_CLIENT_ID")
    previous_client_secret = System.get_env("LINEAR_CLIENT_SECRET")
    previous_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_CLIENT_ID", previous_client_id)
      restore_env("LINEAR_CLIENT_SECRET", previous_client_secret)
      restore_env("LINEAR_API_KEY", previous_api_key)
      Auth.reset_for_test()
    end)

    System.delete_env("LINEAR_API_KEY")
    System.put_env("LINEAR_CLIENT_ID", "client-id-probe")
    System.put_env("LINEAR_CLIENT_SECRET", "client-secret-probe")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)
    Auth.reset_for_test()
    :ok
  end

  test "exchanges client credentials once and keeps the access token in memory" do
    parent = self()

    request_fun = fn url, opts ->
      send(parent, {:token_request, url, opts})
      {:ok, %{status: 200, body: %{"access_token" => "access-token-probe"}}}
    end

    assert {:ok, %{mode: :oauth, token: "access-token-probe"}} =
             Auth.authorization(request_fun: request_fun)

    assert {:ok, %{mode: :oauth, token: "access-token-probe"}} =
             Auth.authorization(request_fun: request_fun)

    assert_receive {:token_request, "https://api.linear.app/oauth/token", opts}
    assert opts[:form][:grant_type] == "client_credentials"
    assert opts[:form][:scope] == "read,write"
    assert opts[:form][:client_id] == "client-id-probe"
    assert opts[:form][:client_secret] == "client-secret-probe"
    refute_receive {:token_request, _, _}
  end

  test "main and Maestro credentials each cross Req for one exchange and GraphQL read" do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {LinearStub, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: make_ref()
        )
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    base_url = "http://127.0.0.1:#{port}"
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil, tracker_endpoint: base_url <> "/graphql")

    for {client_id, client_secret} <- [{"main-client", "main-secret"}, {"maestro-client", "maestro-secret"}] do
      System.put_env("LINEAR_CLIENT_ID", client_id)
      System.put_env("LINEAR_CLIENT_SECRET", client_secret)
      Auth.reset_for_test()

      assert {:ok, %{"data" => %{"viewer" => %{"id" => ^client_id}}}} =
               Client.graphql("query Viewer { viewer { id } }", %{}, auth_opts: [token_endpoint: base_url <> "/oauth/token"])

      assert_receive {:token_exchange,
                      %{
                        "client_id" => ^client_id,
                        "client_secret" => ^client_secret,
                        "grant_type" => "client_credentials",
                        "scope" => "read,write"
                      }}

      assert_receive {:graphql_read, "Bearer " <> ^client_id <> "-access-token", %{"query" => query}}
      assert query =~ "viewer"
      refute_receive {:token_exchange, _}
    end
  end

  test "coalesces concurrent refreshes for the same failed token" do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    request_fun = fn _url, _opts ->
      call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      {:ok, %{status: 200, body: %{"access_token" => "token-#{call}"}}}
    end

    assert {:ok, %{token: "token-1"}} = Auth.authorization(request_fun: request_fun)

    results =
      1..8
      |> Task.async_stream(fn _ -> Auth.refresh("token-1", request_fun: request_fun) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [{:ok, %{mode: :oauth, token: "token-2"}}]
    assert Agent.get(calls, & &1) == 2
  end

  test "returns safe errors for incomplete credentials and failed exchanges" do
    System.delete_env("LINEAR_CLIENT_SECRET")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    assert {:error, {:missing_linear_auth_variable, "LINEAR_CLIENT_SECRET"}} =
             Auth.authorization(request_fun: fn _, _ -> flunk("exchange must not run") end)

    System.put_env("LINEAR_CLIENT_SECRET", "client-secret-probe")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    error =
      Auth.authorization(
        request_fun: fn _, _ ->
          {:ok, %{status: 503, body: "access-token-probe client-secret-probe"}}
        end
      )

    assert error == {:error, {:linear_oauth_token_status, 503}}
    refute inspect(error) =~ "client-secret-probe"
    refute inspect(error) =~ "access-token-probe"

    assert {:error, :invalid_linear_oauth_token_response} =
             Auth.authorization(request_fun: fn _, _ -> {:ok, %{status: 200, body: %{}}} end)

    assert {:error, :linear_oauth_token_request_failed} =
             Auth.authorization(request_fun: fn _, _ -> {:error, :timeout} end)
  end

  test "renews after one OAuth 401 and replays the GraphQL request once" do
    token_calls = Agent.start_link(fn -> 0 end) |> elem(1)
    graphql_calls = Agent.start_link(fn -> 0 end) |> elem(1)

    token_request_fun = fn _, _ ->
      call = Agent.get_and_update(token_calls, &{&1 + 1, &1 + 1})
      {:ok, %{status: 200, body: %{"access_token" => "token-#{call}"}}}
    end

    graphql_request_fun = fn _payload, headers ->
      call = Agent.get_and_update(graphql_calls, &{&1 + 1, &1 + 1})
      assert {"Authorization", "Bearer token-#{call}"} in headers

      if call == 1 do
        {:ok, %{status: 401, body: "expired token-1"}}
      else
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer"}}}}}
      end
    end

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer"}}}} =
             Client.graphql("query Viewer { viewer { id } }", %{},
               request_fun: graphql_request_fun,
               auth_opts: [request_fun: token_request_fun]
             )

    assert Agent.get(token_calls, & &1) == 2
    assert Agent.get(graphql_calls, & &1) == 2
  end

  test "stops after the replacement token also receives a 401" do
    token_calls = Agent.start_link(fn -> 0 end) |> elem(1)
    graphql_calls = Agent.start_link(fn -> 0 end) |> elem(1)

    token_request_fun = fn _, _ ->
      call = Agent.get_and_update(token_calls, &{&1 + 1, &1 + 1})
      {:ok, %{status: 200, body: %{"access_token" => "token-#{call}"}}}
    end

    log =
      capture_log(fn ->
        assert {:error, {:linear_api_status, 401}} =
                 Client.graphql("query Viewer { viewer { id } }", %{},
                   request_fun: fn _payload, _headers ->
                     Agent.update(graphql_calls, &(&1 + 1))
                     {:ok, %{status: 401, body: "access-token-probe client-secret-probe"}}
                   end,
                   auth_opts: [request_fun: token_request_fun]
                 )
      end)

    assert Agent.get(token_calls, & &1) == 2
    assert Agent.get(graphql_calls, & &1) == 2
    refute log =~ "access-token-probe"
    refute log =~ "client-secret-probe"
  end

  test "does not log OAuth response bodies on non-401 failures" do
    token_request_fun = fn _, _ ->
      {:ok, %{status: 200, body: %{"access_token" => "access-token-probe"}}}
    end

    log =
      capture_log(fn ->
        assert {:error, {:linear_api_status, 403}} =
                 Client.graphql("query Viewer { viewer { id } }", %{},
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 403, body: "access-token-probe client-secret-probe"}}
                   end,
                   auth_opts: [request_fun: token_request_fun]
                 )
      end)

    refute log =~ "access-token-probe"
    refute log =~ "client-secret-probe"
  end

  test "LINEAR_API_KEY overrides complete client credentials without an exchange" do
    System.put_env("LINEAR_API_KEY", "api-key-probe")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    assert {:ok, %{mode: :api_key, token: "api-key-probe"}} =
             Auth.authorization(request_fun: fn _, _ -> flunk("exchange must not run") end)

    assert :ok = Auth.prewarm(request_fun: fn _, _ -> flunk("exchange must not run") end)

    assert {:ok, %{mode: :api_key, token: "api-key-probe"}} =
             Auth.refresh("stale-oauth-token", request_fun: fn _, _ -> flunk("exchange must not run") end)
  end

  test "prewarm and refresh return safe configuration and request errors" do
    System.delete_env("LINEAR_CLIENT_SECRET")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    expected = {:error, {:missing_linear_auth_variable, "LINEAR_CLIENT_SECRET"}}
    assert Auth.prewarm() == expected
    assert Auth.refresh("stale-token") == expected

    System.put_env("LINEAR_CLIENT_SECRET", "client-secret-probe")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    assert {:error, :invalid_linear_oauth_token_response} =
             Auth.authorization(request_fun: fn _, _ -> :unexpected end)

    assert {:error, :linear_oauth_token_request_failed} =
             Auth.authorization(request_fun: fn _, _ -> raise "access-token-probe" end)

    assert {:error, :linear_oauth_token_request_failed} =
             Auth.authorization(request_fun: fn _, _ -> throw("client-secret-probe") end)
  end
end
