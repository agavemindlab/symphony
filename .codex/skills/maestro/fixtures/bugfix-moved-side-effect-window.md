# Bugfix that moves side effects opens new failure windows

- Origin: production miss fixed in commit f756b26 (rule formerly inlined in
  the reviewer prompt's bugfix lens).
- Situation: a fix moved persistence/resource creation/external calls/cleanup
  earlier or later relative to the success boundary, creating new failure
  points whose durable leftovers were unexplained.
- Wrong output: approve because the original symptom was fixed and tests
  passed.
- Correct output: request changes — require evidence for each new failure
  point between the moved side effect and the success boundary, and an
  explanation (or tests) showing durable state left by those failures is safe.
- Principle: reordering side effects is itself a change that needs evidence;
  the bugfix lens's "why the change should not introduce new problems" covers
  the windows the move created.
