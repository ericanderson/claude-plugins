# Dagu on-disk layout reference

Path/format reference for everything dagu writes to disk during a DAG run. Use this when writing watch loops, log scrapers, or any tool that needs to read run state directly rather than going through the `dagu` CLI.

## Resolving paths

The canonical move is to ask dagu itself:

```
$ dagu config
```

This prints all resolved paths. Don't hardcode — the data directory differs by OS:

- macOS: `~/Library/Application Support/dagu/`
- Linux: typically `~/.local/share/dagu/`

Example output (with `<HOME>` as a placeholder for the user's home):

```
DAGs directory:    <HOME>/src/github.com/<user>/dagu-dags
Config file:       <HOME>/.config/dagu/config.yaml
Data directory:    <HOME>/Library/Application Support/dagu/data
Logs directory:    <HOME>/Library/Application Support/dagu/logs
Suspend dir:       <HOME>/Library/Application Support/dagu/data/suspend
Admin logs:        <HOME>/Library/Application Support/dagu/logs/admin
```

The two roots that matter for reading run state are **`data/`** and **`logs/`** — described below.

## Tree of `data/`

```
data/
├── dag-runs/
│   └── <dag>/
│       └── dag-runs/YYYY/MM/DD/
│           └── dag-run_<UTCstamp>_<runId>/
│               └── attempt_<stamp>_<attemptId>/
│                   ├── status.jsonl   ← append-only state-machine log; one JSON object per status update
│                   ├── dag.json       ← snapshot of the DAG definition at run time
│                   └── work/          ← scratch dir for the run
├── proc/
│   └── <dag>/<dag>/proc_*.proc        ← heartbeat. Mere presence ⇒ run is alive.
├── queue/
│   └── <dag>/                         ← pending runs awaiting executor
├── scheduler/                         ← cron state
└── gitsync/                           ← git state for dagu's dags_dir repo (when git_sync is enabled)
```

Note the doubled `<dag>/<dag>/` segment under `data/proc/` — that's not a typo, that's how dagu lays it out.

## Tree of `logs/`

```
logs/
├── admin/                             ← server/scheduler logs. NOT DAG runs.
│                                        Common confusion — don't look here for run output.
└── <dag>/
    └── dag-run_<UTCstamp>_<runId>/
        ├── dag-run_<localstamp>.<runIdShort>.log     ← DAG-level combined log
        └── run_<UTCstamp>_<attemptId>/
            ├── <step>.<localstamp>.<runIdShort>.out   ← per-step stdout
            └── <step>.<localstamp>.<runIdShort>.err   ← per-step stderr
```

Per-step logs sit **one level deeper** than the dag-run dir — inside a `run_<UTCstamp>_<attemptId>/` subdir, not next to the combined `.log` file.

## `status.jsonl` schema

Format: append-only JSONL, one JSON object per status change. **The last line is the most recent state.** Tail it; don't try to parse historical entries unless you're rebuilding a timeline.

Top-level fields used by the watch loop:

| Field | Meaning |
|-------|---------|
| `dagRunId` | UUID of this DAG run |
| `attemptId` | UUID of this attempt (one run can have multiple attempts via auto-retry) |
| `attemptKey` | Composite key for the attempt |
| `name` | DAG name |
| `status` | Integer — see top-level enum below |
| `triggerType` | What kicked off the run (e.g. `scheduler`, `manual`) |
| `pid` | Process ID of the running dagu agent (if alive) |
| `nodes[]` | Per-step state — see node fields below |
| `startedAt` | ISO timestamp |
| `finishedAt` | ISO timestamp (empty/zero while running) |
| `log` | Path to the DAG-level combined log file |
| `procGroup` | Process group identifier |

Per-step fields under `nodes[]`:

| Field | Meaning |
|-------|---------|
| `step.name` | Step name from the DAG definition |
| `step.commands[].cmdWithArgs` | Resolved command line |
| `step.depends[]` | Names of upstream steps this one waits for |
| `status` | Integer — see node enum below |
| `stdout` | Path to this step's `.out` file |
| `stderr` | Path to this step's `.err` file |
| `startedAt` | ISO timestamp |
| `finishedAt` | ISO timestamp |
| `doneCount` | Counter incremented on completion (used for repeated steps) |

### Top-level `status` enum (full DAG run state)

Confirmed by sampling 53 runs:

| Int | Name | Notes |
|-----|------|-------|
| 1 | `running` | Run is currently executing. |
| 2 | `failed` | Run reached terminal failure (after auto-retries exhausted). |
| 4 | `succeeded` | All steps completed successfully. |
| 5 | `queued` | Transient state between failed attempt and next auto-retry. |
| 6 | `partially_succeeded` | Some steps succeeded, others failed; reached terminal. |

Other names exist in the `dagu history --status` enum but were **not observed in samples** — value not yet confirmed by sampling: `aborted`, `waiting`, `rejected`, `not_started`, `skipped`.

### Node `status` enum (per-step state)

| Int | Likely name | Notes |
|-----|-------------|-------|
| 0 | `not_started` | Step has not yet run (still pending in the DAG). |
| 1 | `running` | Step is currently executing. |
| 2 | `failed` | Step exited non-zero (or was reported as failed). |
| 3 | `cancelled` | Inferred — observed only on downstream steps after a dependency failure. |
| 4 | `succeeded` | Step exited 0. |

The node enum integers are inferred from observed behavior, not from a confirmed source. Treat the names as best-guess until cross-referenced against dagu's source.

## `.proc` heartbeat file

Lives under `data/proc/<dag>/<dag>/proc_*.proc` (note the doubled `<dag>` segment).

Small JSON-ish content with:

- `version`
- `dag_name`
- `dag_run_id`
- `attempt_id`
- `started_at`

**Presence semantics:** if the file exists, dagu considers the run alive. Absence means the run is not currently executing — either it reached a terminal state or it never started. Use this as a cheap liveness check before parsing `status.jsonl`.

## Step-log filename grammar

The step-log filename pattern:

```
<step>.<YYYYMMDD>.<HHMMSS>.<ms>.<runIdShort>.{out,err}
```

- `<step>` — step name from the DAG definition
- `<YYYYMMDD>.<HHMMSS>.<ms>` — local timestamp the file was opened
- `<runIdShort>` — first 8 chars of the run UUID
- `.out` / `.err` — stdout vs stderr

Lives in `run_<UTCstamp>_<attemptId>/` inside the dag-run dir under `logs/<dag>/dag-run_<UTCstamp>_<runId>/`.

## zsh nullglob trap

Bare globs like `<step>.*.err` in zsh **fail the whole command** if no matches:

```
$ cat mystep.*.err
zsh: no matches found: mystep.*.err
```

Workarounds, in order of preference:

1. **Best:** get the exact path from `dagu status` output (or read it directly from `nodes[].stderr` in `status.jsonl`) and use that — no globbing needed.
2. List the directory explicitly with `ls` or `find`:
   ```
   find run_*/ -name 'mystep.*.err'
   ```
3. As a last resort, opt into bash-style behavior for the shell:
   ```
   setopt null_glob
   ```

Prefer option 1. The exact path is always available — there's no reason to glob.
