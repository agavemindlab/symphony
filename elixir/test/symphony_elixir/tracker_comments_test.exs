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
        "user" => %{
          "id" => "user-1",
          "name" => "Ada Lovelace",
          "displayName" => "ada",
          "app" => false
        },
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
             author_app: false,
             bot_actor_present: false,
             author_is_bot: false
           }
  end

  test "linear client comment normalization falls back through author names" do
    named_user =
      Client.normalize_comment_for_test(%{
        "id" => "comment-2",
        "body" => "Name only",
        "user" => %{
          "id" => "user-1",
          "name" => "Ada Lovelace",
          "displayName" => "",
          "app" => false
        }
      })

    assert named_user.author_name == "Ada Lovelace"
    assert named_user.author_is_bot
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
        "user" => %{"id" => "user-2", "name" => nil, "displayName" => nil, "app" => false},
        "botActor" => %{"id" => "bot-1", "name" => "Maestro"}
      })

    assert user_backed_bot.author_name == "Maestro"
    assert user_backed_bot.author_is_bot

    anonymous =
      Client.normalize_comment_for_test(%{"id" => "comment-5", "body" => "No author"})

    assert anonymous.author_name == nil
    assert anonymous.author_is_bot
  end

  test "linear client preserves strict comment actor provenance" do
    [
      {%{"user" => %{"id" => "human-a", "app" => false}, "botActor" => nil}, false, false, false},
      {%{"user" => %{"id" => "human-b", "app" => false}, "botActor" => nil}, false, false, false},
      {%{"user" => %{"id" => "maestro", "app" => true}, "botActor" => nil}, true, false, true},
      {%{"user" => nil, "botActor" => %{"id" => "bot"}}, :unknown, true, true},
      {%{"user" => %{"id" => "user-bot", "app" => false}, "botActor" => %{"id" => "bot"}}, false, true, true},
      {%{"user" => %{"id" => "missing-app"}, "botActor" => nil}, :unknown, false, true},
      {%{"user" => %{"id" => "missing-bot-key", "app" => false}}, false, :unknown, true}
    ]
    |> Enum.each(fn {input, author_app, bot_actor_present, author_is_bot} ->
      comment = Client.normalize_comment_for_test(input)

      assert comment.author_app == author_app
      assert comment.bot_actor_present == bot_actor_present
      assert comment.author_is_bot == author_is_bot
    end)
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
    assert query =~ ~r/user\s*\{[^}]*\bapp\b/s

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

  test "linear client fetch_issue_comments requires configured auth" do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_client_id = System.get_env("LINEAR_CLIENT_ID")
    previous_client_secret = System.get_env("LINEAR_CLIENT_SECRET")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("LINEAR_CLIENT_ID", previous_client_id)
      restore_env("LINEAR_CLIENT_SECRET", previous_client_secret)
    end)

    System.delete_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_CLIENT_ID")
    System.delete_env("LINEAR_CLIENT_SECRET")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: nil)

    capture_log(fn ->
      assert {:error, :missing_linear_auth} = Client.fetch_issue_comments("issue-1")
    end)
  end

  defp comment_node(comment_id, created_at) do
    %{
      "id" => comment_id,
      "body" => "Comment #{comment_id}",
      "createdAt" => created_at,
      "resolvedAt" => nil,
      "user" => %{
        "id" => "user-1",
        "name" => "Ada Lovelace",
        "displayName" => "ada",
        "app" => false
      },
      "botActor" => nil,
      "parent" => nil
    }
  end
end
