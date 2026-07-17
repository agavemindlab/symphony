# Transient environment probes do not need a human answer

- Case: DEV-5228 (baseline replay, 2026-07).
- Situation: a Requirements artifact was an environment blocker — `.git` not
  writable in the agent workspace — carrying an unresolved
  `[NEEDS CLARIFICATION]` asking the human whether write access was restored.
- Wrong output: `ask clarification` waiting for the human to answer the
  probe; the human simply approved so the next run would re-check.
- Correct output: approve resume (`In Progress`): the artifact content is
  fine and the blocker is transient workspace state the next run re-probes
  itself.
- Principle: `ask clarification` is for judgment, scope, or risk questions
  only a human can answer — not for environment facts an agent can re-check.
