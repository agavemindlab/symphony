# Root-cause deferral must be explicit, not inferred

- Origin: production miss (rule formerly inlined in the reviewer prompt's
  bugfix lens).
- Situation: an Implementation artifact for a runtime failure shipped a
  symptom patch, citing approved Design scope / Deployment gates as implicit
  permission to discover the root cause after merge.
- Wrong output: approve, or offering Requirements rescoping as an
  alternative, treating scope boundaries as a root-cause deferral.
- Correct output: request changes unless the artifact explains the failing
  runtime path and cause, or the approved Requirements (or a human
  Requirements clarification) explicitly says root-cause discovery happens
  after merge.
- Principle: only an explicit human/Requirements statement defers root-cause
  work; Design scope, Implementation boundaries, and Deployment gates do not.
