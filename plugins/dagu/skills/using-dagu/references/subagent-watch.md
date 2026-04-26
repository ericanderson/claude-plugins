# Subagent-driven out-of-band watch

## When to use this

The user wants the run watched while they continue unrelated work in the main
session. Default is in-session `ScheduleWakeup` (see `watch-loop.md`); only
switch to a subagent when the user asks for out-of-band handling — phrases like
"watch in the background while we...", "let me know when it's done, but keep
working on...", "in parallel".

## Subagent prompt template

Pass this verbatim in the `Agent` tool's `prompt` field (substitute the
`<...>` placeholders):

```
Watch dagu run <run-id> of DAG <dag-name> until it reaches a terminal state.

Use the `using-dagu` skill (Skill tool, name=using-dagu) and follow the
ScheduleWakeup-driven watch loop documented in references/watch-loop.md.

Cadence: ScheduleWakeup every <N>s.
Expected duration: ~<minutes> minutes.

On terminal state, return:
- Final status (succeeded / failed / aborted / partially_succeeded).
- Total duration.
- Per-step timeline (one line per step).
- For any failed step: excerpt of its .err and the full path to it.

Keep your final summary under 200 words.
```

## Dispatch parameters

- `subagent_type: general-purpose`
- `run_in_background: true` — main agent must not block on the subagent.
- `description: "Watch dagu run <run-id-short>"` (use first 8 chars of the run ID).

## What the subagent returns

The main agent gets one notification when the subagent completes. Surface the
subagent's summary to the user verbatim — do not re-paraphrase. If any step
failed, then offer: "Want me to drill into the failing step?" — and if yes,
follow the SKILL.md "Drilling into a failing step" section.

## Why this is not the default

Heavier than `ScheduleWakeup`:

- A full subagent context per watch (the skill body loads twice — once in the
  main agent, once in the subagent).
- Main agent loses real-time visibility into transitions; only sees the final
  summary.
- Fewer chances to course-correct if the run misbehaves mid-flight.

Only worth it when the user explicitly wants out-of-band so they can do
something else in the main session.
