# Silent scope narrowing via "first / 首先"

- Origin: production miss fixed in commit cb2e848 (detail formerly inlined in
  the reviewer prompt's Requirements rules).
- Situation: an issue description said to "first / 首先" do one part of a
  broad delivery; the Requirements artifact quietly turned the whole issue
  into a Spike/research/docs-only task scoped to that first part.
- Wrong output: approve, reading "first" as human authorization for the
  narrower issue.
- Correct output: request changes — "first do X" orders work inside the
  issue's scope; it does not shrink the scope. Require a parent/subissue
  boundary or explicit human scope approval for the narrower issue.
- Principle: sequencing words in a description are not scope changes; only
  explicit human approval rescopes an issue.
