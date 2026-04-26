---
name: using-dagu
description: Use when the user asks to start, watch, check, diagnose, stop, or
  retry a dagu workflow run, or when poking at dagu DAGs, scheduler, history,
  or logs. Also use BEFORE tailing dagu log files or grepping dagu state on
  disk — `dagu status` is almost always the right first move.
---

# Operating dagu workflow runs

[dagu](https://github.com/dagu-org/dagu) is a workflow orchestrator with a CLI (`dagu`), a daemon serving a web UI on `127.0.0.1:9090` by default, and on-disk state under a platform-specific data directory. **This skill covers operating runs** — start, watch, drill into failures, stop, retry. It does **not** cover authoring DAG YAML definitions.

## First moves: don't reach for files

When asked anything about a dagu run, **run `dagu status <dag-name>` before doing anything else.** It returns:

- Current state (running / succeeded / failed / etc).
- Per-step status with durations.
- Inline paths to each step's `.out` and `.err` log file.
- The dag-run ID, which you'll need for any drill-in.

Only fall back to filesystem inspection (under the dagu data/log dirs) when:

- The CLI is unresponsive or the daemon is down.
- You need machine-readable state for a watch loop (see `references/watch-loop.md`).

**Common gotchas:**

- The version flag is `dagu version` — `dagu --version` is rejected.
- `dagu start` returns immediately after queueing the run; it does **not** wait. To watch a run, capture its ID and poll `dagu status --run-id $ID`. Don't sleep-then-grep `dagu start`'s captured stdout.
- Step log files live one level deeper than the run dir (in `run_<ts>_<attemptId>/`), not at the top of the dag-run dir.

## CLI cheat sheet

The 10 commands you actually use. Full per-flag reference in `references/cli.md`.

| Command | Purpose |
|---------|---------|
| `dagu status [<dag>] [--run-id ID]` | Pretty tree of the latest (or specific) run with per-step state and log paths. |
| `dagu history [<dag>] [--last 7d \| --from … --to …] [--status STATE] [--format json]` | List runs filtered by time/state. JSON for scripting. |
| `dagu start <dag> [-- params]` | Queue a new run. Returns immediately. Capture run ID for follow-up. |
| `dagu enqueue <dag>` | Like `start` but goes through the queue (respects concurrency). |
| `dagu stop [<dag>] [--run-id ID]` | Graceful termination — runs cleanup handlers. |
| `dagu restart <dag> [--run-id ID]` | Stop + new run with same params. |
| `dagu retry --run-id ID [--step NAME] <dag>` | Retry a previous run, optionally just one step. |
| `dagu dry <dag>` | Simulate without executing. |
| `dagu validate <dag>` | Check DAG YAML for errors. |
| `dagu cleanup [--retention-days N] [--dry-run] <dag>` | Prune old run history. |

The `dagu status [<dag>]` form (no run-id) shows the most recent run — usually what you want.

## Where things live on disk

Three layers, all derivable from `dagu config`:

- **DAG definitions** in the configured `dags_dir` (often a separate git repo).
- **Runtime state** under `data/`: dag-runs, queue, proc files (liveness), scheduler state.
- **Logs** under `logs/`: per-run subdirectories with both DAG-level and per-step `.out`/`.err` files.

For exact paths, the `status.jsonl` schema, the integer status enum, and the log filename grammar, see `references/on-disk.md`.

## "dagu green is not signal"

A step exiting 0 is **not** proof it did real work. Verify dagu success against filesystem evidence:

- Did the step write the files it was supposed to write?
- Did expected commits land?
- Did downstream artifacts update?

This isn't paranoia — it bites. The macOS `/var` ↔ `/private/var` symlink has caused steps to silently exit 0 when an `import.meta.url` check failed under dagu's worktree paths, while dagu reported success for over a week. When in doubt, check the artifacts, not the badge.

## Watching a run to completion

When the user wants a run watched until terminal, use **agent-driven `ScheduleWakeup`** with state carry. Don't poll in a foreground loop; don't dispatch a subagent for the watch unless the user explicitly wants it out-of-band.

The flow:

1. Run `dagu start <dag>` (or identify the existing run from `dagu status`); capture the run ID.
2. Run `dagu status --run-id $ID` once for a baseline; report current state to the user.
3. Call `ScheduleWakeup` with delay tuned to the run's expected duration:
   - Default **270s** to stay inside the 5-minute prompt-cache TTL.
   - Use **1200s+** for runs known to take 20+ minutes — one cache miss buys a long wait.
4. Pass a self-contained prompt that includes the run ID and a compact serialization of last-known step states (e.g. `step1:done,step2:running,step3:pending`).
5. On wake: re-read status, diff against last state, surface new transitions to the user, schedule again if non-terminal.
6. On terminal: report a timeline summary. If any step failed, drill into its `.err`.

Full pseudocode and the state-carry format are in `references/watch-loop.md`.

## When to dispatch a subagent instead

Default is `ScheduleWakeup` in the main agent. **Switch to a background subagent only when** the user wants the watch fully out-of-band while doing unrelated work in the main session.

The subagent loads this same skill in its own context, owns its own wakeup loop, and reports back one final summary. See `references/subagent-watch.md` for the dispatch template.

Why not the default: it's heavier (full subagent context per watch) and the main agent loses real-time visibility into transitions.

## Drilling into a failing step

1. `dagu status --run-id $ID` — the failing step's `.err` path is in the output.
2. `Read` the `.err` file directly (paths are exact; no globbing needed).
3. To retry just that step: `dagu retry --run-id $ID --step <name> <dag>`.

If you must glob for step logs (e.g. you only have the run dir), set `set +o nomatch` first in zsh — bare `<step>.*.err` errors with `no matches found` instead of expanding to nothing.

## Stopping or restarting

- `dagu stop <dag>` — graceful, runs cleanup handlers. Use `--run-id ID` to target a specific run; without it, stops all running runs of the named DAG.
- `dagu restart <dag> [--run-id ID]` — stop + new run with the same parameters.
- `dagu retry --run-id ID [--step NAME] <dag>` — preserves the original run ID; with `--step`, retries only that step.

## Repo-specific knowledge

This skill is generic. Every project that uses dagu has its own:

- DAG name(s).
- Working directory / pipeline checkout location (often distinct from where the user has the repo checked out).
- DAG YAML repo location (often a separate git repo, auto-pulled by dagu's git_sync).
- Project-specific quirks (silent-exit traps, slug drift, etc.).

**Look in the project's `CLAUDE.md` first.** If it doesn't say, ask the user — don't guess paths.
