# Runtime-exercise demands: core boundary vs covered windows

- Cases: DEV-5189 (over-fire) vs DEV-5396 (correct fire), baseline replay.
- Situation A (DEV-5189): ffmpeg-decoder-leak bugfix with targeted service
  tests covering each durable-state failure window (stale state self-heal,
  cleanup paths), CI green, merge-risk judgment present.
- Wrong output A: request changes demanding a black-box runtime exercise
  ritually; the human approved on the targeted-test evidence.
- Situation B (DEV-5396): a new CI deploy gate whose entire value is the
  external `lain job` CLI boundary, verified only by self-written stubs.
- Correct output B: request changes — no named test touched the boundary the
  change exists to cross.
- Principle: demand a runtime exercise when the change's core value crosses a
  boundary no named test touches; when targeted tests demonstrably cover each
  changed boundary, judge as a strict human would instead of by checklist.
