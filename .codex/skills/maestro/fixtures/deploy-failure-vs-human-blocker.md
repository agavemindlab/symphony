# Failed deployment beats the human-only-blocker carve-out

- Case: DEV-5361 (baseline replay, 2026-07).
- Situation: Deployment artifact reported Terraform Apply failing on a
  Cloudflare token scope error (HTTP 522 on the worker route), with a clear
  runbook for the admin-side token fix and CI rerun.
- Wrong output: `no reply yet` / `unchanged`, treating the token fix as a
  parked human-only operation; the human requested changes.
- Correct output: request changes / `Rework` — the deployment failed and needs
  correction; the human-side credential fix is one input to the rework, not a
  reason to park the issue.
- Principle: "Deployment failed or needs correction -> `Rework`" takes
  precedence over the human-only-operation carve-out.
