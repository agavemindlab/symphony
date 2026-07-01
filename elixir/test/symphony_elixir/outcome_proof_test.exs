defmodule SymphonyElixir.OutcomeProofTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Analytics
  alias SymphonyElixir.OutcomeProof

  test "collects linear and github proof into one deduplicated analytics snapshot" do
    path = tmp_path("outcome-proof-collector.ndjson")

    linear_graphql = fn query, variables ->
      send(self(), {:linear_query, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-1",
                 "identifier" => "DEV-1",
                 "completedAt" => "2026-06-15T12:00:00Z",
                 "url" => "https://linear.app/grandline/issue/DEV-1/test",
                 "state" => %{"name" => "Done", "type" => "completed"},
                 "project" => %{"name" => "symphony", "slugId" => "symphony"},
                 "comments" => %{
                   "nodes" => [
                     %{
                       "body" => "## Implementation",
                       "user" => %{"name" => "Symphony", "app" => true},
                       "botActor" => %{"name" => "Symphony"},
                       "children" => %{
                         "nodes" => [
                           %{
                             "body" => "⏩ 自动进入 Design",
                             "user" => %{"name" => "Symphony", "app" => true},
                             "botActor" => %{"name" => "Symphony"}
                           },
                           %{
                             "body" => "批准当前 Implementation",
                             "user" => %{"name" => "Qiangning Hong", "app" => false},
                             "botActor" => nil
                           }
                         ]
                       }
                     }
                   ]
                 },
                 "stateHistory" => %{
                   "nodes" => [
                     %{
                       "startedAt" => "2026-06-15T10:00:00Z",
                       "endedAt" => "2026-06-15T11:00:00Z",
                       "state" => %{"name" => "Human Review"}
                     }
                   ]
                 },
                 "attachments" => %{
                   "nodes" => [
                     %{"title" => "PR", "url" => "https://github.com/agavemindlab/symphony/pull/123"}
                   ]
                 }
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    github_pull_request = fn "https://github.com/agavemindlab/symphony/pull/123" ->
      {:ok,
       %{
         head_sha: "abc123",
         reviews: [
           %{author: %{login: "human-reviewer", type: "User"}, state: "APPROVED"},
           %{author: %{login: "github-actions[bot]", type: "Bot"}, state: "APPROVED"}
         ],
         comments: [],
         checks: [%{sha: "abc123", conclusion: "success"}]
       }}
    end

    opts = [
      path: path,
      linear_graphql: linear_graphql,
      github_pull_request: github_pull_request,
      collected_at: "2026-07-01T00:00:00Z",
      now: ~D[2026-07-01]
    ]

    assert {:ok, snapshot} = OutcomeProof.collect(opts)
    assert_receive {:linear_query, query, variables}
    assert query =~ "SymphonyOutcomeProofIssuesByProject"
    assert variables.first == 201

    metrics = metrics_by_id(snapshot)
    assert metrics["auto_advance_rate"].numerator == 1
    assert metrics["human_touch_count"].value == 1
    assert metrics["pr_human_review_count"].value == 1
    assert metrics["ci_success_rate"].value == "1 / 1"

    assert %{events: [%{"event_type" => "outcome_proof_snapshot"}]} = Analytics.read_events(path: path, max_events: :all)

    assert {:ok, duplicate} = OutcomeProof.collect(opts)
    assert duplicate.digest == snapshot.digest
    assert %{events: [_only]} = Analytics.read_events(path: path, max_events: :all)
  end

  test "collects project-name scopes and fails closed when default github proof is unavailable" do
    path = tmp_path("outcome-proof-project-name.ndjson")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")

    System.delete_env("GH_TOKEN")
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_project_slugs: nil,
      tracker_project_name: nil,
      tracker_project_names: ["symphony"]
    )

    linear_graphql = fn query, variables ->
      send(self(), {:linear_query, query, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-1",
                 "identifier" => "DEV-1",
                 "completedAt" => "2026-06-15T12:00:00Z",
                 "state" => %{"name" => "Done"},
                 "project" => %{"name" => "symphony"},
                 "comments" => %{"nodes" => []},
                 "stateHistory" => %{"nodes" => []},
                 "attachments" => %{
                   "nodes" => [%{"url" => "https://github.com/agavemindlab/symphony/pull/123"}]
                 }
               },
               %{
                 "id" => "issue-2",
                 "identifier" => "DEV-2",
                 "completedAt" => "2026-06-22T12:00:00Z",
                 "state" => %{"name" => "Done"},
                 "project" => %{"name" => "symphony"},
                 "comments" => %{"nodes" => []},
                 "stateHistory" => %{"nodes" => []},
                 "attachments" => nil
               }
             ]
           }
         }
       }}
    end

    assert {:ok, snapshot} =
             OutcomeProof.collect(
               path: path,
               linear_graphql: linear_graphql,
               collected_at: "2026-07-01T00:00:00Z",
               now: ~D[2026-07-01]
             )

    assert_receive {:linear_query, query, variables}
    assert query =~ "SymphonyOutcomeProofIssuesByProjectName"
    assert variables.projectName == "symphony"

    metrics = metrics_by_id(snapshot)
    assert metrics["pr_human_review_count"].status == "gap"
    assert metrics["ci_success_rate"].status == "gap"
  end

  test "collects non-terminal issues accepted by implementation approval replies" do
    path = tmp_path("outcome-proof-non-terminal-accepted.ndjson")

    linear_graphql = fn query, variables ->
      send(self(), {:linear_query, query, variables})

      nodes =
        if query =~ "✅ 已批准，进入 Deployment" and query =~ "parent: {body: {contains: \"## Implementation\"}}" do
          [
            %{
              "id" => "issue-accepted",
              "identifier" => "DEV-accepted",
              "completedAt" => nil,
              "updatedAt" => "2026-04-01T12:00:00Z",
              "state" => %{"name" => "Human Review"},
              "project" => %{"name" => "symphony"},
              "comments" => %{
                "nodes" => [
                  %{
                    "body" => "## Implementation",
                    "createdAt" => "2026-06-20T12:00:00Z",
                    "user" => %{"name" => "Symphony", "app" => true},
                    "botActor" => %{"name" => "Symphony"},
                    "children" => %{
                      "nodes" => [
                        %{
                          "body" => "✅ 已批准，进入 Deployment（2026-06-22 10:00:00 CST）",
                          "createdAt" => "2026-06-22T02:00:00Z",
                          "user" => %{"name" => "Symphony", "app" => true},
                          "botActor" => %{"name" => "Symphony"}
                        }
                      ]
                    }
                  }
                ]
              },
              "stateHistory" => %{"nodes" => []},
              "attachments" => %{"nodes" => []}
            },
            %{
              "id" => "issue-noise",
              "identifier" => "DEV-noise",
              "completedAt" => nil,
              "updatedAt" => "2026-06-22T12:00:00Z",
              "state" => %{"name" => "Human Review"},
              "project" => %{"name" => "symphony"},
              "comments" => %{
                "nodes" => [
                  %{
                    "body" => "✅ 已批准，进入 Deployment（standalone note, not a phase artifact）",
                    "createdAt" => "2026-06-22T03:00:00Z",
                    "user" => %{"name" => "Symphony", "app" => true},
                    "botActor" => %{"name" => "Symphony"},
                    "children" => %{"nodes" => []}
                  }
                ]
              },
              "stateHistory" => %{"nodes" => []},
              "attachments" => %{"nodes" => []}
            }
          ]
        else
          []
        end

      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}}
    end

    assert {:ok, snapshot} =
             OutcomeProof.collect(
               path: path,
               linear_graphql: linear_graphql,
               github_pull_request: fn url -> flunk("unexpected GitHub fetch for #{url}") end,
               collected_at: "2026-07-01T00:00:00Z",
               now: ~D[2026-07-01]
             )

    assert_receive {:linear_query, query, variables}
    assert query =~ "✅ 已批准，进入 Deployment"
    assert query =~ "parent: {body: {contains: \"## Implementation\"}}"
    assert variables.first == 201

    assert snapshot.accepted_issue_count == 1
    assert [%{week: "2026-W26", sample_count: 1}] = snapshot.cohorts

    metrics = metrics_by_id(snapshot)
    assert metrics["auto_advance_rate"].denominator == 1
  end

  test "returns linear collector errors without writing a proof snapshot" do
    path = tmp_path("outcome-proof-linear-error.ndjson")

    assert {:error, :linear_outcome_proof_payload} =
             OutcomeProof.collect(
               path: path,
               linear_graphql: fn _query, _variables -> {:ok, %{"data" => %{"issues" => %{}}}} end,
               now: ~D[2026-07-01]
             )

    assert %{events: []} = Analytics.read_events(path: path, max_events: :all)

    assert {:error, :linear_down} =
             OutcomeProof.collect(
               path: path,
               linear_graphql: fn _query, _variables -> {:error, :linear_down} end,
               now: ~D[2026-07-01]
             )
  end

  test "collects github proof only for retained capped accepted issues" do
    path = tmp_path("outcome-proof-github-cap.ndjson")

    issues =
      1..201
      |> Enum.map(fn index ->
        %{
          "id" => "issue-#{index}",
          "identifier" => "DEV-#{index}",
          "completedAt" => "2026-06-15T12:00:00Z",
          "state" => %{"name" => "Done"},
          "project" => %{"name" => "symphony"},
          "comments" => %{"nodes" => []},
          "stateHistory" => %{"nodes" => []},
          "attachments" => %{
            "nodes" => [%{"url" => "https://github.com/agavemindlab/symphony/pull/#{index}"}]
          }
        }
      end)

    linear_graphql = fn _query, _variables ->
      {:ok, %{"data" => %{"issues" => %{"nodes" => issues}}}}
    end

    github_pull_request = fn url ->
      send(self(), {:github_pull, url})
      {:ok, %{head_sha: "sha", reviews: [], comments: [], checks: []}}
    end

    assert {:ok, snapshot} =
             OutcomeProof.collect(
               path: path,
               linear_graphql: linear_graphql,
               github_pull_request: github_pull_request,
               collected_at: "2026-07-01T00:00:00Z",
               now: ~D[2026-07-01]
             )

    assert snapshot.accepted_issue_count == 200
    assert snapshot.truncated? == true

    Enum.each(1..200, fn _index ->
      assert_receive {:github_pull, _url}
    end)

    refute_receive {:github_pull, _url}, 10
  end

  test "builds accepted cohort lifecycle github and runtime proof metrics" do
    snapshot =
      OutcomeProof.snapshot(
        %{
          accepted_issues: [
            %{
              id: "issue-1",
              identifier: "DEV-1",
              project: "symphony",
              accepted_at: "2026-06-15T12:00:00Z",
              phase_closings: [%{kind: "auto_advance"}, %{kind: "human_approval"}],
              comments: [
                %{user: %{app: false}, bot_actor: nil},
                %{user: %{app: true}, bot_actor: %{name: "Symphony"}}
              ],
              state_spans: [
                %{
                  state: "Human Review",
                  started_at: "2026-06-15T10:00:00Z",
                  ended_at: "2026-06-15T11:30:00Z"
                },
                %{state: "Rework", started_at: "2026-06-15T11:30:00Z", ended_at: "2026-06-15T12:00:00Z"}
              ],
              clarification?: true,
              pull_request: %{
                head_sha: "abc123",
                reviews: [
                  %{author: %{login: "human-reviewer", type: "User"}, state: "APPROVED"},
                  %{author: %{login: "github-actions[bot]", type: "Bot"}, state: "APPROVED"},
                  %{author: %{login: "gl-swe", type: "User"}, state: "APPROVED"}
                ],
                comments: [%{author: %{login: "human-reviewer", type: "User"}}],
                checks: [%{sha: "abc123", conclusion: "success"}]
              }
            },
            %{
              id: "issue-2",
              identifier: "DEV-2",
              project: "symphony",
              accepted_at: "2026-06-22T12:00:00Z",
              phase_closings: [%{kind: "human_approval"}],
              comments: [],
              state_spans: [],
              pull_request: %{head_sha: "def456", reviews: [], comments: [], checks: [%{sha: "def456", conclusion: "failure"}]}
            }
          ],
          runtime_events: [
            %{
              "event_type" => "cost_snapshot",
              "issue_id" => "issue-1",
              "tokens" => %{"total_tokens" => 30},
              "recorded_at" => "2026-06-15T12:01:00Z"
            },
            %{"event_type" => "retry_scheduled", "issue_id" => "issue-1", "recorded_at" => "2026-06-15T12:02:00Z"},
            %{"event_type" => "blocked", "issue_id" => "issue-2", "recorded_at" => "2026-06-22T12:02:00Z"},
            %{
              "event_type" => "capacity_snapshot",
              "effective_capacity" => 4,
              "recorded_at" => "2026-06-15T12:03:00Z"
            },
            %{
              "event_type" => "capacity_snapshot",
              "effective_capacity" => 6,
              "recorded_at" => "2026-06-22T12:03:00Z"
            }
          ]
        },
        collected_at: "2026-07-01T00:00:00Z",
        now: ~D[2026-07-01],
        automated_reviewers: ["gl-swe"]
      )

    assert snapshot.event_type == "outcome_proof_snapshot"
    assert snapshot.accepted_issue_count == 2
    assert Enum.map(snapshot.cohorts, & &1.week) == ["2026-W25", "2026-W26"]
    assert snapshot.baseline.week == "2026-W25"
    assert snapshot.latest.week == "2026-W26"
    assert snapshot.trend.status == "direct"

    metrics = metrics_by_id(snapshot)

    assert metrics["auto_advance_rate"].numerator == 1
    assert metrics["auto_advance_rate"].denominator == 3
    assert metrics["human_touch_count"].value == 1
    assert metrics["human_review_wait_seconds"].value == 5_400
    assert metrics["clarification_rate"].numerator == 1
    assert metrics["rework_rate"].numerator == 1
    assert metrics["pr_human_review_count"].value == 2
    assert metrics["ci_success_rate"].numerator == 1
    assert metrics["ci_success_rate"].denominator == 2
    assert metrics["tokens_per_accepted_issue"].value == 15
    assert metrics["retry_denominator"].numerator == 1
    assert metrics["blocked_denominator"].numerator == 1
    assert metrics["capacity_trend"].value == "+2"
  end

  test "marks cohort trend partial when the accepted issue cap truncates the denominator" do
    accepted_issues =
      1..201
      |> Enum.map(fn index ->
        %{
          id: "issue-#{index}",
          identifier: "DEV-#{index}",
          project: "symphony",
          accepted_at: "2026-06-15T12:00:00Z",
          phase_closings: [],
          comments: [],
          state_spans: []
        }
      end)

    snapshot =
      OutcomeProof.snapshot(
        %{accepted_issues: accepted_issues, runtime_events: []},
        collected_at: "2026-07-01T00:00:00Z",
        now: ~D[2026-07-01]
      )

    assert snapshot.accepted_issue_count == 200
    assert snapshot.truncated? == true
    assert snapshot.trend.status == "partial"
    assert snapshot.trend.reason == "accepted_issue_cap_reached"
    assert "accepted_issue_cap_reached" in snapshot.data_quality.warnings
  end

  test "marks proof gaps and partial sources when durable denominators are incomplete" do
    empty_snapshot = OutcomeProof.snapshot(%{})
    assert empty_snapshot.accepted_issue_count == 0
    assert empty_snapshot.trend.status == "gap"
    assert "accepted_issue_denominator_empty" in empty_snapshot.data_quality.warnings
    assert metrics_by_id(empty_snapshot)["auto_advance_rate"].value == "denominator required"

    snapshot =
      OutcomeProof.snapshot(
        %{
          accepted_issues: [
            %{
              id: "issue-1",
              project: %{name: "symphony"},
              accepted_at: "2026-06-15T12:00:00Z",
              state: :done,
              phase_closings: [%{kind: :human_approval}],
              comments: [nil],
              state_spans: [
                %{state: "Human Review", started_at: "bad-date", ended_at: "2026-06-15T12:00:00Z"},
                %{state: nil, started_at: "2026-06-15T12:00:00Z", ended_at: "2026-06-15T12:01:00Z"},
                %{state: [], started_at: "2026-06-15T12:01:00Z", ended_at: "2026-06-15T12:02:00Z"},
                nil
              ],
              pull_request: %{
                head_sha: "abc123",
                reviews: [
                  %{author: %{login: :"bot-user", type: "Bot"}},
                  %{author: %{login: nil, type: "User"}}
                ],
                comments: [],
                checks: []
              }
            },
            %{
              id: "issue-2",
              project: nil,
              accepted_at: "2026-06-22T12:00:00Z",
              state: "Done",
              phase_closings: [],
              comments: [],
              state_spans: [],
              pull_request: nil
            },
            %{id: "issue-old", accepted_at: "2026-04-01T12:00:00Z", state: "Done"},
            %{id: "issue-invalid", accepted_at: "not-a-date", state: "Done"},
            %{id: "issue-canceled", accepted_at: "2026-06-22T12:00:00Z", state: "Canceled"}
          ],
          runtime_events: [
            %{"event_type" => "cost_snapshot", "issue_id" => "issue-1", "tokens" => %{"total_tokens" => "9"}},
            %{"event_type" => "cost_snapshot", "issue_id" => "issue-1", "tokens" => %{"total_tokens" => "bad"}},
            %{"event_type" => "cost_snapshot", "issue_id" => "issue-2"},
            %{"event_type" => "capacity_snapshot", "recorded_at" => nil},
            %{"event_type" => "capacity_snapshot", "effective_capacity" => 4.8, "recorded_at" => "2026-06-15T12:00:00Z"}
          ]
        },
        collected_at: "2026-07-01T00:00:00Z",
        now: ~D[2026-07-01],
        automated_reviewers: [:gl_swe, 123]
      )

    assert snapshot.accepted_issue_count == 2
    assert Enum.map(snapshot.cohorts, & &1.project) == ["symphony", "unknown"]

    metrics = metrics_by_id(snapshot)
    assert metrics["pr_human_review_count"].status == "partial"
    assert metrics["ci_success_rate"].status == "gap"
    assert metrics["tokens_per_accepted_issue"].value == 4
    assert metrics["capacity_trend"].status == "partial"
    assert metrics["human_review_wait_seconds"].value == 0
  end

  test "reports capacity drops and CI from checks without exact head sha" do
    snapshot =
      OutcomeProof.snapshot(
        %{
          accepted_issues: [
            %{
              id: "issue-1",
              project: "symphony",
              accepted_at: "2026-06-15T12:00:00Z",
              state: "Done",
              pull_request: %{head_sha: "", reviews: [], comments: [], checks: [%{sha: 123, conclusion: "skipped"}]}
            },
            %{id: "issue-2", project: "symphony", accepted_at: "2026-06-22T12:00:00Z", state: "Done", pull_request: nil}
          ],
          runtime_events: [
            %{"event_type" => "capacity_snapshot", "effective_capacity" => 6, "recorded_at" => "2026-06-15T12:00:00Z"},
            %{"event_type" => "capacity_snapshot", "effective_capacity" => 4, "recorded_at" => "2026-06-22T12:00:00Z"}
          ]
        },
        collected_at: "2026-07-01T00:00:00Z",
        now: ~D[2026-07-01]
      )

    metrics = metrics_by_id(snapshot)
    assert metrics["ci_success_rate"].value == "1 / 1"
    assert metrics["capacity_trend"].value == "-2"
  end

  defp metrics_by_id(snapshot) do
    Map.new(snapshot.metrics, &{&1.id, &1})
  end

  defp tmp_path(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-outcome-proof-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, name)
  end
end
