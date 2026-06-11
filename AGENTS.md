# Symphony — agent working principles

## Fix by simplifying first, not by adding

When fixing a defect in a prompt / skill / spec / doc, **the default move is to
delete or correct, not to add.** First ask: can this be solved by *removing one
wrong line, correcting one place, or merging duplication*? If so, do that. Only
add new content when simplification genuinely cannot solve it.

Why: a defect usually comes from one thing written wrong or one misleading
example, which downstream copies as the default ingredient. Patching over it
hides the symptom while the doc grows longer, rules start contradicting each
other, and the root cause survives. A fix that keeps getting longer is usually
compensating for a place that should have just been corrected.

How to apply:
- Trace the root cause to the **single smallest place** (which sentence, which
  example steered the behavior) and change that.
- After changing it, re-read: does any new paragraph merely restate what is
  already true once the root cause is fixed? If so, delete it.
- Ending shorter than you started is the norm, not the exception.

## Where to work: the workflows/ symlink model

`workflows/<project>/` is composed from symlinks into a canonical shared base
plus real files that override it. Before editing anything under a project
directory, `readlink` it first:

- A **symlink** (e.g. `WORKFLOW.md -> ../agavemindlab/WORKFLOW.md`,
  `skills -> ../agavemindlab/skills`) means you are editing the **shared base** —
  the change hits every project that inherits it. `agavemindlab` is the base.
- A **real file/dir** is a per-project override; it touches only that project.
  To make a shared entry project-specific, replace the symlink with a real file.

There is no `extends`/merge layer — directory entries are the whole mechanism.
See `workflows/agavemindlab/README.md` for the override rules and `bin/README.md`
for the launcher's env layering.
