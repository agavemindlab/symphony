defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20
    assert config.hooks.issue_running == nil
    assert config.hooks.issue_stopped == nil

    assert :ok =
             SymphonyElixir.IssueRunHook.run(:running, %Issue{
               id: "issue-no-hook",
               identifier: "MT-NO-HOOK",
               title: "No hook",
               state: "In Progress"
             })

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_scope} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: [" project-a ", "project-b", "project-a"]
    )

    assert :ok = Config.validate!()
    assert Config.settings!().tracker.project_slug == nil
    assert Config.settings!().tracker.project_slugs == ["project-a", "project-b"]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_names: [" Project A ", "Project B", "Project A"]
    )

    assert :ok = Config.validate!()
    assert Config.settings!().tracker.project_names == ["Project A", "Project B"]

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_project_slugs: ["project-b"]
    )

    assert {:error, :conflicting_linear_project_slug_config} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil,
      tracker_project_slugs: ["project-a", " "]
    )

    assert {:error, {:invalid_linear_project_slugs, :blank}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.set_workflow_file_path(Path.expand("../workflows/symphony/WORKFLOW.md", File.cwd!()))

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert Map.get(tracker, "project_slug") == "$SYMPHONY_PROJECT_SLUG"
    assert Map.get(tracker, "project_slugs") == "$SYMPHONY_PROJECT_SLUGS"
    assert Map.get(tracker, "project_name") == "$SYMPHONY_PROJECT_NAME"
    assert Map.get(tracker, "project_names") == "$SYMPHONY_PROJECT_NAMES"
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "project_workflow_dir="
    assert Map.get(hooks, "after_create") =~ "\"$project_workflow_dir/setup.sh\""
    assert Map.get(hooks, "after_create") =~ "\"$project_workflow_dir/skills\""
    assert Map.get(hooks, "after_create") =~ ".git/info/exclude"
    assert Map.get(hooks, "before_remove") =~ "\"$project_workflow_dir/teardown.sh\""

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
    assert prompt =~ "## Phase Map"
    assert prompt =~ "| Requirements | `phase-requirements` |"
    assert prompt =~ "| Design | `phase-design` |"
    assert prompt =~ "| Implementation | `phase-implementation` |"
    assert prompt =~ "| Deployment | `phase-deployment` |"
    assert prompt =~ "## Main Flow"
    assert prompt =~ "Open and follow `.agents/skills/symphony-linear/SKILL.md`"
    assert prompt =~ "create `.symphony/stop-after-turn`"
    assert prompt =~ "Do **not** open the next phase skill in this session"
    assert prompt =~ "### Rework cycle (same phase)"
    assert prompt =~ "Requirements rework must also state"
    assert prompt =~ "reachable only via `Merging`"
    assert prompt =~ "retain each comment's `parent { id }`"
    assert prompt =~ "reply node as standalone top-level feedback"
    assert prompt =~ "## Phase Artifact Protocol"
    assert prompt =~ "Each phase artifact version is a top-level Linear comment"
    assert prompt =~ "clarification-answer resume"
    assert prompt =~ "fresh top-level artifact"
    refute prompt =~ "posts or updates its own artifact"
    refute prompt =~ "exactly one top-level comment"
    refute prompt =~ "updates the existing one in place via `commentUpdate`"
    assert prompt =~ "## Workpad"
    assert prompt =~ "⏩ 自动进入 [Next Phase]"
    assert prompt =~ "✅ 已批准，进入 [Next Phase]"
    assert prompt =~ ">>> 🛠️ 本次激活的 skills"
    assert prompt =~ "Implementation never auto-advances"
    assert prompt =~ "Deployment only via `Merging`"
    assert prompt =~ "## 建议新建 issue"
    assert prompt =~ "Do **not** use GitHub-style"
    assert prompt =~ "Phase Artifact Protocol"
    assert prompt =~ "Rework cycle"
    assert prompt =~ "Cross-phase rework"
    assert prompt =~ "Agent never moves to `Done`"
    assert prompt =~ "**`Human Review` is not an agent state**"
    assert prompt =~ "collapsible sections (`>>>`)"
    assert prompt =~ "Skills-activated footer"
    assert prompt =~ "Codex session id"
    assert prompt =~ "CODEX_THREAD_ID"
    refute prompt =~ "symphony_session_context"
    assert prompt =~ "`n/a`"
    assert length(String.split(prompt, "---")) >= 4

    phase_skill_paths = [
      "../workflows/agavemindlab/skills/phase-requirements/SKILL.md",
      "../workflows/agavemindlab/skills/phase-design/SKILL.md",
      "../workflows/agavemindlab/skills/phase-implementation/SKILL.md",
      "../workflows/agavemindlab/skills/phase-deployment/SKILL.md"
    ]

    for phase_skill_path <- phase_skill_paths do
      phase_skill = File.read!(Path.expand(phase_skill_path, File.cwd!()))

      assert phase_skill =~ ">>> 🛠️ 本次激活的 skills"
      assert phase_skill =~ "- Codex session id: `<session_id | n/a>`"
    end
  end

  test "requirements skill publishes reworked clarification artifacts through workflow protocol" do
    workflow =
      File.read!(Path.expand("../workflows/agavemindlab/WORKFLOW.md", File.cwd!()))

    skill =
      File.read!(Path.expand("../workflows/agavemindlab/skills/phase-requirements/SKILL.md", File.cwd!()))

    assert workflow =~ "clarification-answer resume"
    assert workflow =~ "same-phase Rework cycle"
    assert workflow =~ "even if the Linear state is `In Progress`"
    assert workflow =~ "post a fresh top-level artifact"
    assert skill =~ "workflow artifact protocol"
    assert skill =~ "not the old comment body"
    refute skill =~ "Post (or update) the `## Requirements` artifact"
    refute skill =~ "Post or update the artifact comment."
    refute skill =~ "Post or update the `## Requirements` artifact"
  end

  test "design skill publishes reworked clarification artifacts through workflow protocol" do
    skill =
      File.read!(Path.expand("../workflows/agavemindlab/skills/phase-design/SKILL.md", File.cwd!()))

    assert skill =~ "workflow artifact protocol"
    assert skill =~ "not the old comment body"
    refute skill =~ "Post or update the artifact comment."
    refute skill =~ "Post or update the `## Design` artifact"
  end

  test "cross-phase rollback supersedes stale target-through-awaiting artifacts" do
    workflow = shared_workflow_prompt()

    implementation_skill =
      File.read!(Path.expand("../workflows/agavemindlab/skills/phase-implementation/SKILL.md", File.cwd!()))

    artifacts = [
      %{id: "stale-requirements", phase: "Requirements", kind: :phase_artifact, invalidated?: true},
      %{id: "stale-design", phase: "Design", kind: :phase_artifact, invalidated?: true},
      %{
        id: "approved-still-referenced-design",
        phase: "Design",
        kind: :phase_artifact,
        invalidated?: false
      },
      %{id: "stale-implementation", phase: "Implementation", kind: :phase_artifact, invalidated?: true},
      %{id: "standalone-human-feedback", kind: :human_feedback, invalidated?: true}
    ]

    calls = dry_run_artifact_calls(workflow, :cross_phase_rollback, "Requirements", "Implementation", artifacts)
    resolved_ids = resolved_comment_ids(calls)

    assert resolved_ids == ["stale-requirements", "stale-design", "stale-implementation"]
    refute "approved-still-referenced-design" in resolved_ids
    refute "standalone-human-feedback" in resolved_ids
    assert {:commentCreate, :top_level_phase_artifact, "## Requirements"} in calls

    active_requirements =
      calls
      |> active_artifacts_after_rollback(artifacts, %{
        id: "new-requirements",
        phase: "Requirements",
        kind: :phase_artifact
      })
      |> Enum.filter(&(&1.phase == "Requirements"))

    assert Enum.map(active_requirements, & &1.id) == ["new-requirements"]
    assert implementation_skill =~ "target phase through Implementation"
    assert implementation_skill =~ "including stale same-phase target artifacts"
  end

  test "DEV-5321 style clarification resume fixture publishes a fresh artifact version" do
    workflow = shared_workflow_prompt()

    old_artifact = %{
      id: "80905809-e1e6-4ff6-a275-c94c2415e7ce",
      created_at: ~U[2026-06-20 01:00:00Z]
    }

    for phase <- ["Requirements", "Design"] do
      new_artifact = fresh_artifact_version(old_artifact)
      calls = dry_run_artifact_calls(workflow, :clarification_answer, phase, old_artifact)

      assert calls == [
               {:commentResolve, old_artifact.id},
               {:commentCreate, :top_level_phase_artifact, "## #{phase}"},
               {:commentCreate, {:reply_to_new_artifact, new_artifact.id}, "clarification summary"}
             ]

      assert new_artifact.id != old_artifact.id
      assert DateTime.compare(new_artifact.created_at, old_artifact.created_at) == :gt
      refute_called_comment_update_for_artifact(calls, old_artifact.id)
    end
  end

  test "DEV-5338 style question discussion fixture replies without rewriting artifacts" do
    workflow = shared_workflow_prompt()
    artifact = %{id: "requirements-question-thread", created_at: ~U[2026-06-23 01:00:00Z]}

    calls = dry_run_artifact_calls(workflow, :question_discussion, "Requirements", artifact)

    assert calls == [{:commentCreate, {:reply_to_artifact, artifact.id}, "answer Requirements question"}]
    refute Enum.any?(calls, fn {operation, _, _} -> operation in [:commentResolve, :commentUpdate] end)

    refute Enum.any?(calls, fn
             {:commentCreate, :top_level_phase_artifact, _body} -> true
             _ -> false
           end)
  end

  test "aggregate dispatch ordering interleaves projects" do
    issues = [
      dispatch_issue("grotto-1", "DEV-1001", "grotto", ~U[2026-01-01 00:00:00Z]),
      dispatch_issue("grotto-2", "DEV-1002", "grotto", ~U[2026-01-02 00:00:00Z]),
      dispatch_issue("symphony-1", "DEV-2001", "symphony", ~U[2026-01-03 00:00:00Z]),
      dispatch_issue("voxvault-1", "DEV-3001", "voxvault", ~U[2026-01-04 00:00:00Z])
    ]

    assert issues
           |> Orchestrator.sort_issues_for_dispatch_for_test()
           |> Enum.map(& &1.identifier) == [
             "DEV-1001",
             "DEV-2001",
             "DEV-3001",
             "DEV-1002"
           ]
  end

  test "shared phase prompts explain rework handoff gates" do
    repo_root = Path.expand("..", File.cwd!())
    workflow = File.read!(Path.join(repo_root, "workflows/agavemindlab/WORKFLOW.md"))

    assert workflow =~ "当前停在 `Human Review`"
    assert workflow =~ "下游 Design/Implementation/PR 还未按本轮 artifact 更新"

    requirements_skill =
      File.read!(Path.join(repo_root, "workflows/agavemindlab/skills/phase-requirements/SKILL.md"))

    design_skill =
      File.read!(Path.join(repo_root, "workflows/agavemindlab/skills/phase-design/SKILL.md"))

    refute requirements_skill =~ "opens `phase-design` in the same session"
    refute design_skill =~ "opens `phase-implementation` in the same session"
  end

  test "phase artifact templates keep decisions visible and details folded" do
    implementation_skill =
      File.read!(Path.expand("../workflows/agavemindlab/skills/phase-implementation/SKILL.md", File.cwd!()))

    implementation_visible =
      implementation_skill
      |> String.split(">>> 🧩 本轮实现细节（默认折叠）", parts: 2)
      |> hd()

    for section <- [
          "### 结论",
          "### Root cause / recommendation",
          "### Human action needed"
        ] do
      assert implementation_visible =~ section
    end

    for folded_section <- [
          "### 本轮变化",
          "### Rework 已回应",
          "### 验证结论",
          "### Acceptance mapping",
          "### 合并风险判断",
          "### Merge 后验证"
        ] do
      refute implementation_visible =~ folded_section
      assert implementation_skill =~ folded_section
    end

    for folded_marker <- [
          ">>> 🧩 本轮实现细节（默认折叠）",
          ">>> ✅ 验证与验收（默认折叠）",
          ">>> 🔎 审计证据（默认折叠）"
        ] do
      assert implementation_skill =~ folded_marker
    end

    for evidence <- [
          "Source comment:",
          "Automated review:",
          "不等于人工批准",
          "S2 direct verification",
          "S1 post-deploy close test",
          "Current-main compatibility"
        ] do
      assert implementation_skill =~ evidence
    end

    for merge_risk_contract <- [
          "### 合并风险判断",
          "required: 2-3 bullets",
          "漏 bug 最坏影响",
          "服务故障 / 数据损坏 / 权限隐私 / 不可逆状态",
          "低风险也必须说明为什么低风险",
          "缓解措施或 Deployment 验证"
        ] do
      assert implementation_skill =~ merge_risk_contract
    end

    design_skill =
      File.read!(Path.expand("../workflows/agavemindlab/skills/phase-design/SKILL.md", File.cwd!()))

    design_visible =
      design_skill
      |> String.split(">>> 🧩 设计细节（默认折叠）", parts: 2)
      |> hd()

    assert design_visible =~ "### 图示"
    assert design_visible =~ "### 风险/注意"
    refute design_visible =~ "### 验收方案"
    assert design_skill =~ ">>> 🧩 设计细节（默认折叠）"
    assert design_skill =~ ">>> ✅ 验收方案（默认折叠）"
  end

  test "maestro reviewer requests changes for missing or stale merge risk judgment" do
    reviewer =
      File.read!(Path.expand("../.codex/skills/maestro/agents/maestro-reviewer.md", File.cwd!()))

    for contract <- [
          "合并风险判断",
          "缺少合并风险判断",
          "PR diff / evidence",
          "request changes"
        ] do
      assert reviewer =~ contract
    end
  end

  test "maestro reviewer challenges undersized retention windows for trend claims" do
    reviewer =
      File.read!(Path.expand("../.codex/skills/maestro/agents/maestro-reviewer.md", File.cwd!()))

    for contract <- [
          "retention window",
          "long-term",
          "large enough",
          "request changes or ask clarification"
        ] do
      assert reviewer =~ contract
    end
  end

  test "maestro resumes human answers to clarification markers through active state" do
    launcher = File.read!(Path.expand("../.codex/skills/maestro/SKILL.md", File.cwd!()))

    reviewer =
      File.read!(Path.expand("../.codex/skills/maestro/agents/maestro-reviewer.md", File.cwd!()))

    assert launcher =~ "clarification-answer resume"
    assert launcher =~ "set the issue to `In Progress`"
    assert reviewer =~ "clarification answer already exists"
    assert reviewer =~ "not phase approval"
  end

  test "maestro reviewer does not overstate readback as regression verification" do
    reviewer =
      File.read!(Path.expand("../.codex/skills/maestro/agents/maestro-reviewer.md", File.cwd!()))

    for contract <- [
          "merged-file readback",
          "Linear relation checks",
          "regression verification/evidence",
          "command, log, test, or manual exercise"
        ] do
      assert reviewer =~ contract
    end
  end

  test "maestro reviewer blocks Done when required regression validation is missing" do
    reviewer =
      File.read!(Path.expand("../.codex/skills/maestro/agents/maestro-reviewer.md", File.cwd!()))

    for contract <- [
          "required regression validation",
          "回归例",
          "historical issue",
          "sole evidence",
          "workflow path",
          "existing Linear state",
          "readback satisfies",
          "readback-only risk",
          "bundled `S1-S6`",
          "separate evidence",
          "close-test gap",
          "request changes",
          "not completion",
          "Readback cannot satisfy it",
          "manual exercise of the affected behavior"
        ] do
      assert reviewer =~ contract
    end
  end

  test "maestro launcher task repeats required regression validation gate" do
    skill = File.read!(Path.expand("../.codex/skills/maestro/SKILL.md", File.cwd!()))

    for contract <- [
          "required",
          "regression validation",
          "回归例",
          "historical issue",
          "workflow path",
          "readback-only risk",
          "bundled `S1-S6`",
          "command, log, test, or manual exercise",
          "request changes instead of completion",
          "confirmation"
        ] do
      assert skill =~ contract
    end
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load preserves UTF-8 prompt text after front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UTF8_WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: linear
    ---
    ## Review Handoff

    审核重点（仅 PR review；否则省略）:
    - 已回应的问题需要保留完整中文字符。

    Ticket {{ issue.identifier }}: {{ issue.title }}
    """)

    assert {:ok, %{prompt_template: prompt_template}} = Workflow.load(workflow_path)
    assert String.valid?(prompt_template)

    issue = %Issue{
      id: "issue-utf8",
      identifier: "DEV-UTF8",
      title: "中文标题",
      description: "中文描述",
      state: "In Progress"
    }

    Workflow.set_workflow_file_path(workflow_path)
    prompt = PromptBuilder.build_prompt(issue)

    assert String.valid?(prompt)
    assert prompt =~ "审核重点"
    assert prompt =~ "中文标题"
    assert {:ok, _json} = Jason.encode(%{"text" => prompt})
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "human review reconcile starts maestro pre-review before stopping active agent" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])
    SymphonyElixir.MaestroPreReview.reset_handoff_claims_for_test()

    parent = self()
    issue_id = "issue-human-review-reconcile"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pre_review_runner = fn issue, opts ->
      send(parent, {:maestro_pre_review, issue.identifier, issue.state, opts[:worker_host]})
      :ok
    end

    state =
      %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: "MT-HUMAN-REVIEW",
            issue: %Issue{
              id: issue_id,
              identifier: "MT-HUMAN-REVIEW",
              state: "In Progress",
              labels: ["symphony"]
            },
            worker_host: nil,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }
      |> Map.put(:maestro_pre_review_runner, pre_review_runner)

    issue = %Issue{
      id: issue_id,
      identifier: "MT-HUMAN-REVIEW",
      state: "Human Review",
      title: "Ready for review",
      description: "Stopped by reconciliation",
      labels: ["symphony"]
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert_receive {:maestro_pre_review, "MT-HUMAN-REVIEW", "Human Review", nil}
    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "maestro pre-review handoff claim is shared across launch paths" do
    SymphonyElixir.MaestroPreReview.reset_handoff_claims_for_test()

    handoff_at = DateTime.from_naive!(~N[2026-06-25 10:00:00], "Etc/UTC")

    issue = %Issue{
      id: "issue-shared-maestro-claim",
      identifier: "MT-SHARED-MAESTRO",
      state: "Human Review",
      labels: ["symphony"],
      updated_at: handoff_at
    }

    assert SymphonyElixir.MaestroPreReview.claim_handoff_for_test(issue)
    refute SymphonyElixir.MaestroPreReview.claim_handoff_for_test(issue)

    next_handoff = %{issue | updated_at: DateTime.add(handoff_at, 60)}
    assert SymphonyElixir.MaestroPreReview.claim_handoff_for_test(next_handoff)
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-marker-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(marker) end)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_issue_stopped: "printf '%s|%s|%s' \"$SYMPHONY_HOOK_EVENT\" \"$SYMPHONY_HOOK_REASON\" \"$SYMPHONY_ISSUE_IDENTIFIER\" > #{marker}"
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
      assert File.read!(marker) == "stopped|terminal_state|MT-556"
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue reconcile stops agent and cleans workspace when issue stopped hook times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-timeout-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-terminal-timeout"
    issue_identifier = "MT-TERMINAL-TIMEOUT"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Closed"],
        hook_issue_stopped: "sleep 1",
        hook_timeout_ms: 10
      )

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        labels: []
      }

      parent = self()

      log =
        capture_log(fn ->
          updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
          send(parent, {:terminal_timeout_state, updated_state})
        end)

      assert_receive {:terminal_timeout_state, updated_state}
      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
      assert log =~ "Issue run hook timed out"
      assert log =~ "hook=issue_stopped"
      assert log =~ "timeout_ms=10"
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "retry releases its claim when issue has a non-terminal blocker" do
    issue_id = "retry-blocked"

    state = %Orchestrator.State{
      max_concurrent_agents: 0,
      running: %{},
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-566",
      title: "Retry blocked by dependency",
      state: "In Progress",
      blocked_by: [%{id: "blocker-4", identifier: "MT-567", state: "In Progress"}]
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "agent runner does not continue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-label-continuation",
      identifier: "MT-563",
      title: "Stop after opt-out",
      state: "In Progress",
      labels: ["symphony"]
    }

    refreshed_issue = %{issue | labels: []}
    fetcher = fn ["issue-label-continuation"] -> {:ok, [refreshed_issue]} end

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "dispatch writes issue running marker hook after claim" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-running-marker-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(marker) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "printf '%s|%s|%s|%s' \"$SYMPHONY_HOOK_EVENT\" \"$SYMPHONY_HOOK_REASON\" \"$SYMPHONY_ISSUE_IDENTIFIER\" \"${SYMPHONY_WORKER_HOST:-}\" > #{marker}"
    )

    parent = self()

    start_child = fn _fun ->
      pid =
        spawn(fn ->
          send(parent, :fake_agent_started)

          receive do
            :stop -> :ok
          end
        end)

      {:ok, pid}
    end

    issue = %Issue{
      id: "issue-running-hook",
      identifier: "MT-RUNNING",
      title: "Running hook",
      state: "In Progress",
      url: "https://linear.example/MT-RUNNING"
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      max_concurrent_agents: 10
    }

    updated_state = Orchestrator.dispatch_issue_for_test(state, issue, start_child)

    assert_receive :fake_agent_started
    assert Map.has_key?(updated_state.running, "issue-running-hook")
    assert MapSet.member?(updated_state.claimed, "issue-running-hook")
    assert File.read!(marker) == "running|dispatch|MT-RUNNING|"
  end

  test "dispatch claims issue and starts agent when issue running hook fails" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "printf 'marker failed' && exit 17"
    )

    parent = self()

    start_child = fn _fun ->
      pid =
        spawn(fn ->
          send(parent, :fake_agent_started_after_hook_failure)

          receive do
            :stop -> :ok
          end
        end)

      {:ok, pid}
    end

    issue = %Issue{
      id: "issue-running-hook-fails",
      identifier: "MT-RUNNING-FAIL",
      title: "Running hook failure",
      state: "In Progress"
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      max_concurrent_agents: 10
    }

    log =
      capture_log(fn ->
        updated_state = Orchestrator.dispatch_issue_for_test(state, issue, start_child)
        send(parent, {:dispatch_state_after_hook_failure, updated_state})
      end)

    assert_receive :fake_agent_started_after_hook_failure
    assert_receive {:dispatch_state_after_hook_failure, updated_state}
    assert Map.has_key?(updated_state.running, "issue-running-hook-fails")
    assert MapSet.member?(updated_state.claimed, "issue-running-hook-fails")
    assert log =~ "Issue run hook failed"
    assert log =~ "hook=issue_running"
    assert log =~ "status=17"
  end

  test "dispatch claims issue and starts agent when issue running hook times out" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_running: "sleep 1",
      hook_timeout_ms: 10
    )

    parent = self()

    start_child = fn _fun ->
      pid =
        spawn(fn ->
          send(parent, :fake_agent_started_after_hook_timeout)

          receive do
            :stop -> :ok
          end
        end)

      {:ok, pid}
    end

    issue = %Issue{
      id: "issue-running-hook-timeout",
      identifier: "MT-RUNNING-TIMEOUT",
      title: "Running hook timeout",
      state: "In Progress"
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      max_concurrent_agents: 10
    }

    log =
      capture_log(fn ->
        updated_state = Orchestrator.dispatch_issue_for_test(state, issue, start_child)
        send(parent, {:dispatch_state_after_hook_timeout, updated_state})
      end)

    assert_receive :fake_agent_started_after_hook_timeout
    assert_receive {:dispatch_state_after_hook_timeout, updated_state}
    assert Map.has_key?(updated_state.running, "issue-running-hook-timeout")
    assert MapSet.member?(updated_state.claimed, "issue-running-hook-timeout")
    assert log =~ "Issue run hook timed out"
    assert log =~ "hook=issue_running"
    assert log =~ "timeout_ms=10"
  end

  test "normal worker exit writes issue stopped marker hook before continuation retry" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stopped-marker-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(marker) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_stopped: "printf '%s|%s|%s' \"$SYMPHONY_HOOK_EVENT\" \"$SYMPHONY_HOOK_REASON\" \"$SYMPHONY_ISSUE_IDENTIFIER\" > #{marker}"
    )

    issue_id = "issue-stopped-hook"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :IssueStoppedHookOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-STOPPED",
      issue: %Issue{
        id: issue_id,
        identifier: "MT-STOPPED",
        title: "Stopped hook",
        state: "In Progress"
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    assert File.read!(marker) == "stopped|agent_down_normal|MT-STOPPED"
    refute Map.has_key?(:sys.get_state(pid).running, issue_id)
  end

  test "normal worker exit schedules continuation retry when issue stopped hook fails" do
    write_workflow_file!(Workflow.workflow_file_path(),
      hook_issue_stopped: "printf 'stop marker failed' && exit 19"
    )

    issue_id = "issue-stopped-hook-fails"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :IssueStoppedHookFailureOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-STOPPED-FAIL",
      issue: %Issue{
        id: issue_id,
        identifier: "MT-STOPPED-FAIL",
        title: "Stopped hook failure",
        state: "In Progress"
      },
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_retry_ms = System.monotonic_time(:millisecond)

    log =
      capture_log(fn ->
        send(pid, {:DOWN, ref, :process, self(), :normal})
        Process.sleep(50)
      end)

    state = :sys.get_state(pid)
    after_retry_ms = System.monotonic_time(:millisecond)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert_due_in_range(due_at_ms, before_retry_ms, after_retry_ms, 500, 1_100)
    assert log =~ "Issue run hook failed"
    assert log =~ "hook=issue_stopped"
    assert log =~ "status=19"
  end

  test "orchestrator startup cleanup clears stale markers for active and terminal issues" do
    previous_running_label = System.get_env("SYMPHONY_RUNNING_LABEL")
    System.put_env("SYMPHONY_RUNNING_LABEL", "symphony:running:default")
    on_exit(fn -> restore_env("SYMPHONY_RUNNING_LABEL", previous_running_label) end)

    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-startup-marker-cleanup-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(marker) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"],
      hook_issue_stopped: "printf '%s|%s\\n' \"$SYMPHONY_HOOK_REASON\" \"$SYMPHONY_ISSUE_IDENTIFIER\" >> #{marker}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "active-1",
        identifier: "MT-ACTIVE",
        title: "Active",
        state: "In Progress",
        labels: ["symphony:running:default"]
      },
      %Issue{
        id: "done-1",
        identifier: "MT-DONE",
        title: "Done",
        state: "Done",
        labels: ["symphony:running:default"]
      },
      %Issue{id: "other-1", identifier: "MT-OTHER", title: "Other", state: "Backlog"}
    ])

    orchestrator_name = Module.concat(__MODULE__, :StartupMarkerCleanupOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    Process.sleep(50)

    assert marker |> File.read!() |> String.split("\n", trim: true) |> Enum.sort() == [
             "startup_recovery|MT-ACTIVE",
             "startup_recovery|MT-DONE"
           ]
  end

  test "orchestrator startup cleanup prints progress" do
    previous_running_label = System.get_env("SYMPHONY_RUNNING_LABEL")
    System.put_env("SYMPHONY_RUNNING_LABEL", "symphony:running:default")
    on_exit(fn -> restore_env("SYMPHONY_RUNNING_LABEL", previous_running_label) end)

    previous_progress = Application.get_env(:symphony_elixir, :startup_cleanup_progress)
    Application.put_env(:symphony_elixir, :startup_cleanup_progress, true)
    on_exit(fn -> restore_app_env(:startup_cleanup_progress, previous_progress) end)

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-startup-cleanup-progress-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)
    File.mkdir_p!(Path.join(workspace_root, "MT-DONE"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"],
      hook_issue_stopped: "true"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "done-1",
        identifier: "MT-DONE",
        title: "Done",
        state: "Done",
        labels: ["symphony:running:default"]
      },
      %Issue{
        id: "todo-1",
        identifier: "MT-TODO",
        title: "Todo",
        state: "Todo",
        labels: ["symphony:running:default"]
      },
      %Issue{id: "old-1", identifier: "MT-OLD", title: "Old", state: "Done"}
    ])

    orchestrator_name = Module.concat(__MODULE__, :StartupCleanupProgressOrchestrator)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

    assert output =~ "startup cleanup: terminal workspaces"
    assert output =~ "startup cleanup: terminal workspaces 1/1 MT-DONE"
    assert output =~ "startup cleanup: issue markers 1/2 MT-DONE"
    assert output =~ "startup cleanup: issue markers 2/2 MT-TODO"
    assert output =~ "startup cleanup: done"
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_retry_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)
    after_retry_ms = System.monotonic_time(:millisecond)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, before_retry_ms, after_retry_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_retry_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)
    after_retry_ms = System.monotonic_time(:millisecond)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, before_retry_ms, after_retry_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    before_retry_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)
    after_retry_ms = System.monotonic_time(:millisecond)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, before_retry_ms, after_retry_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, before_retry_ms, after_retry_ms, min_delay_ms, max_delay_ms) do
    assert due_at_ms >= before_retry_ms + min_delay_ms
    assert due_at_ms <= after_retry_ms + max_delay_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "linear client polls each configured project and dedupes combined issues" do
    raw_issue = fn issue_id, identifier, project_slug ->
      %{
        "id" => issue_id,
        "identifier" => identifier,
        "title" => "Issue #{identifier}",
        "description" => "Project #{project_slug}",
        "state" => %{"name" => "Todo"},
        "project" => %{
          "id" => "project-#{project_slug}",
          "slugId" => project_slug,
          "name" => "Project #{project_slug}"
        },
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []},
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => "2026-01-02T00:00:00Z"
      }
    end

    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:linear_poll, query, variables})

      nodes =
        case variables.projectSlug do
          "project-a" ->
            [
              raw_issue.("issue-a", "MT-A", "project-a"),
              raw_issue.("issue-shared", "MT-SHARED", "project-a")
            ]

          "project-b" ->
            [
              raw_issue.("issue-shared", "MT-SHARED", "project-b"),
              raw_issue.("issue-b", "MT-B", "project-b")
            ]
        end

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, issues} =
             Client.fetch_issues_by_states_for_test(["project-a", "project-b"], ["Todo"], graphql_fun)

    assert Enum.map(issues, & &1.id) == ["issue-a", "issue-shared", "issue-b"]
    assert Enum.map(issues, & &1.project.slug_id) == ["project-a", "project-a", "project-b"]

    assert_receive {:linear_poll, query, %{projectSlug: "project-a", stateNames: ["Todo"]}}
    assert query =~ "project {"
    assert query =~ "slugId"
    assert_receive {:linear_poll, ^query, %{projectSlug: "project-b", stateNames: ["Todo"]}}
  end

  test "linear client can poll configured project names" do
    raw_issue = fn issue_id, identifier, project_name ->
      %{
        "id" => issue_id,
        "identifier" => identifier,
        "title" => "Issue #{identifier}",
        "description" => "Project #{project_name}",
        "state" => %{"name" => "Todo"},
        "project" => %{
          "id" => "project-#{project_name}",
          "slugId" => String.downcase(project_name),
          "name" => project_name
        },
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []},
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => "2026-01-02T00:00:00Z"
      }
    end

    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:linear_poll, query, variables})

      nodes =
        case variables.projectName do
          "grotto" -> [raw_issue.("issue-a", "MT-A", "grotto")]
          "symphony" -> [raw_issue.("issue-b", "MT-B", "symphony")]
        end

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, issues} =
             Client.fetch_issues_by_project_names_for_test(["grotto", "symphony"], ["Todo"], graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-A", "MT-B"]

    assert_receive {:linear_poll, query, %{projectName: "grotto", stateNames: ["Todo"]}}
    assert query =~ "project {"
    assert query =~ "name"
    assert_receive {:linear_poll, ^query, %{projectName: "symphony", stateNames: ["Todo"]}}
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders Linear project context" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Project {{ issue.project.slug_id }} id={{ issue.project.id }} name={{ issue.project.name }}"
    )

    issue = %Issue{
      identifier: "S-2",
      title: "Route by project",
      description: "Project context should render",
      state: "Todo",
      url: "https://example.org/issues/S-2",
      project: %{id: "project-id", slug_id: "project-slug", name: "Project Name"}
    }

    assert PromptBuilder.build_prompt(issue) == "Project project-slug id=project-id name=Project Name"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("../workflows/symphony/WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended Symphony orchestration session."
    assert prompt =~ "Stop early only for a true blocker"
    assert prompt =~ "Do not include generic \"next steps for user\""
    assert prompt =~ "unresolved Phase artifacts"
    assert prompt =~ "most recent unresolved artifact with no closing reply"
    assert prompt =~ "Open and follow `.agents/skills/symphony-linear/SKILL.md`"
    assert prompt =~ "When the target phase is a rework of its own artifact"
    assert prompt =~ "Requirements rework must also state"
    assert prompt =~ "reachable only via `Merging`"
    assert prompt =~ ".symphony/stop-after-turn"
    assert prompt =~ "Codex session id"
    assert prompt =~ "CODEX_THREAD_ID"
    refute prompt =~ "symphony_session_context"
    assert prompt =~ "`n/a`"
    assert prompt =~ "## Phase Map"
    assert prompt =~ "## Main Flow"
    assert prompt =~ "Scan **every** unresolved artifact"
    assert prompt =~ "inspect each artifact's `children` / thread replies"
    assert prompt =~ "retain each comment's `parent { id }`"
    assert prompt =~ "reply node as standalone top-level feedback"
    assert prompt =~ "feedback keeps the phase intent of that artifact"
    assert prompt =~ "Implementation → Deployment is gated by `Merging`"
    assert prompt =~ "open the matching phase skill"
    assert prompt =~ ".agents/skills/symphony-linear/SKILL.md"
    assert prompt =~ "## Phase Map"
    assert prompt =~ "## Main Flow"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"

    refute "Human Review" in Config.settings!().tracker.active_states
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "maestro pre-review prompt preserves human review gate semantics" do
    issue = %Issue{
      id: "issue-maestro-prompt",
      identifier: "MT-5316",
      title: "Use Maestro before human review",
      description: "Pre-review handoff",
      state: "Human Review",
      url: "https://example.org/issues/MT-5316",
      labels: ["symphony"]
    }

    prompt = SymphonyElixir.MaestroPreReview.build_prompt_for_test(issue)

    assert prompt =~ "$maestro MT-5316"
    assert prompt =~ "fresh Codex session"
    assert prompt =~ "Do not reuse the working agent"
    assert prompt =~ "dedicated Maestro Linear OAuth app"
    assert prompt =~ "without using any fallback identity"
    assert prompt =~ "request changes"
    assert prompt =~ "Rework"
    assert prompt =~ "approve"
    assert prompt =~ "0-10"
    assert prompt =~ "keep the issue in `Human Review`"
    assert prompt =~ "same current artifact/head"
    assert prompt =~ "already contains a Maestro pre-review reply"
    assert prompt =~ "record a short no-action reason"
    assert prompt =~ "evidence is unavailable"
    refute prompt =~ "✅ 已批准"

    assert SymphonyElixir.MaestroPreReview.workspace_identifier_for_test(issue) == "MT-5316-maestro"
    assert SymphonyElixir.MaestroPreReview.prepare_main_branch_command_for_test() =~ "upstream/$base_branch"
  end

  test "maestro pre-review fails closed without dedicated Linear auth" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-maestro-pre-review-missing-auth-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      previous_maestro_linear_api_key = System.get_env("MAESTRO_LINEAR_API_KEY")
      on_exit(fn -> restore_env("MAESTRO_LINEAR_API_KEY", previous_maestro_linear_api_key) end)
      System.delete_env("MAESTRO_LINEAR_API_KEY")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-maestro-failure",
        identifier: "MT-5318",
        title: "Record pre-review failure",
        description: "The fallback should leave the issue in Human Review",
        state: "Human Review",
        url: "https://example.org/issues/MT-5318",
        labels: ["symphony"]
      }

      assert {:error, :missing_maestro_linear_api_key} =
               SymphonyElixir.MaestroPreReview.run(issue,
                 linear_client: fn _query, _variables, _opts ->
                   flunk("missing dedicated auth must not preflight Linear")
                 end,
                 app_server_runner: fn _workspace, _prompt, _issue, _opts ->
                   flunk("missing dedicated auth must not start Maestro")
                 end
               )

      refute_received {:memory_tracker_comment, "issue-maestro-failure", _body}
      refute_received {:memory_tracker_state_update, "issue-maestro-failure", _state}
    after
      File.rm_rf(test_root)
    end
  end

  test "maestro pre-review fails closed when dedicated Linear auth is invalid" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "issue-maestro-invalid-auth",
      identifier: "MT-5320",
      title: "Reject invalid Maestro Linear auth",
      description: "The fallback must not use Symphony auth",
      state: "Human Review",
      url: "https://example.org/issues/MT-5320",
      labels: ["symphony"]
    }

    assert {:error, :invalid_maestro_linear_api_key} =
             SymphonyElixir.MaestroPreReview.run(issue,
               maestro_linear_api_key: "bad-token",
               linear_client: fn _query, _variables, opts ->
                 assert opts == [api_key: "bad-token"]
                 {:error, {:linear_api_status, 401}}
               end,
               app_server_runner: fn _workspace, _prompt, _issue, _opts ->
                 flunk("invalid dedicated auth must not start Maestro")
               end
             )

    refute_received {:memory_tracker_comment, "issue-maestro-invalid-auth", _body}
    refute_received {:memory_tracker_state_update, "issue-maestro-invalid-auth", _state}
  end

  test "maestro pre-review does not write Symphony-auth no-action comments after startup failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-maestro-pre-review-startup-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(test_root, "workspaces")
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-maestro-startup-failure",
        identifier: "MT-5321",
        title: "Do not fallback-comment startup failures",
        description: "Only dedicated Maestro auth may write Maestro review notes",
        state: "Human Review",
        url: "https://example.org/issues/MT-5321",
        labels: ["symphony"]
      }

      assert {:error, {:maestro_main_branch_prepare_failed, _status, _output}} =
               SymphonyElixir.MaestroPreReview.run(issue,
                 maestro_linear_api_key: "maestro-token",
                 linear_client: fn _query, _variables, opts ->
                   assert opts == [api_key: "maestro-token"]
                   {:ok, %{"data" => %{"viewer" => %{"id" => "usr_maestro"}}}}
                 end
               )

      refute_received {:memory_tracker_comment, "issue-maestro-startup-failure", _body}
      refute_received {:memory_tracker_state_update, "issue-maestro-startup-failure", _state}
    after
      File.rm_rf(test_root)
    end
  end

  test "maestro pre-review injects the dedicated Linear api key into fresh session tools" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-maestro-pre-review-dedicated-auth-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      upstream_repo = Path.join(test_root, "upstream")

      File.mkdir_p!(upstream_repo)
      System.cmd("git", ["-C", upstream_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", upstream_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", upstream_repo, "config", "user.email", "test@example.com"])
      File.write!(Path.join(upstream_repo, "README.md"), "# upstream")
      System.cmd("git", ["-C", upstream_repo, "add", "README.md"])
      System.cmd("git", ["-C", upstream_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git init -b main . && git remote add upstream #{upstream_repo}"
      )

      issue = %Issue{
        id: "issue-maestro-dedicated-auth",
        identifier: "MT-5319",
        title: "Use dedicated Maestro Linear auth",
        description: "Maestro tool calls must not use Symphony auth",
        state: "Human Review",
        url: "https://example.org/issues/MT-5319",
        labels: ["symphony"]
      }

      parent = self()

      linear_client = fn query, variables, opts ->
        send(parent, {:linear_client_called, query, variables, opts})
        {:ok, %{"data" => %{"viewer" => %{"id" => "usr_maestro"}}}}
      end

      app_server_runner = fn _workspace, _prompt, _issue, opts ->
        result = opts[:tool_executor].("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})
        send(parent, {:tool_result, result})
        {:ok, %{id: "turn-maestro"}}
      end

      assert :ok =
               SymphonyElixir.MaestroPreReview.run(issue,
                 maestro_linear_api_key: "maestro-token",
                 linear_client: linear_client,
                 app_server_runner: app_server_runner
               )

      assert_receive {:linear_client_called, "query SymphonyLinearViewer" <> _, %{}, [api_key: "maestro-token"]}
      assert_receive {:linear_client_called, "query Viewer { viewer { id } }", %{}, [api_key: "maestro-token"]}
      assert_receive {:tool_result, %{"success" => true}}
      refute_received {:memory_tracker_comment, "issue-maestro-dedicated-auth", _body}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner runs maestro pre-review after a human review handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-maestro-human-review-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-maestro"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-maestro"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      parent = self()

      issue = %Issue{
        id: "issue-maestro-human-review",
        identifier: "MT-5316",
        title: "Pre-review Human Review",
        description: "Run Maestro after handoff",
        state: "In Progress",
        url: "https://example.org/issues/MT-5316",
        labels: ["symphony"]
      }

      pre_review_runner = fn refreshed_issue, opts ->
        send(parent, {:maestro_pre_review, self(), refreshed_issue.identifier, refreshed_issue.state, opts[:worker_host]})

        receive do
          :finish_maestro_pre_review -> :ok
        after
          5_000 -> :ok
        end

        :ok
      end

      runner_task =
        Task.async(fn ->
          AgentRunner.run(
            issue,
            nil,
            issue_state_fetcher: fn [_issue_id] ->
              {:ok, [%{issue | state: "Human Review"}]}
            end,
            maestro_pre_review_runner: pre_review_runner
          )
        end)

      assert_receive {:maestro_pre_review, maestro_pid, "MT-5316", "Human Review", nil}, 5_000
      runner_result = Task.yield(runner_task, 200)
      maestro_ref = Process.monitor(maestro_pid)

      send(maestro_pid, :finish_maestro_pre_review)
      assert runner_result == {:ok, :ok}
      assert_receive {:DOWN, ^maestro_ref, :process, ^maestro_pid, :normal}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips maestro pre-review for non human review terminal handoff" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-maestro-done-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-done"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-done"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      parent = self()

      issue = %Issue{
        id: "issue-maestro-done",
        identifier: "MT-5317",
        title: "No pre-review after done",
        description: "Do not run Maestro for Done",
        state: "In Progress",
        url: "https://example.org/issues/MT-5317",
        labels: ["symphony"]
      }

      pre_review_runner = fn refreshed_issue, _opts ->
        send(parent, {:unexpected_maestro_pre_review, refreshed_issue.state})
        :ok
      end

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end,
                 maestro_pre_review_runner: pre_review_runner
               )

      refute_received {:unexpected_maestro_pre_review, _state}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops same-session continuation when stop-after-turn marker is written" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-stop-after-turn-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-249")
      stop_marker = Path.join([workspace, ".symphony", "stop-after-turn"])
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      stop_marker="${SYMP_TEST_STOP_MARKER:?}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-stop-marker"}}}'
            ;;
          4)
            mkdir -p "$(dirname "$stop_marker")"
            : > "$stop_marker"
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-stop-marker-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-stop-marker-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      System.put_env("SYMP_TEST_STOP_MARKER", stop_marker)

      on_exit(fn ->
        System.delete_env("SYMP_TEST_CODEx_TRACE")
        System.delete_env("SYMP_TEST_STOP_MARKER")
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_stop_marker_fetch_count, 0) + 1
        Process.put(:agent_stop_marker_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-stop-marker",
             identifier: "MT-249",
             title: "Stop after auto-advance",
             description: "Marker asks runner to yield to the scheduler",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-stop-marker",
        identifier: "MT-249",
        title: "Stop after auto-advance",
        description: "Marker asks runner to yield to the scheduler",
        state: "In Progress",
        url: "https://example.org/issues/MT-249",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_received {:issue_state_fetch, _}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      turn_starts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.count(&(&1["method"] == "turn/start"))

      assert turn_starts == 1
      assert File.exists?(stop_marker)
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      System.delete_env("SYMP_TEST_STOP_MARKER")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp dispatch_issue(id, identifier, project_slug, created_at) do
    %Issue{
      id: id,
      identifier: identifier,
      title: identifier,
      priority: 0,
      state: "Todo",
      project: %{slug_id: project_slug},
      labels: ["symphony"],
      created_at: created_at
    }
  end

  defp shared_workflow_prompt do
    File.read!(Path.expand("../workflows/agavemindlab/WORKFLOW.md", File.cwd!()))
  end

  defp dry_run_artifact_calls(workflow, :clarification_answer, phase, old_artifact) do
    required_contracts = [
      "clarification-answer resume",
      "even if the Linear state is `In Progress`",
      "resolve the old artifact",
      "post a fresh top-level artifact",
      "do not `commentUpdate` the old artifact",
      "resolves the old artifact with `commentResolve`",
      "fresh top-level artifact with `commentCreate`"
    ]

    if Enum.all?(required_contracts, &String.contains?(workflow, &1)) do
      new_artifact = fresh_artifact_version(old_artifact)

      [
        {:commentResolve, old_artifact.id},
        {:commentCreate, :top_level_phase_artifact, "## #{phase}"},
        {:commentCreate, {:reply_to_new_artifact, new_artifact.id}, "clarification summary"}
      ]
    else
      [{:commentUpdate, old_artifact.id, "## #{phase}"}]
    end
  end

  defp dry_run_artifact_calls(workflow, :question_discussion, phase, artifact) do
    required_contracts = [
      "**Question / discussion**",
      "answer in that artifact's thread",
      "Do **not** write an approval reply, advance, resolve, or re-post the artifact"
    ]

    if Enum.all?(required_contracts, &String.contains?(workflow, &1)) do
      [{:commentCreate, {:reply_to_artifact, artifact.id}, "answer #{phase} question"}]
    else
      [{:commentUpdate, artifact.id, "## #{phase}"}]
    end
  end

  defp dry_run_artifact_calls(workflow, :cross_phase_rollback, target_phase, awaiting_phase, artifacts) do
    required_contracts = [
      "from the target phase through the awaiting-review phase",
      "including stale same-phase target artifacts",
      "phase artifact comments invalidated by the rollback",
      "Do not resolve standalone human comments",
      "new source of truth explicitly keeps"
    ]

    artifacts_to_resolve =
      artifacts
      |> Enum.filter(&phase_artifact_invalidated_between?(&1, target_phase, awaiting_phase))
      |> then(fn invalidated ->
        if Enum.all?(required_contracts, &String.contains?(workflow, &1)) do
          invalidated
        else
          Enum.reject(invalidated, &(&1.phase == target_phase))
        end
      end)

    Enum.map(artifacts_to_resolve, &{:commentResolve, &1.id}) ++
      [{:commentCreate, :top_level_phase_artifact, "## #{target_phase}"}]
  end

  defp phase_artifact_invalidated_between?(artifact, target_phase, awaiting_phase) do
    artifact.kind == :phase_artifact and artifact.invalidated? and
      phase_between?(artifact.phase, target_phase, awaiting_phase)
  end

  defp phase_between?(phase, target_phase, awaiting_phase) do
    phase_order = ["Requirements", "Design", "Implementation", "Deployment"]
    phase_index = Enum.find_index(phase_order, &(&1 == phase))
    target_index = Enum.find_index(phase_order, &(&1 == target_phase))
    awaiting_index = Enum.find_index(phase_order, &(&1 == awaiting_phase))

    phase_index >= target_index and phase_index <= awaiting_index
  end

  defp resolved_comment_ids(calls) do
    for {:commentResolve, id} <- calls, do: id
  end

  defp active_artifacts_after_rollback(calls, artifacts, replacement_artifact) do
    resolved_ids = MapSet.new(resolved_comment_ids(calls))

    artifacts
    |> Enum.concat([replacement_artifact])
    |> Enum.filter(&(&1.kind == :phase_artifact))
    |> Enum.reject(&MapSet.member?(resolved_ids, &1.id))
  end

  defp fresh_artifact_version(old_artifact) do
    %{
      id: "fresh-#{old_artifact.id}",
      created_at: DateTime.add(old_artifact.created_at, 1, :second)
    }
  end

  defp refute_called_comment_update_for_artifact(calls, artifact_id) do
    refute Enum.any?(calls, fn
             {:commentUpdate, ^artifact_id, _body} -> true
             _ -> false
           end)
  end
end
