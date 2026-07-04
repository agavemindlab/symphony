# Human-only provisioning needs the runbook in the artifact

- Origin: production misses fixed in commits 9bc50e3 and 4cc0527.
- Situation: an issue was blocked on separate human-only credential/secret
  provisioning; the artifact said "waiting on human" but the concrete steps
  lived only in the PR diff, CI logs, and the reviewer's own investigation.
- Wrong output: `no reply yet` with a runbook the reviewer assembled from
  PRs/logs, or one that also asked to merge first.
- Correct output: request changes — the artifact itself must say where to
  act, what to configure, where secret values come from (without printing
  them), how to rerun verification, and the pass predicate; only then is
  `no reply yet` / `unchanged` correct.
- Principle: the human-only carve-out is earned by the artifact's own proven
  boundary and executable runbook, never inferred by the reviewer.
