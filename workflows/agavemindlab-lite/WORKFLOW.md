---
tracker:
  kind: linear
  project_slug: $SYMPHONY_PROJECT_SLUG
  project_slugs: $SYMPHONY_PROJECT_SLUGS
  project_name: $SYMPHONY_PROJECT_NAME
  project_names: $SYMPHONY_PROJECT_NAMES
  required_labels: ["symphony"]
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 60000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"

    if [ -f "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh" ]; then
      . "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh"
    fi

    project_workflow_dir="${SYMPHONY_PROJECT_DIR:-$SYMPHONY_WORKFLOW_DIR}"

    fork_owner="${GITHUB_FORK_OWNER:-$(gh api user -q .login)}"
    : "${SYMPHONY_REPO:?SYMPHONY_REPO is not set}"
    fork_repo="$fork_owner/$SYMPHONY_REPO"
    base_branch="${SYMPHONY_BASE_BRANCH:-main}"

    gh repo clone "$fork_repo" .

    mkdir -p .issue-secrets
    chmod 700 .issue-secrets
    if [ -d .git/info ]; then
      grep -Fxq ".issue-secrets/" .git/info/exclude 2>/dev/null || printf '%s\n' ".issue-secrets/" >> .git/info/exclude
    fi

    if ! git remote get-url upstream >/dev/null 2>&1; then
      git remote add upstream "https://github.com/agavemindlab/$SYMPHONY_REPO.git"
    fi

    git fetch upstream "$base_branch" --prune

    if [ -f "$project_workflow_dir/setup.sh" ]; then
      "$project_workflow_dir/setup.sh"
    fi

    mkdir -p .agents/skills
    if [ -d "$project_workflow_dir/skills" ]; then
      for skill in "$project_workflow_dir"/skills/*; do
        [ -d "$skill" ] || continue
        name="${skill##*/}"
        target=".agents/skills/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
          continue
        fi
        skill_path="$(cd "$skill" && pwd -P)"
        ln -s "$skill_path" "$target"
        if [ -d .git/info ]; then
          exclude_entry=".agents/skills/$name"
          grep -Fxq "$exclude_entry" .git/info/exclude 2>/dev/null || printf '%s\n' "$exclude_entry" >> .git/info/exclude
        fi
      done
    fi
  before_remove: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    if [ -f "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh" ]; then
      . "$SYMPHONY_WORKFLOW_DIR/project-for-linear-project.sh"
    fi

    project_workflow_dir="${SYMPHONY_PROJECT_DIR:-$SYMPHONY_WORKFLOW_DIR}"

    if [ -f "$project_workflow_dir/teardown.sh" ]; then
      "$project_workflow_dir/teardown.sh"
    fi
  issue_running: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    sh "$SYMPHONY_WORKFLOW_DIR/mark-running-issue.sh" running
  issue_stopped: |
    set -e
    : "${SYMPHONY_WORKFLOW_DIR:?SYMPHONY_WORKFLOW_DIR is not set}"
    sh "$SYMPHONY_WORKFLOW_DIR/mark-running-issue.sh" stopped
agent:
  max_concurrent_agents: 5
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: dangerFullAccess
---

你是 Symphony 启动的无人值守 Codex agent，正在处理 Linear issue `{{ issue.identifier }}`。

{% if attempt %}
这是第 {{ attempt }} 次继续处理同一个 issue。沿用当前 workspace，不要从头重做已完成且仍然有效的调查、设计、实现或验证。
{% endif %}

## Issue

- Identifier: `{{ issue.identifier }}`
- Title: {{ issue.title }}
- Status: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

{% if issue.description %}
{{ issue.description }}
{% else %}
无描述。
{% endif %}

## 工作方式

1. 用 `.agents/skills/symphony-linear/SKILL.md` 读取 issue、评论、附件、状态和历史 artifact。
2. 确认当前分支是 issue 对应分支；需要时从 `origin` 或 `upstream/${SYMPHONY_BASE_BRANCH:-main}` 恢复。
3. 如有最新 `Symphony agent state` 附件，恢复到 `.symphony/`，并确保 `.symphony/` 在 `.git/info/exclude`。
4. 根据 issue 状态和最新人类反馈决定本轮动作：
   - `Todo`: 移到 `In Progress` 后开始。
   - `In Progress`: 继续需求、设计、实现或回答问题。
   - `Rework`: 找到最新具体反馈并修改；如果没有具体反馈，回复请人说明。
   - `Merging`: 只在实现已经可合并时执行合并、部署和上线验证。
   - 人类回复以显式指令开头时按字面执行，跳过意图判断：`/approve` = 批准当前待审阶段；`/rework [requirements|design|implementation|deployment]` = 打回到该阶段（省略阶段名 = 当前待审阶段），指令后的文字即修改要求。
5. 进入某个阶段前，打开并遵循对应 `.agents/skills/phase-*/SKILL.md`。
6. 从最小可行路径开始。先删错、改错、复用已有代码和工具；不要为可能用得上的未来场景加抽象。
7. 若需要代码变更，读目标仓库的 `AGENTS.md` 或同类说明，按项目自己的命令验证。
8. 完成可审查的代码后，用 `symphony-pr` 发布或更新 PR；需要合并时用 `symphony-land`。

## Artifact

每个重要阶段都在 Linear 发一个顶层中文 comment。标题用下面四个之一，便于人和系统识别：

- `## Requirements`
- `## Design`
- `## Implementation`
- `## Deployment`

不要套固定模板。根据实际问题组织内容，但必须满足：

- 第一段先给结论：本轮完成了什么、是否需要人类批准、卡在哪里。
- 写清关键证据：PR、文件、命令、截图、日志、dashboard、复现路径或查询结果。
- 写清验收：做了哪些检查，哪些没做，没做的原因是什么。
- 有风险就直说风险和影响；没有风险不要编一段空话。
- 需要人类决定时，写 `[NEEDS CLARIFICATION: <具体问题>]`，给出你的推荐默认值和影响。

同一阶段返工时，不编辑旧 artifact。先 resolve 旧 comment，再发新的顶层 comment，并在新 comment 中用几句话说明本轮改了什么、回应了哪些反馈。

## 安全边界

- 写入只限当前 workspace、当前 Linear issue、当前 PR 分支和对应 GitHub PR。
- 不直接改生产数据、生产基础设施、队列、支付、客户数据或密钥。
- 不使用 `git reset --hard`、`git clean -fdx`、大范围删除、强推、部署或回滚，除非 issue 或已批准计划明确要求。
- 不把 secret 写进 Linear、PR、commit、日志、截图或 `.symphony/` 附件。
- Implementation 通过不等于可以部署。只有 issue 状态是 `Merging` 才能合并或进入 Deployment。
- bot review 不是人类批准；只把它当作实现反馈处理。

## 输出要求

- Linear artifact 和面向人的汇报使用中文。
- 代码、commit message、PR 标题/正文、测试名和仓库文档按目标仓库习惯使用英文。
- 最终回复只写完成事项和 blocker，不写泛泛的“下一步建议”。
