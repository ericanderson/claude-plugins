# dagu CLI reference

Per-subcommand reference for the 10 commands the SKILL.md cheat sheet uses. Authoritative source is `dagu <cmd> --help`.

## Common flags

These appear on every subcommand below and are omitted from the per-command tables:

| Flag | Type | Behavior |
|------|------|----------|
| `-h`, `--help` | bool | Show help for the subcommand. |
| `-q`, `--quiet` | bool | Suppress output during the run. |
| `--cpu-profile` | bool | Enable CPU profiling (writes `cpu.pprof`). |
| `-c`, `--config` | string | Path to alternate config file (default `$HOME/.config/dagu/config.yaml`). |
| `--dagu-home` | string | Override `DAGU_HOME` for this command. |

Global flag (applies to every subcommand): `--context <name>` — selects a non-local dagu server context.

---

## `dagu status`

**Purpose** — Show real-time status of a DAG-run instance.

**Synopsis** — `dagu status [flags] <DAG name>`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-r`, `--run-id` | string | no | Specific dag-run ID to inspect. Without it, shows the most recent run. |
| `-s`, `--sub-run-id` | string | no | Sub dag-run ID for nested runs. Requires `--run-id`. |

**Returns** — Prints state (running, completed, failed), PID, and run details to stdout. Exits 0 on success, non-zero if the DAG or run is not found. Read-only — does not affect the run.

**Example**

```
dagu status --run-id=abc123 my_dag
```

---

## `dagu history`

**Purpose** — Display execution history of past DAG runs with filtering.

**Synopsis** — `dagu history [flags] [DAG name]`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-f`, `--format` | string | no | Output format: `table` (default), `json`, or `csv`. |
| `--from` | string | no | UTC start date/time (`2006-01-02` or `2006-01-02T15:04:05Z`). |
| `--to` | string | no | UTC end date/time. |
| `--last` | string | no | Relative period (e.g. `7d`, `24h`, `1w`). Mutually exclusive with `--from`/`--to`. |
| `-l`, `--limit` | string | no | Max results, default 100, max 1000. |
| `--run-id` | string | no | Filter by run ID (partial match supported). |
| `--status` | string | no | Filter by status: `running`, `succeeded`, `failed`, `aborted`, `queued`, `waiting`, `rejected`, `not_started`, `partially_succeeded`. |
| `--tags` | string | no | Comma-separated DAG tags, AND logic. |

**Returns** — Prints history rows in the chosen format to stdout. Exits 0. Read-only. Default window is last 30 days, newest first, all UTC.

**Example**

```
dagu history --last 7d --status failed --format json
```

---

## `dagu start`

**Purpose** — Begin executing a DAG, creating a new run with a unique ID.

**Synopsis** — `dagu start [flags] <DAG definition> [-- param1 param2 ...]`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-r`, `--run-id` | string | no | Assign a specific dag-run ID instead of an auto-generated one. |
| `-N`, `--name` | string | no | Override the DAG name. |
| `-p`, `--params` | string | no | Parameters to pass into the run. |
| `--tags` | string | no | Additional tags applied to this run. |
| `--from-run-id` | string | no | Use a historic run ID as the template for the new run. |
| `--default-working-dir` | string | no | Default working directory for steps without explicit `workingDir`. |
| `--trigger-type` | string | no | How the run was initiated. Default `manual`. |
| `--schedule-time` | string | no | RFC 3339 timestamp. Set by the scheduler — not for manual use. |
| `--worker-id` | string | no | Worker ID. Auto-set in distributed mode. |

Positional parameters after `--` are passed as run parameters (positional or `key=value`).

**Returns** — Queues the run and returns immediately with the new run ID printed to stdout. Exit 0 on successful queueing — **does not block on completion**. To watch the run, capture the run ID and poll `dagu status --run-id <id>` (see SKILL.md "Watching a run to completion").

**Example**

```
dagu start my_dag -- P1=foo P2=bar
```

---

## `dagu enqueue`

**Purpose** — Submit a run through the queue (respects per-DAG concurrency) instead of starting immediately.

**Synopsis** — `dagu enqueue [flags] <DAG definition> [-- param1 param2 ...]`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-r`, `--run-id` | string | no | Assign a specific dag-run ID. |
| `-N`, `--name` | string | no | Override the DAG name. |
| `-p`, `--params` | string | no | Parameters. |
| `-u`, `--queue` | string | no | Override the DAG-level queue definition. |
| `--tags` | string | no | Additional tags. |
| `--default-working-dir` | string | no | Default working directory. |
| `--trigger-type` | string | no | How initiated. Default `manual`. |
| `--schedule-time` | string | no | RFC 3339 timestamp (scheduler use). |

