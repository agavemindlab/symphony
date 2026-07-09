defmodule SymphonyElixir.TrackerCommentsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  defmodule FakeLinearClient do
    def fetch_issue_comments(issue_id) do
      send(self(), {:fetch_issue_comments_called, issue_id})
      {:ok, [%{id: "comment-1", body: "hello"}]}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
    end)

    :ok
  end

  test "tracker delegates fetch_issue_comments to the memory adapter" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    comment = %{
      id: "comment-1",
      body: "First",
      created_at: ~U[2026-01-01 00:00:00Z],
      resolved_at: nil,
      parent_id: nil,
      author_name: "Reviewer",
      author_is_bot: false
    }

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-1" => [comment]})

    assert Tracker.adapter() == Memory
    assert {:ok, [^comment]} = Tracker.fetch_issue_comments("issue-1")
    assert {:ok, []} = Tracker.fetch_issue_comments("issue-unknown")

    Application.delete_env(:symphony_elixir, :memory_tracker_comments)
    assert {:ok, []} = Memory.fetch_issue_comments("issue-1")
  end

  test "linear adapter delegates fetch_issue_comments to the configured client module" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [%{id: "comment-1", body: "hello"}]} = Adapter.fetch_issue_comments("issue-9")
    assert_receive {:fetch_issue_comments_called, "issue-9"}
  end

  test "linear client normalizes user comments preferring display name" do
    comment =
      Client.normalize_comment_for_test(%{
        "id" => "comment-1",
        "body" => "Looks good",
        "createdAt" => "2026-01-01T00:00:00Z",
        "resolvedAt" => "2026-01-02T00:00:00Z",
        "user" => %{"id" => "user-1", "name" => "Ada Lovelace", "displayName" => "ada"},
        "botActor" => nil,
        "parent" => %{"id" => "comment-0"}
      })

    assert comment == %{
             id: "comment-1",
             body: "Looks good",
             created_at: ~U[2026-01-01 00:00:00Z],
             resolved_at: ~U[2026-01-02 00:00:00Z],
             parent_id: "comment-0",
             author_name: "ada",
             author_is_bot: false
           }
  end

  test "linear client comment normalization falls back through author names" do
    named_user =
      Client.normalize_comment_for_test(%{
        "id" => "comment-2",
        "body" => "Name only",
        "user" => %{"id" => "user-1", "name" => "Ada Lovelace", "displayName" => ""}
      })

    assert named_user.author_name == "Ada Lovelace"
    refute named_user.author_is_bot
    assert named_user.parent_id == nil
    assert named_user.created_at == nil
    assert named_user.resolved_at == nil

    bot_comment =
      Client.normalize_comment_for_test(%{
        "id" => "comment-3",
        "body" => "Bot reply",
        "user" => nil,
        "botActor" => %{"id" => "bot-1", "name" => "Maestro"}
      })

    assert bot_comment.author_name == "Maestro"
    assert bot_comment.author_is_bot

    user_backed_bot =
      Client.normalize_comment_for_test(%{
        "id" => "comment-4",
        "body" => "App acting for a user",
        "user" => %{"id" => "user-2", "name" => nil, "displayName" => nil},
        "botActor" => %{"id" => "bot-1", "name" => "Maestro"}
      })

    assert user_backed_bot.author_name == "Maestro"
    refute user_backed_bot.author_is_bot

    anonymous =
      Client.normalize_comment_for_test(%{"id" => "comment-5", "body" => "No author"})

    assert anonymous.author_name == nil
    refute anonymous.author_is_bot
  end

  test "linear client paginates issue comments and sorts ascending by created_at" do
    page_1 = %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => [
              comment_node("comment-3", "2026-01-03T00:00:00Z"),
              comment_node("comment-2", "2026-01-02T00:00:00Z")
            ],
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
          }
        }
      }
    }

    page_2 = %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => [
              comment_node("comment-1", "2026-01-01T00:00:00Z"),
              comment_node("comment-0", nil)
            ],
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }

    graphql_fun = fn query, variables ->
      send(self(), {:issue_comments_page, query, variables})

      case variables.after do
        nil -> {:ok, page_1}
        "cursor-1" -> {:ok, page_2}
      end
    end

    assert {:ok, comments} = Client.fetch_issue_comments_for_test("issue-1", graphql_fun)

    assert Enum.map(comments, & &1.id) == ["comment-0", "comment-1", "comment-2", "comment-3"]

    assert_receive {:issue_comments_page, query, %{issueId: "issue-1", first: 100, after: nil}}
    assert query =~ "SymphonyIssueComments"

    assert_receive {:issue_comments_page, ^query, %{issueId: "issue-1", first: 100, after: "cursor-1"}}
  end

  test "linear client surfaces comment fetch errors" do
    errors_fun = fn _query, _variables ->
      {:ok, %{"errors" => [%{"message" => "boom"}]}}
    end

    assert {:error, {:linear_graphql_errors, [%{"message" => "boom"}]}} =
             Client.fetch_issue_comments_for_test("issue-1", errors_fun)

    unknown_fun = fn _query, _variables -> {:ok, %{"data" => %{"issue" => nil}}} end

    assert {:error, :linear_unknown_payload} =
             Client.fetch_issue_comments_for_test("issue-1", unknown_fun)

    missing_cursor_fun = fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [],
               "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}
             }
           }
         }
       }}
    end

    assert {:error, :linear_missing_end_cursor} =
             Client.fetch_issue_comments_for_test("issue-1", missing_cursor_fun)

    transport_error_fun = fn _query, _variables -> {:error, :boom} end

    assert {:error, :boom} = Client.fetch_issue_comments_for_test("issue-1", transport_error_fun)
  end

  test "linear client fetch_issue_comments requires an api token" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    capture_log(fn ->
      assert {:error, {:linear_api_request, :missing_linear_api_token}} =
               Client.fetch_issue_comments("issue-1")
    end)
  end

  defp comment_node(comment_id, created_at) do
    %{
      "id" => comment_id,
      "body" => "Comment #{comment_id}",
      "createdAt" => created_at,
      "resolvedAt" => nil,
      "user" => %{"id" => "user-1", "name" => "Ada Lovelace", "displayName" => "ada"},
      "botActor" => nil,
      "parent" => nil
    }
  end
end
