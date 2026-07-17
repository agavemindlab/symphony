# Prerequisite blockers inherit the blocked issue's priority

- Origin: production miss fixed in commit c570056 (rule deleted from the
  reviewer prompt in the 2026-07 rubric refactor).
- Situation: the agent created a true prerequisite blocker issue with a lower
  priority than the high-priority issue it blocked, so the blocker would
  never be scheduled ahead of the work waiting on it.
- Wrong output: approve the artifact with the under-prioritized blocker.
- Correct output: request changes — the blocker's priority must be at least
  the highest priority of the issue it blocks, unless current human feedback
  explicitly accepts lower priority.
- Principle: a blocker that sorts behind its dependents is not schedulable;
  priority is part of a valid blocker relation.
