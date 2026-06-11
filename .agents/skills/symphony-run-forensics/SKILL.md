---
name: symphony-run-forensics
description: Use when investigating or root-causing why a Symphony/Codex agent run did, skipped, or got something wrong (e.g. "why didn't the PR request review", "why did it add a 7-day criterion", "why did the run stop"). Read the run's Codex session transcript as primary evidence BEFORE theorizing from skill/engine/config code.
---

# Symphony run forensics

When investigating why a Symphony/Codex run did or skipped something, the
ground truth is what the agent **actually did** — recorded in its Codex session
transcript — **not** what the skill, engine, or config implies it *should* do.

**Read the transcript first.** Reach for code/config tracing only to explain
something the transcript already shows happened.

## Why this skill exists

A Codex agent follows skill **prose** and improvises its own shell commands; it
does **not** deterministically run a skill's embedded scripts or read every env
var / code path the implementation consults. So inferring behavior from the
code assumes a premise the agent may never have acted on, and a tidy code-path
theory can be confidently wrong.

Worked example (the run that motivated this skill): a PR failed to request its
`gl-swe` review. Several turns were burned tracing how `$AUTOMATED_REVIEWER`
flows through the launcher, the Elixir engine, `set -a`, SSH, and `Port.open` —
all to decide whether the env var reached the agent. The transcript settled it
in one line: the agent **never read that env var at all**. It grepped
`AGENTS.md` / `.github` for a reviewer account, found only a `reviewdog` lint
annotator, and concluded "no reviewer configured" — because the skill's *prose*
told it to look in `AGENTS.md`. No amount of env-plumbing code reading could
have found that; the transcript showed it immediately.

## How to do it

1. **Locate the transcripts.** They live at
   `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl`. The filename timestamp
   is **local time**; the `timestamp` fields inside each entry are **UTC** — so
   a run logged at ~05:00 UTC appears under a `T13-*` filename in a UTC+8 zone.

2. **Find the right run** by grepping a unique string — issue title, PR number,
   an artifact phrase — rather than guessing by time:
   ```
   grep -rl "<unique phrase>" ~/.codex/sessions/<YYYY>/<MM>
   ```
   Prefer a string unique to the issue (e.g. a Chinese title fragment); a bare
   PR number matches many unrelated runs.

3. **Read what the agent actually ran and concluded, in order.** The signal is
   in `payload.type` of each line: `function_call` (the `exec_command` /
   tool calls it ran, with `arguments`), `function_call_output` (results), and
   `message` (its own reasoning / conclusions). Parse with a small Python jsonl
   reader — not raw `cat` (these files are large and noisy):
   ```python
   import json, sys
   rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
   for i, r in enumerate(rows):
       p = r.get("payload", {})
       t = p.get("type")
       if t == "function_call":
           print(f"[{i}] $ {p.get('name')} {p.get('arguments','')[:300]}")
       elif t == "function_call_output":
           print(f"[{i}] OUT {str(p.get('output',''))[:300]}")
       elif t == "message":
           txt = "".join(c.get("text","") for c in p.get("content",[]) if isinstance(c, dict))
           print(f"[{i}] {p.get('role')}: {txt[:300]}")
   ```
   Grep the dump for the decision point (the command it ran, the message where
   it concluded), then print the surrounding window for context.

4. **Quote the transcript line as evidence before asserting a cause.** "The
   agent ran X and concluded Y" beats "the code would have done Z." If you catch
   yourself theorizing about behavior without having opened the transcript, stop
   and open it.

## Then, and only then, trace code

Once the transcript shows *what* happened, use the skill/engine/config to
explain *why the agent was led there* — usually a misleading instruction or a
gap between prose and the embedded script. That is the place to fix (see the
"fix by simplifying first" principle in `AGENTS.md`).
