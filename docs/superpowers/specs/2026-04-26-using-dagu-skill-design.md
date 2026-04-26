# Design: `using-dagu` skill

**Status:** spec, awaiting user review before implementation.
**Date:** 2026-04-26.
**Repo:** `ericanderson/claude-plugins`.

## Goal

Give Claude Code a reliable, generic way to operate [dagu](https://github.com/dagu-org/dagu) workflow runs — start, watch, diagnose, stop, retry — without rediscovering the CLI surface and on-disk layout from scratch every session.

## Why

Transcript analysis across 36 conversations in `~/.claude/projects/-Users-eanderson-Finances*` and 15 in `-private-tmp-dagu-sandbox-test` surfaced a consistent set of failure modes when Claude was asked to operate dagu runs:

- **Rediscovery tax.** Every session re-derived the CLI surface (`dagu version` not `--version`, the existence of `dagu status`, `dagu history`, run-id flags) and the on-disk layout from scratch.
- **Wrong log paths.** Reached for `logs/admin/<dag>/` (admin is for the scheduler/server) instead of `logs/<dag>/`. Took multiple round-trips to find a per-step log because step files live one level deeper than the run dir.
- **Treating dagu as a black box.** Diagnosed pipeline issues by code-reading scripts instead of opening dagu's logs, even when the task explicitly invited it.
- **Trusting green status.** Multiple cases where dagu reported success while the underlying step exited 0 without doing work (notably the macOS `/var` ↔ `/private/var` symlink gotcha).
- **Scraping start's stdout.** `dagu start` returns immediately after queueing; the right move is `dagu status --run-id $ID`, but the default instinct was to `sleep 5 && cat <captured-output>`.
- **Foreground watching.** Long polls in the main agent burn cache and tokens. Anthropic's `ScheduleWakeup` and `/loop` primitives are purpose-built for this and were not used.

The skill must be **generic** (no repo-specific paths or DAG names hardcoded) so it can be reused across projects that drive workflows with dagu.

## Non-goals

- DAG authoring (writing the YAML). That's separate work and warrants its own skill if needed.
- Replacing the dagu web UI for inspection. The skill operates dagu via CLI and on-disk state.
- Multi-host / remote dagu (`dagu --context` flag). The skill assumes local dagu; remote-server operation can be a future extension.

## Architecture

### Plugin and file layout

```
~/src/github.com/ericanderson/claude-plugins/plugins/dagu/
├── .claude-plugin/
│   └── plugin.json              # name: "dagu", version 1.0.0
└── skills/
    └── using-dagu/
        ├── SKILL.md             # ~150-200 lines, always loaded when skill fires
        └── references/
            ├── cli.md           # full CLI reference (~150 lines)
            ├── on-disk.md       # full path/format reference (~120 lines)
            ├── watch-loop.md    # ScheduleWakeup-driven watch pseudocode (~80 lines)
            └── subagent-watch.md # alternative out-of-band subagent pattern (~50 lines)
```

Single skill (`using-dagu`) under a single plugin (`dagu`). No hooks — there is no wrong-CLI ambiguity to redirect away from, unlike the existing `git` plugin.

### Granularity and context strategy

One skill, with `references/` for lazy-loaded depth. Reasoning:

- **Shared facts** (paths, status codes, run-id conventions) are used across every dagu task. Splitting into multiple skills would duplicate them or require brittle cross-references.
- **Workflows interleave** — start → watch → drill → retry happens in one session, not as separate engagements.
- **Context isolation comes from subagent dispatch, not skill splitting.** When a watch needs to run out-of-band, the main agent dispatches a subagent that loads the same skill in its own context.

### What's inline vs in `references/`

**Inline in SKILL.md** (always loaded when skill fires):

- "First moves" rule: `dagu status <dag>` is the default; only fall back to filesystem inspection if the CLI is unresponsive.
- Compact CLI cheat sheet (10 commands, one line each, key flags inline).
- On-disk layout overview: paths only, one-liner each.
- "dagu green is not signal" trust principle.
- Watch-loop prescription: ScheduleWakeup-driven with state carry.
- Subagent dispatch pattern with explicit "when to use it."
- Common-mistakes prologue distilled from transcript analysis.

**`references/cli.md`** — per-subcommand full reference. Per command: purpose, full flag list with semantics, return behavior, representative example. Plus quirks: `dagu version` (not `--version`), `--context`, `-c`/`--config`.

**`references/on-disk.md`** — full path map and format reference. Resolved-paths table (derive from `dagu config`), tree diagram of `data/` and `logs/`, `status.jsonl` schema with status integer enum (0=pending, 1=running, 4=succeeded, plus failed/aborted/skipped values — to be confirmed by sampling real files), `.proc` file semantics, step-log filename grammar, zsh nullglob safety pattern.

**`references/watch-loop.md`** — full pseudocode for ScheduleWakeup watch. State-carry serialization format (compact, e.g. `step1:done,step2:running,step3:pending`), decision tree per tick, cache-TTL guidance (270s default, 1200s+ for slow runs), terminal-state output format, exit conditions.

**`references/subagent-watch.md`** — alternative dispatch pattern. When to use, subagent prompt template, what the subagent returns, why it's not the default.

**Not in the skill at all** (lives in each project's CLAUDE.md):

- Project-specific DAG names.
- Working directory / pipeline checkout paths.
- Repo-specific quirks and history.

## Components

### SKILL.md frontmatter (description)

```yaml
---
name: using-dagu
description: Use when the user asks to start, watch, check, diagnose, stop, or
  retry a dagu workflow run, or when poking at dagu DAGs, scheduler, history,
  or logs. Also use BEFORE tailing dagu log files or grepping dagu state on
  disk — `dagu status` is almost always the right first move.
---
```

The "BEFORE tailing dagu log files" anti-trigger is intentional — the most common failure mode in transcripts was the agent reaching for `tail -f` on log paths it half-remembered, instead of `dagu status`.

### SKILL.md body sections (in order)

1. **What dagu is and what this skill covers** — two sentences, scopes the skill to operating runs (not authoring DAGs).
2. **First moves (don't reach for files)** — THE rule: `dagu status <dag>` first. Includes the `dagu version` (not `--version`) gotcha.
3. **CLI cheat sheet** — compact table, pointer to `references/cli.md`.
4. **Where things live on disk** — three-bullet summary, pointer to `references/on-disk.md`.
5. **"dagu green is not signal"** — trust-the-filesystem principle, with the `/var` ↔ `/private/var` example.
6. **Watching a run to completion** — the prescribed ScheduleWakeup pattern, summarized. Pointer to `references/watch-loop.md`.
7. **When to dispatch a subagent instead** — out-of-band watching. Pointer to `references/subagent-watch.md`.
8. **Drilling into a failing step** — three-step pattern: status → read `.err` → optional `dagu retry --step`.
9. **Stopping or restarting** — `stop`, `restart`, `retry --run-id [--step]` semantics.
10. **Repo-specific knowledge** — handoff to project CLAUDE.md; ask the user if it's not documented.

### Watch loop mechanism

The skill prescribes **agent-driven `ScheduleWakeup`** with state carry as the default for "kick off and watch" requests:

1. **Main agent** runs `dagu start <dag>` (or notes the existing run) and captures the run ID.
2. **Main agent** does one `dagu status --run-id $ID` to set a baseline and reports current state to the user.
3. **Main agent** calls `ScheduleWakeup` with delay tuned to expected duration. Default 270s (stays in cache); longer (1200s+) for known-slow runs where the cache miss is amortized.
4. **On wake**, the agent re-reads status (preferably `data/dag-runs/.../status.jsonl` — machine-parseable, cheaper than CLI invocation), diffs against last-known state passed in via the wakeup prompt, surfaces new transitions, and decides whether to schedule again.
5. **On terminal state**, the agent reports a timeline summary and, if any step failed, drills into that step's `.err`.

Foreground polling and continuous subagent loops are explicitly *not* the default — they burn tokens and risk cache misses without real benefit.

### Subagent fallback

When the user is doing unrelated work and wants the watch fully out-of-band, the main agent dispatches a background subagent (using `run_in_background: true`) that owns its own `ScheduleWakeup` loop. The subagent loads the same `using-dagu` skill in its own context. Main agent gets one notification when the run reaches a terminal state and a final summary.

## Data flow

```
User: "kick off the dagu run and watch it"
  │
  ▼
Main agent invokes Skill(using-dagu) → SKILL.md body loads into context
  │
  ▼
Main agent runs `dagu start <dag>`, captures run_id
  │
  ▼
Main agent runs `dagu status --run-id $run_id`, reports baseline to user
  │
  ▼
Main agent calls ScheduleWakeup(delay=270s, prompt="check run $run_id, last state: <serialized>")
  │
  ▼ (agent returns control to user; runtime later re-fires)
  │
  ▼
On wake: agent re-reads status, diffs, surfaces transitions
  │
  ├─ non-terminal → ScheduleWakeup again with updated state
  └─ terminal → final summary, optional .err drill-in for failures
```

## Error handling

- **Daemon unresponsive.** If `dagu status` fails or hangs, fall back to checking `data/proc/<dag>/` (presence = alive) and reading `data/dag-runs/.../status.jsonl` directly.
- **CLI surface drift.** Skill is pinned against dagu 2.5.0 conventions; if a future version changes flags, the skill should be updated. References include exact flag names so drift is detectable.
- **Macros and globs.** zsh-specific glob behavior is called out in `references/on-disk.md`; the skill prescribes explicit paths over globs where possible.
- **Wakeup chain interruption.** If `ScheduleWakeup` chain breaks (user takes session in a different direction), no recovery is needed — the user can re-invoke the skill to resume watching.

## Testing

- **Skill metadata triggers correctly.** Manual: in a fresh session in `~/Finances`, ask "is the dagu run still going?" and verify the skill fires.
- **First-moves rule lands.** Manual: ask Claude to "check on the dagu run" and verify it runs `dagu status` before any filesystem inspection.
- **Watch loop works.** Manual: ask Claude to "kick off the financial-data dagu run and watch it." Verify (a) baseline reported, (b) ScheduleWakeup fires, (c) transitions surfaced, (d) terminal summary delivered, (e) any failures drilled into.
- **Subagent path works.** Manual: ask Claude to "watch the dagu run in the background while we do other work." Verify subagent dispatched, main agent free, completion notification arrives.
- **No regression on generic-ness.** Skill body must contain no path under `~/Finances`, no DAG name, no project-specific quirk. Self-review checklist before commit.

## Open questions

- **Status integer enum values.** Inline guess (0=pending, 1=running, 4=succeeded) is from a single observed file. Before locking values into `references/on-disk.md`, sample multiple `status.jsonl` files across run states (succeeded, failed, aborted, skipped, partially succeeded) to confirm the full enum.
- **`/loop` documentation.** The skill prescribes agent-driven `ScheduleWakeup`. Should the user-typeable `/loop` form be documented as well? Lean yes — it's a useful escape hatch when the user wants to take over pacing manually.

Both can be resolved during implementation without changing the architecture.

## Out of scope (potential follow-ups)

- A `dagu` plugin hook that intercepts `tail -f` of dagu log paths and redirects to the skill — possible but unclear value.
- Per-DAG slash commands (e.g. `/dagu-watch <run-id>`) — could wrap the skill behavior; not needed for v1.
- Remote dagu server support (`--context` flag) — additive when needed.
