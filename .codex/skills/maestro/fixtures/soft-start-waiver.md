# Soft-start feedback is not a merge waiver

- Origin: production misses fixed in commits 2bd06bf and 7ecf78c (rule
  formerly restated three times in the reviewer prompt).
- Situation: human feedback accepted a soft-start shape ("keep it default-off",
  "if this issue merges first, it must soft-start") or asked only for
  refreshed merge-risk evidence while a prerequisite issue was unfinished.
- Wrong output: approve/merge nudge citing that feedback as acceptance of
  merging before the prerequisite.
- Correct output: request changes / `Rework` — a waiver exists only when the
  human explicitly says to merge, approve, or move to `Merging` before the
  prerequisite finishes, cited verbatim in `依据`.
- Principle: conditional or shape-level feedback is implementation guidance;
  treat "no citable waiver text" as "no waiver".
