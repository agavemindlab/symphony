# Human Review handoff in flight is still reviewable

- Case: DEV-5384 (baseline replay, 2026-07).
- Situation: at the replay cutoff the Implementation artifact existed and the
  session showed the `Human Review` state move completing 49 seconds later;
  PR head was CLEAN with automated-reviewer approval only.
- Wrong output: `no reply yet` because "the issue was not yet in Human Review
  at the cutoff"; the human approved.
- Correct output: review the awaiting artifact on its merits; a stale or
  racing issue-state read does not change what the artifact is.
- Principle: the review target is the awaiting-review artifact, not the
  issue-state read; state verification exists to avoid reviewing the wrong
  thing, not to license abstention.
