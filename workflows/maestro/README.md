# Maestro reviewer instance

Maestro as a plain Symphony workflow instead of engine machinery: a second
`symphony-run` process watches the same Linear projects with
`active_states: ["Human Review"]` and `required_labels: ["symphony",
"maestro:review"]`, runs the pre-review prompt in `WORKFLOW.md`, and posts the
`🤖 Maestro 预审核:` reply under its own Linear identity.

```sh
bin/symphony-run maestro
```

## Dispatch gate (why the extra label)

To this instance `Human Review` is an *active* state, so a reviewed issue that
stays in `Human Review` would be re-dispatched forever. The `maestro:review`
label is the gate:

- the main workflow adds it whenever a run moves an issue to `Human Review`
  (single rule in the shared WORKFLOW.md guardrails);
- the review session removes it as its **last** step, after the reply and any
  state change. A crash before removal self-heals: the engine retries, the
  `🤖 Maestro 预审核:` marker dedups the reply, and the label then gets removed.

## Operator setup

- `~/.config/symphony/maestro.env` must exist and set `LINEAR_API_KEY` to the
  **Maestro** Linear OAuth key (this instance's whole identity — do not set
  `MAESTRO_LINEAR_API_KEY` here; that variable belongs to the legacy engine
  pre-review only).
- Auto-action envs work as in the engine variant: `MAESTRO_AUTO_REWORK`
  (default on; `false`/`0` for recommendation-only) and `MAESTRO_AUTO_APPROVE`
  / `MAESTRO_AUTO_APPROVE_MIN_CONFIDENCE` (default off / 8).
- Workspaces live under `$HOME/symphony-maestro-workspaces` (set in
  `project.env`) so they never collide with the main instance.
- `projects.tsv` / `project-for-linear-project.sh` are symlinks to the
  grandline registry: both instances watch the same projects.
- Analytics: this instance appends to the same default NDJSON as the main
  instance (dir-lock append is multi-process safe; readers dedup by
  `event_id`). Its dispatch-time comment scans record `maestro_review` events
  at review time. `capacity_snapshot` events mix across instances — known,
  acceptable until the rollup grows an instance tag.

## Migration off the engine pre-review

1. **Coexist (now)**: run this instance alongside the engine-integrated
   pre-review; the `🤖 Maestro 预审核:` marker dedups whichever fires second.
2. **Hand over**: once this instance reviews reliably, remove
   `MAESTRO_LINEAR_API_KEY` from the grandline profile (the engine path then
   fails closed; expect `maestro_skipped` noise on the panel until step 3).
3. **Delete**: remove `maestro_pre_review.ex` + its orchestrator/agent_runner
   trigger sites and tests from the engine — the engine goes back to being a
   generic scheduler.