**Returns** — Adds the run to the queue and returns immediately. Exit 0 on successful enqueue — **does not block on completion**. The scheduler picks it up when concurrency allows. To watch, poll `dagu status --run-id <id>`.

**Example**

```
dagu enqueue --run-id=run_id my_dag -- P1=foo P2=bar
```

---

## `dagu stop`

**Purpose** — Gracefully terminate an active DAG-run.

**Synopsis** — `dagu stop [flags] <DAG name>`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-r`, `--run-id` | string | no | Specific dag-run ID to stop. With it, can also cancel a failed root run still pending DAG-level auto-retry. |

**Returns** — Sends termination signals, waits for cleanup handlers to finish, then exits 0. Unlike `start`/`enqueue`, this **blocks until graceful shutdown completes**.

**Example**

```
dagu stop --run-id=abc123 my_dag
```

---

## `dagu restart`

**Purpose** — Stop a running DAG-run and immediately re-launch it with the same configuration but a new run ID.

**Synopsis** — `dagu restart [flags] <DAG name>`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-r`, `--run-id` | string | no | dag-run ID to restart. |
| `--schedule-time` | string | no | RFC 3339 timestamp (scheduler use). |

**Returns** — Stops the existing run (graceful), then queues a new run with a fresh ID and returns immediately. Exits 0 once the new run is queued — does not wait for it to complete.

**Example**

```
dagu restart --run-id=abc123 my_dag
```

---

## `dagu retry`

**Purpose** — Create a new run for a previously executed DAG-run, reusing the same DAG-run ID.

**Synopsis** — `dagu retry [flags] <DAG name or file>`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-r`, `--run-id` | string | **yes** | Run ID to retry. Required. |
| `--step` | string | no | Retry only the named step. |
| `--default-working-dir` | string | no | Default working directory. |
| `--worker-id` | string | no | Worker ID. |

**Returns** — Re-runs the targeted DAG-run (or single step) and returns once queued. Exits 0 on successful submission. Errors out if `--run-id` is missing.

**Example**

```
dagu retry --run-id=abc123 my_dag
```

---

## `dagu dry`

**Purpose** — Simulate a DAG-run without executing any real actions. No side effects.

**Synopsis** — `dagu dry [flags] <DAG definition> [-- param1 param2 ...]`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `-N`, `--name` | string | no | Override the DAG name. |
| `-p`, `--params` | string | no | Parameters. |

**Returns** — Walks the DAG, prints the planned execution to stdout, and exits 0 if the simulation completes. Side-effect free.

**Example**

```
dagu dry my_dag.yaml -- P1=foo P2=bar
```

---

## `dagu validate`

**Purpose** — Validate a DAG YAML file without executing it. Mirrors server-side spec validation (structure, step dependency references).

**Synopsis** — `dagu validate [flags] <DAG definition>`

**Flags** — none beyond the common flags.

**Returns** — Prints a human-readable validation result. Exits 0 if the DAG is valid, non-zero if any errors are found.

**Example**

```
dagu validate my_dag.yaml
```

---

## `dagu cleanup`

**Purpose** — Delete old DAG-run history for a specified DAG. Active runs are never deleted.

**Synopsis** — `dagu cleanup [flags] <DAG name>`

**Flags**

| Flag | Type | Required? | Behavior |
|------|------|-----------|----------|
| `--retention-days` | string | no | Days of history to retain. `0` = delete all. |
| `--dry-run` | bool | no | Preview deletions without performing them. |
| `-y`, `--yes` | bool | no | Skip the confirmation prompt. |

**Returns** — Removes matching history entries (or just lists them under `--dry-run`) and exits 0 on success. Without `-y`, prompts interactively before deleting — wire `-y` for automation.

**Example**

```
dagu cleanup --retention-days 30 -y my-workflow
```

---

## Quirks

- **Version flag**: `dagu version` is a subcommand. There is no `dagu --version`.
- **Remote contexts**: `--context <name>` is a global flag selecting a configured remote dagu server. Defaults to the current context (or `local`).
- **Alternate config**: `-c` / `--config` points at a config file other than `$HOME/.config/dagu/config.yaml` for a single invocation.
- **Per-command data dir**: `--dagu-home <dir>` overrides `DAGU_HOME` for the current command only — useful for poking at an isolated checkout (e.g. the dagu pipeline checkout) without exporting the env var globally.
