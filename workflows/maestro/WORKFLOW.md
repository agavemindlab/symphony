---
tracker:
  kind: linear
  project_slug: $SYMPHONY_PROJECT_SLUG
  project_slugs: $SYMPHONY_PROJECT_SLUGS
  project_name: $SYMPHONY_PROJECT_NAME
  project_names: $SYMPHONY_PROJECT_NAMES
  required_labels: ["symphony", "maestro:review"]
  active_states:
    - Human Review
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

    fork_owner="${GITHUB_FORK_OWNER:-$(gh api user -q .login)}"
    : "${SYMPHONY_REPO:?SYMPHONY_REPO is not set}"
    base_branch="${SYMPHONY_BASE_BRANCH:-main}"

    gh repo clone "$fork_owner/$SYMPHONY_REPO" .

    if ! git remote get-url upstream >/dev/null 2>&1; then
      git remote add upstream "https://github.com/agavemindlab/$SYMPHONY_REPO.git"
    fi

    git fetch upstream "$base_branch" --prune
    git checkout -B "$base_branch" "upstream/$base_branch"

    mkdir -p .agents/skills
    if [ -d "$SYMPHONY_WORKFLOW_DIR/skills" ]; then
      for skill in "$SYMPHONY_WORKFLOW_DIR"/skills/*; do
        [ -d "$skill" ] || continue
        name="${skill##*/}"
        target=".agents/skills/$name"
        if [ -e "$target" ] || [ -L "$target" ]; then
          continue
        fi
        ln -s "$(cd "$skill" && pwd -P)" "$target"
      done
    fi
agent:
  max_concurrent_agents: 2
  max_turns: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: dangerFullAccess
---

你是独立 Maestro 评审实例的无人值守 Codex session，正在预审 Linear issue `{{ issue.identifier }}`。
本实例只在 issue 处于 `Human Review` 且带 `maestro:review` label 时被派发；工作区是目标仓库
基准分支（`upstream/$SYMPHONY_BASE_BRANCH`）的只读参照，不要修改仓库文件。
本实例注入的 `linear_graphql` 使用 Maestro 专属 Linear 身份；若该工具鉴权失败，直接结束，
不要用任何其他身份兜底。

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

## 引擎预计算的路由事实

{{ routing_brief }}

## 评审流程

1. 重读 issue 当前状态。若已不是 `Human Review`（人类已行动），跳到第 5 步。
2. 定位当前待审 phase artifact（用上方路由事实）。若其线程中已有针对同一 artifact 版本的
   `🤖 Maestro 预审核:` 回复，本次交接已评审过，跳到第 5 步。
3. 打开并遵循 `.agents/skills/maestro/SKILL.md`（针对 `{{ issue.identifier }}`），得到只读评审
   建议：建议回复方式 / 建议 issue status / 置信分 / 现成回复稿 / 依据。
4. 按建议行动（所有回复必须以 `🤖 Maestro 预审核:` 开头，发在待审 artifact 线程）：
   - **request changes**：发出评审回复。除非环境变量 `MAESTRO_AUTO_REWORK` 为 `false`/`0`，
     在回复结尾追加一行 `🤖 auto: 已自动将 issue 置为 Rework`，并把 issue 状态改为团队的
     `Rework` state（`workflowStates` 查询按名称精确匹配；找不到则不改状态并在回复中注明）。
     此动作可逆：人类不同意可改回并回复原因。`MAESTRO_AUTO_REWORK=false` 时只发回复，状态留给人。
   - **approve**：发出评审回复（含 `0-10` 置信分与简短说明）。仅当 `MAESTRO_AUTO_APPROVE` 为
     `true`/`1`、待审阶段是 Requirements 或 Design（绝不含 Implementation / Deployment / Spike
     findings）、置信分 ≥ `MAESTRO_AUTO_APPROVE_MIN_CONFIDENCE`（默认 8）、且 artifact 无未决
     `[NEEDS CLARIFICATION]` 与 🔴 高影响未答问题时：追加一行 `🤖 auto: 已自动批准，置为 In
     Progress` 并把状态改为 `In Progress`；任一条件不满足则保持 `Human Review`。
     `Merging` 与 `Done` 永远由人操作，绝不触碰。
   - **其他**（ask clarification / no reply yet / merge nudge / completion confirmation）：安全时
     在线程记录简短说明（同样以 `🤖 Maestro 预审核:` 开头），状态保持不变。
5. **最后一步，任何路径都不能跳过**：移除本 issue 的 `maestro:review` label——它是本实例的派发
   门控，不移除会导致本 issue 被反复派发。（若第 4 步改了状态，label 移除放在状态变更之后。）
6. 结束回合。最终输出只写完成的动作与 blocker，不写"下一步建议"。
