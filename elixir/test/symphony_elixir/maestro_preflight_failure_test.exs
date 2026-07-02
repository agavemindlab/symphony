defmodule SymphonyElixir.MaestroPreflightFailureTest do
  use ExUnit.Case, async: false

  test "failure helper does not duplicate no-action comment when label cleanup retries" do
    {:ok, state} =
      Agent.start_link(fn ->
        %{
          comments: [],
          labels: [
            %{"id" => "symphony-label", "name" => "symphony"},
            %{"id" => "maestro-label", "name" => "symphony:maestro"},
            %{"id" => "feature-label", "name" => "Type:Feature"}
          ],
          update_attempts: 0
        }
      end)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_socket)
    server = spawn_link(fn -> serve_linear_graphql(listen_socket, state) end)

    on_exit(fn ->
      :gen_tcp.close(listen_socket)

      if Process.alive?(state) do
        Agent.stop(state)
      end

      if Process.alive?(server) do
        Process.exit(server, :kill)
      end
    end)

    script = Path.expand("../workflows/agavemindlab/maestro-preflight-failure.sh", File.cwd!())

    env = [
      {"LINEAR_API_ENDPOINT", "http://127.0.0.1:#{port}/graphql"},
      {"LINEAR_API_KEY", "test-token"},
      {"SYMPHONY_ISSUE_ID", "issue-1"},
      {"SYMPHONY_MAESTRO_FAILURE_STATUS", "128"},
      {"SYMPHONY_MAESTRO_FAILURE_REASON", "test checkout failed"}
    ]

    assert {_output, 0} = System.cmd("sh", [script], env: env, stderr_to_stdout: true)
    assert {_output, 0} = System.cmd("sh", [script], env: env, stderr_to_stdout: true)

    snapshot = Agent.get(state, & &1)
    assert length(snapshot.comments) == 1
    assert snapshot.update_attempts == 2
    refute Enum.any?(snapshot.labels, &(&1["name"] == "symphony:maestro"))
  end

  defp serve_linear_graphql(listen_socket, state) do
    case :gen_tcp.accept(listen_socket, 1_000) do
      {:ok, socket} ->
        with {:ok, body} <- read_http_body(socket) do
          body
          |> Jason.decode!()
          |> linear_response(state)
          |> send_json(socket)
        end

        :gen_tcp.close(socket)
        serve_linear_graphql(listen_socket, state)

      {:error, :timeout} ->
        serve_linear_graphql(listen_socket, state)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_http_body(socket) do
    with {:ok, request} <- recv_until(socket, "\r\n\r\n", "") do
      [headers, rest] = String.split(request, "\r\n\r\n", parts: 2)
      content_length = content_length(headers)
      remaining = content_length - byte_size(rest)

      if remaining > 0 do
        {:ok, body_tail} = :gen_tcp.recv(socket, remaining, 1_000)
        {:ok, rest <> body_tail}
      else
        {:ok, binary_part(rest, 0, content_length)}
      end
    end
  end

  defp recv_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, chunk} -> recv_until(socket, marker, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find(&(String.downcase(&1) |> String.starts_with?("content-length:")))
    |> String.split(":", parts: 2)
    |> List.last()
    |> String.trim()
    |> String.to_integer()
  end

  defp linear_response(%{"query" => query, "variables" => variables}, state) do
    cond do
      String.contains?(query, "MaestroPreflightFailureIssueLabels") ->
        labels = Agent.get(state, & &1.labels)

        %{
          "data" => %{
            "issue" => %{
              "labels" => %{
                "nodes" => labels,
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          }
        }

      String.contains?(query, "MaestroPreflightFailureIssue(") ->
        comments = Agent.get(state, & &1.comments)

        %{
          "data" => %{
            "issue" => %{
              "id" => variables["issueId"],
              "state" => %{"name" => "Human Review"},
              "comments" => %{
                "nodes" => [
                  %{
                    "id" => "artifact-1",
                    "body" => "## Implementation\n\nReady for review.",
                    "createdAt" => "2026-07-02T00:00:00Z",
                    "parent" => nil,
                    "resolvedAt" => nil,
                    "children" => %{"nodes" => comments}
                  }
                ]
              }
            }
          }
        }

      String.contains?(query, "MaestroPreflightFailureComment") ->
        body = variables["body"]

        Agent.update(state, fn snapshot ->
          comment = %{
            "id" => "comment-#{length(snapshot.comments) + 1}",
            "body" => body,
            "createdAt" => "2026-07-02T00:00:01Z"
          }

          %{snapshot | comments: snapshot.comments ++ [comment]}
        end)

        %{"data" => %{"commentCreate" => %{"success" => true}}}

      String.contains?(query, "MaestroPreflightFailureCleanup") ->
        Agent.get_and_update(state, &record_cleanup_attempt(&1, variables["labelIds"]))
    end
  end

  defp record_cleanup_attempt(snapshot, label_ids) do
    update_attempts = snapshot.update_attempts + 1
    response = %{"data" => %{"issueUpdate" => %{"success" => update_attempts > 1}}}
    {response, cleanup_snapshot(snapshot, label_ids, update_attempts)}
  end

  defp cleanup_snapshot(snapshot, _label_ids, 1), do: %{snapshot | update_attempts: 1}

  defp cleanup_snapshot(snapshot, label_ids, update_attempts) do
    labels = Enum.filter(snapshot.labels, &(&1["id"] in label_ids))
    %{snapshot | update_attempts: update_attempts, labels: labels}
  end

  defp send_json(payload, socket) do
    body = Jason.encode!(payload)

    response = [
      "HTTP/1.1 200 OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end
end
