# Multiple linked PRs need explicit classification

- Origin: production miss fixed in commit 0a2fcbd.
- Situation: the reviewed issue had several linked/open PRs; the artifact
  reported evidence for one PR while another open PR carried unmerged scope
  and unresolved checks, with no statement of which PR was the merge target.
- Wrong output: approve based on the healthy PR alone.
- Correct output: request changes or ask clarification — identify the current
  merge target, classify every other open PR as superseded/stale or still
  relevant, and block when the target is ambiguous or another PR holds
  unmerged scope, current human feedback, or unresolved checks.
- Principle: PR evidence is per-target; an unclassified extra open PR is
  unaccounted scope, not noise.
