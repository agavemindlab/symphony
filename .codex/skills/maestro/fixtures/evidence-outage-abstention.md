# Evidence-tool outage is not a verdict

- Cases: DEV-4800, DEV-5239, DEV-5362, DEV-5371 (baseline replay, 2026-07).
- Situation: Linear/GitHub network access was blocked; local session
  transcripts and caches carried the artifact, comments, and PR facts, but the
  reviewer refused them as "prior conversation context".
- Wrong output: `no reply yet` / `unchanged` reporting the tool outage as the
  blocker; humans decided approve (3 cases) or request changes (1 case).
- Correct output: decide from the best available cached/local evidence, cite
  the source and its limits in `依据`/`注意`, and return a real verdict.
- Principle: a tool outage changes the evidence source, not the reviewer's
  obligation to judge; abstain only when no awaiting artifact is identifiable.
