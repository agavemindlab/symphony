---
name: artifact-eval
description:
  Capture a Human Review phase artifact into a local replay case, then replay
  that case against the current workflow and phase skill.
---

# Artifact Eval

Use this skill when a Human Review artifact should become a local, replayable
case for workflow or phase-skill prompt changes.

## Safety Model

- `capture` is read-only for Linear: use GraphQL queries only.
- Do not change issue state, write comments, push, or commit.
- Write generated cases under `.symphony/artifact-eval/cases/` unless the user
  gives an explicit repo-local output path.
- Do not capture secrets, `.env`, `.issue-secrets`, or the whole workspace.
- Do not capture symlinks; they may point at repo-external secrets.
- `replay` must not read current Linear/GitHub state. If a case needs
  uncaptured external context, report `MISSING_CONTEXT`.

## Commands

### `capture <Linear artifact/comment URL>`

1. Parse the Linear comment id from the URL.
2. Use `linear_graphql` with query operations only to read:
   - the target comment;
   - its parent and children;
   - the issue snapshot;
   - unresolved phase artifacts that are part of the current review chain.
3. Save the read result as:

   ```text
   .symphony/artifact-eval/raw/<issue>-<comment>.json
   ```

   The JSON must contain:

   ```json
   {
     "issue": {},
     "artifact_thread": {},
     "required_context": []
   }
   ```

4. Build the case:

   ```bash
   python3 .codex/skills/artifact-eval/scripts/artifact_eval.py \
     capture "<Linear artifact/comment URL>" \
     --linear-json .symphony/artifact-eval/raw/<issue>-<comment>.json \
     --output .symphony/artifact-eval/cases/<issue>-<comment>
   ```

5. Report the case path. Do not post it back to Linear unless a separate
   workflow explicitly asks for that.

### `replay <case path>`

Run:

```bash
python3 .codex/skills/artifact-eval/scripts/artifact_eval.py replay <case path>
```

Then read `<case path>/replay/report.md` and
`<case path>/replay/artifact-draft.md`.

If the report says `MISSING_CONTEXT`, stop. Do not patch around it by reading
the current machine's real external files, Linear state, GitHub state, or tool
state.

### Local Verification

Run:

```bash
python3 .codex/skills/artifact-eval/scripts/artifact_eval.py verify-fixtures
```

This checks the committed fixture case structure, replay rebuild path, and
`MISSING_CONTEXT` guard.

## Related: maestro verdict corpus

`mix symphony.eval.maestro` (run in `elixir/`) pairs every `maestro_review`
analytics event with its human verdict (the next `run_started` state) and
writes `eval/maestro/corpus.jsonl` plus a `report.md` of agreement rates.
That corpus is ground truth for future maestro-reviewer replays; capture a
full artifact-eval case for any overridden pair worth debugging. `eval/` is
gitignored — corpora carry internal issue content and stay local.

## Maestro reviewer replay

Evaluate `.codex/skills/maestro/agents/maestro-reviewer.md` against human
verdicts. `mix symphony.eval.reviews` (run in `elixir/`) labels every
`phase_published` artifact with its first disposition — human ✅ `approve`,
agent ⏩ `auto_advanced`, a superseding rework round or rollback
`request_changes`, else `pending` — and writes `eval/reviews/cases.jsonl`
plus `labels-report.md` (only approve/request_changes are scored).

```bash
cd elixir && mix symphony.eval.reviews          # build the labeled test set
python3 .codex/skills/artifact-eval/scripts/maestro_replay.py replay \
  --cases eval/reviews/cases.jsonl --sample 20   # one codex session per case
python3 .codex/skills/artifact-eval/scripts/maestro_replay.py score \
  --cases eval/reviews/cases.jsonl \
  --predictions eval/reviews/replay/predictions.jsonl
```

`replay` runs `codex exec --sandbox read-only` per case (prompt on stdin:
the full reviewer prompt plus a time-travel preamble) and appends
`predictions.jsonl` incrementally — interrupted runs keep partial results and
reruns resume by skipping predicted cases. Time-travel caveat: the reviewer
is told to only consider Linear comments and PR state from before the
artifact's `published_at`, but it reads live Linear/GitHub, so leakage from
later history is possible — treat agreement as an upper bound. Cost note:
each case is a full codex session; use `--sample N` (stable sort by case id,
deterministic) and `--phase` for regression subsets. `score` writes
`report.md` with overall/by-phase/by-label agreement, a confusion matrix,
and the disagreement list.
