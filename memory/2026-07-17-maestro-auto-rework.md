# Debug report: Maestro ordinary request changes stalled in Human Review

- **Symptom:** DEV-4917 received a high-confidence Maestro `request changes` / `Rework` recommendation, but Maestro removed `symphony:maestro` and left the issue in `Human Review`.
- **Root cause:** `815396b` replaced all pre-review state changes with a blanket recommendation-only rule while fixing ESCALATED review loops. The normal workflow also accepted only human feedback, so restoring the state mutation alone would still lose Maestro's rework direction.
- **Fix:** Auto-execute non-ESCALATED `request changes` with the existing audited marker and `Rework` state; let the main workflow consume only a matching artifact/head marker; keep the ESCALATED human gate first. Retry a failed state write when a matching auto-rework reply already exists.
- **Evidence:** The prompt contract test failed 4 assertions before the fix and passes after it. `mise exec -- make all` passes with 471 tests, 0 failures, 2 skipped and no Dialyzer errors. Artifact-eval fixtures return the expected PASS/MISSING_CONTEXT/INVALID_CASE results.
- **Regression test:** `elixir/test/symphony_elixir/core_test.exs` covers ordinary auto-rework, marker routing, and ESCALATED precedence.
- **Related:** `95c30f8` correctly moved the ESCALATED gate before generic intent; this fix preserves that ordering.
- **Status:** DONE
