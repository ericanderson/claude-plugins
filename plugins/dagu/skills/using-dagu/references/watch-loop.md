# ScheduleWakeup-Driven Watch Loop

How to watch a dagu run to completion in the main session without burning context
or LLM turns between status checks.

## When to use this

Use when the user asked to watch a dagu run from the main session — "kick off and
watch", "let me know when X finishes", "is it done yet". This is the **default**
mechanism for in-session watching.

Do **not** use for:
- Out-of-band watching where the user wants to keep working — see `subagent-watch.md`.
- One-shot status checks — just run `dagu status` and report.

## State-carry format

The wakeup `prompt` carries a compact serialization of the last-known node states
so the next firing can diff without re-reading run history. Format:

```
<step1>:<state>,<step2>:<state>,<step3>:<state>
```

`<state>` is one of: `pending`, `running`, `done`, `failed`, `cancelled`. These map
from the integer status enum (see `on-disk.md`): 0→pending, 1→running, 2→failed,
3→cancelled, 4→done.

Example mid-run snapshot for a 5-step DAG:

```
fetch:done,validate:done,transform:running,load:pending,notify:pending
```

## Per-tick decision tree

On each wakeup the agent runs:

```
1. Read latest status.
   Prefer:  tail -1 of <data>/dag-runs/<dag>/.../attempt_*/status.jsonl
   Fallback: dagu status --run-id $RUN_ID

2. Parse current node states from status into a map: step_name -> state.

3. Diff against the last-known states (passed in via wakeup prompt).
   For each transition, surface to user as one line:
     [HH:MM:SS] <step>: <old> → <new>

4. If any node is in `failed` state with no `continueOn: failure` clause, read its
   .err (path comes from status output) and surface a short excerpt (last 20 lines).

5. Classify overall:
   - All nodes terminal (done | failed | cancelled) AND top status is terminal
     (2, 4, 6) → emit final timeline summary, do NOT schedule again.
   - Any node still running OR top status still 1 → ScheduleWakeup again with
     updated state-carry.
   - Top status is 5 (queued for retry) → ScheduleWakeup with shorter delay
     (auto-retry usually fires within seconds).
```

## Cache-TTL guidance

| Run duration | Recommended delay | Rationale |
|--------------|-------------------|-----------|
| <2 min | Don't watch — one `dagu status` and report. | |
| 2–5 min | 270s | Stays inside the 5-min prompt-cache TTL. |
| 5–15 min | 270s repeated | Multiple short wakes; cache stays warm if they don't cluster. |
| 15+ min | 1200s | Pay one cache miss for a long wait. |

**Don't pick 300s.** Worst-of-both: cache miss without amortization. Either drop to
270s (cache-warm) or commit to 1200s+ (long wait amortizes the miss).

## Terminal-state output format

When the run reaches a terminal state, emit one consolidated message:

```
<dag-name> run <run-id-short> finished: <status>  (<duration>)

Timeline:
  [HH:MM:SS] fetch: 0s  ✓
  [HH:MM:SS] validate: 8s  ✓
  [HH:MM:SS] transform: 1m 0s  ✓
  [HH:MM:SS] load: 4s  ✓
  [HH:MM:SS] notify: 1m 9s  ✗ failed
    (last 20 lines of .err)
  [HH:MM:SS] cleanup: SKIPPED (continueOn: failure on notify)

Logs: <path-to-dag-run-dir>
```

## Exit conditions

- Terminal top-status integer (2 failed, 4 done, or 6 cancelled) → emit final
  summary and stop scheduling.
- User interruption — the next user message naturally pre-empts the loop; no
  explicit handling needed.
- Max-tick safety bound: if more than 100 wakeups have fired without reaching a
  terminal state, stop and report "watch loop hit safety bound — manual check
  needed."
