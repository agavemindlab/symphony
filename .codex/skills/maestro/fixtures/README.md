# Maestro reviewer fixtures

Case cards distilled from measured reviewer failures and from one-incident
rules removed from `../agents/maestro-reviewer.md` during the 2026-07 rubric
refactor (roadmap P1-11). Each card records: situation, the wrong output it
guards against, the correct output, and a one-line principle. They are inputs
for future eval cases (`mix symphony.eval.reviews` +
`.codex/skills/artifact-eval/scripts/maestro_replay.py`); when a card's
behavior regresses, fix the prompt principle and replay — do not re-inline
the card as a prompt rule.

## From measured baseline disagreements (30-case replay, 70% agreement)

- [evidence-outage-abstention.md](evidence-outage-abstention.md) — tool
  outage is not a verdict; decide from cached/local evidence.
- [handoff-in-flight-state-check.md](handoff-in-flight-state-check.md) — a
  racing Human Review state read does not license abstention.
- [deploy-failure-vs-human-blocker.md](deploy-failure-vs-human-blocker.md) —
  a failed deployment is `Rework` even with a human-side fix involved.
- [environment-blocker-clarification.md](environment-blocker-clarification.md)
  — transient agent-environment probes need no human answer.
- [runtime-exercise-overreach.md](runtime-exercise-overreach.md) — demand a
  runtime exercise for uncovered core boundaries, not ritually.

## From one-incident rules removed from the prompt

- [bugfix-moved-side-effect-window.md](bugfix-moved-side-effect-window.md) —
  moved side effects open new failure windows needing evidence.
- [runtime-root-cause-deferral.md](runtime-root-cause-deferral.md) — only
  explicit Requirements/human text defers root-cause work past merge.
- [spike-scope-narrowing.md](spike-scope-narrowing.md) — "first / 首先" is
  sequencing, not scope narrowing.
- [soft-start-waiver.md](soft-start-waiver.md) — conditional soft-start
  feedback is not a merge waiver.
- [multi-pr-target.md](multi-pr-target.md) — extra open PRs must be
  classified against the merge target.
- [blocker-priority-inheritance.md](blocker-priority-inheritance.md) —
  prerequisite blockers inherit the blocked issue's priority.
- [human-only-provisioning-runbook.md](human-only-provisioning-runbook.md) —
  the human-only carve-out requires the artifact's own runbook.
- [deployment-wait-triggers.md](deployment-wait-triggers.md) — abstract
  future events are not actionable wait triggers.
- [dashboard-outcome-metrics.md](dashboard-outcome-metrics.md) — gap labels
  do not close outcome-proof work.
