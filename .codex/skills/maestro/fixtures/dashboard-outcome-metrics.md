# Dashboard gap labels do not close outcome-proof work

- Origin: production misses fixed in commits 286c3a6 and 1affa71 (metric
  enumeration formerly inlined in the reviewer prompt).
- Situation: a dashboard/analytics issue whose purpose was proving a real
  outcome (cycle time, manual intervention, automation rate, failure/rework
  quality, review/CI quality, cohort definition, baseline/trend) shipped with
  those signals labeled `partial` / `gap` / "sample insufficient" and a
  "no follow-up needed" note; the human had praised the honest labeling.
- Wrong output: `Done` — treating transparent gap labels or the human's
  labeling approval as acceptance to stop tracking.
- Correct output: request changes — require a linked, routed, scheduled
  follow-up carrying those proof gaps, or explicit human risk acceptance to
  drop them.
- Principle: labeling a gap satisfies transparency; closing the issue's
  stated question still needs the gap tracked or explicitly waived.
