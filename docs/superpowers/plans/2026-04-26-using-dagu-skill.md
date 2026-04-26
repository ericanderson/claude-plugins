# `using-dagu` Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a generic `using-dagu` skill (under a new `dagu` plugin) that teaches Claude how to operate dagu workflow runs reliably — start, watch via `ScheduleWakeup`, drill into failures, stop/retry — without rediscovering the CLI surface or on-disk layout from scratch.

**Architecture:** One plugin (`dagu`), one skill (`using-dagu`), four lazily-loaded `references/` files for depth. The skill body prescribes `dagu status` as the first move and `ScheduleWakeup`-driven watching as the default for run monitoring. Repo-specific facts (DAG names, working dirs) stay in each project's CLAUDE.md.

**Tech Stack:** Markdown + YAML frontmatter; Claude Code skill loader; dagu 2.5.0 CLI as the surface being documented.

**Spec:** [`docs/superpowers/specs/2026-04-26-using-dagu-skill-design.md`](../specs/2026-04-26-using-dagu-skill-design.md)

---

## File Structure

All paths are relative to `~/src/github.com/ericanderson/claude-plugins/`.

| File | Responsibility |
|------|---------------|
| `plugins/dagu/.claude-plugin/plugin.json` | Plugin metadata: name, version, description. |
| `plugins/dagu/skills/using-dagu/SKILL.md` | Always-loaded skill body: first-moves rule, CLI cheat sheet, on-disk overview, watch-loop prescription, subagent fallback, drill/stop/retry sections. |
| `plugins/dagu/skills/using-dagu/references/cli.md` | Per-subcommand full reference for the 10 commands the skill names. |
| `plugins/dagu/skills/using-dagu/references/on-disk.md` | Path map, `status.jsonl` schema with confirmed integer enum, log filename grammar. |
| `plugins/dagu/skills/using-dagu/references/watch-loop.md` | ScheduleWakeup-driven watch pseudocode, state-carry format, terminal handling. |
| `plugins/dagu/skills/using-dagu/references/subagent-watch.md` | Out-of-band subagent dispatch pattern. |

---

## Verification Note

This is a documentation skill, not code. The "tests" in this plan are:
1. **Schema/structural checks** — `plugin.json` validates as JSON; SKILL.md frontmatter is valid YAML; markdown link references resolve.
2. **Behavioral checks** — manual: trigger the skill in a fresh Claude Code session, verify the prescribed first move (`dagu status`) and watch loop fire as designed.

Each task that produces a file ends with a JSON/YAML/markdown sanity check before committing.

---

### Task 1: Plugin scaffolding

**Files:**
- Create: `plugins/dagu/.claude-plugin/plugin.json`

- [ ] **Step 1: Create plugin manifest**

Write `plugins/dagu/.claude-plugin/plugin.json` with:

```json
{
  "name": "dagu",
  "description": "Helpers for operating dagu workflow runs (start, watch, diagnose, stop, retry). Ships a generic using-dagu skill; repo-specific DAG names and paths stay in each project's CLAUDE.md.",
  "version": "1.0.0"
}
```

- [ ] **Step 2: Validate JSON**

Run: `python3 -m json.tool plugins/dagu/.claude-plugin/plugin.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/dagu/.claude-plugin/plugin.json
git commit -m "feat(dagu): scaffold dagu plugin manifest"
```

---

### Task 2: SKILL.md — frontmatter, rule, and CLI/on-disk overview

This task creates SKILL.md with the locked frontmatter and the first half of the body (sections 1–5 of the 10-section outline). Section pointers to `references/*.md` files are written now even though those files don't exist yet — they'll be added in later tasks.

**Files:**
- Create: `plugins/dagu/skills/using-dagu/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

```markdown
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
```

- [ ] **Step 2: Validate frontmatter is parseable YAML**

Run:

```bash
python3 -c "
import sys, re, yaml
with open('plugins/dagu/skills/using-dagu/SKILL.md') as f: txt = f.read()
m = re.match(r'^---\n(.*?)\n---', txt, re.DOTALL)
assert m, 'no frontmatter'
fm = yaml.safe_load(m.group(1))
assert fm['name'] == 'using-dagu', fm
assert 'description' in fm and len(fm['description']) > 50
print('OK')
"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/dagu/skills/using-dagu/SKILL.md
git commit -m "feat(dagu): SKILL.md with first-moves rule, CLI cheat sheet, watch loop"
```

---

### Task 3: `references/cli.md` — full per-subcommand reference

**Files:**
- Create: `plugins/dagu/skills/using-dagu/references/cli.md`

The file documents all 10 commands the cheat sheet names, plus the gotchas. Pull exact flag names and semantics from `dagu <cmd> --help` (run them while writing — do not paraphrase from memory).

- [ ] **Step 1: Capture authoritative help text for each command**

Run and save (in scratch, not committed):

```bash
for cmd in status history start enqueue stop restart retry dry validate cleanup; do
  echo "=== $cmd ==="
  dagu "$cmd" --help 2>&1
done > /tmp/dagu-help.txt
```

This is the source of truth for what flags each command takes. Refer to it while writing the reference.

- [ ] **Step 2: Write `references/cli.md`**

Structure: one H2 per command, each section contains:

- **Purpose** — one sentence.
- **Synopsis** — `dagu <cmd> [flags] <args>` skeleton.
- **Flags** — table (Flag | Type | Required? | Behavior). Pull exact names from the captured `--help` output.
- **Returns** — what the command does on success and exit behavior (in particular: `dagu start` returns immediately after queueing).
- **Example** — one representative invocation.

End with a "Quirks" section covering:

- `dagu version` (no `--version`).
- Global `--context <name>` for remote dagu servers.
- `-c`/`--config` to point at an alternate config file.
- `--dagu-home` to override the data directory for one command.

Aim for ~150 lines. No code that's not a literal `dagu` invocation.

- [ ] **Step 3: Validate links and basic structure**

Run:

```bash
python3 -c "
with open('plugins/dagu/skills/using-dagu/references/cli.md') as f: txt = f.read()
for cmd in ['status','history','start','enqueue','stop','restart','retry','dry','validate','cleanup']:
    assert f'## {cmd}' in txt.lower() or f'## \`dagu {cmd}\`' in txt or f'## dagu {cmd}' in txt, f'missing section for {cmd}'
print('OK')
"
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add plugins/dagu/skills/using-dagu/references/cli.md
git commit -m "feat(dagu): full CLI reference for using-dagu skill"
```

---

### Task 4: `references/on-disk.md` — paths, schema, log filename grammar

**Files:**
- Create: `plugins/dagu/skills/using-dagu/references/on-disk.md`

This task includes confirming the `status.jsonl` integer status enum by sampling real run files. The spec lists this as an open question.

- [ ] **Step 1: Confirm status integer enum**

Sample status integers across runs of varying outcome. Run:

```bash
python3 <<'EOF'
import json, glob
seen_top = {}
seen_node = {}
files = glob.glob(
    f'{__import__("os").path.expanduser("~")}/Library/Application Support/dagu/data/'
    'dag-runs/*/dag-runs/*/*/*/dag-run_*/attempt_*/status.jsonl'
)
for f in files:
    try: lines = open(f).read().splitlines()
    except: continue
    for line in lines:
        try: d = json.loads(line)
        except: continue
        seen_top[d.get('status')] = seen_top.get(d.get('status'), 0) + 1
        for n in d.get('nodes', []):
            seen_node[n.get('status')] = seen_node.get(n.get('status'), 0) + 1
print('top-level status integers seen:', sorted(seen_top.items()))
print('node status integers seen:', sorted(seen_node.items()))
EOF
```

Cross-reference each integer against the corresponding DAG-name + run-id outcome from `dagu history --format json --limit 100`. The mapping you find — including any not yet observed in the local data — should be documented in the reference. Known names from `dagu schema` and `dagu history --status` flag values: `not_started`, `running`, `succeeded`, `failed`, `aborted`, `queued`, `waiting`, `rejected`, `partially_succeeded`, `skipped`.

- [ ] **Step 2: Write `references/on-disk.md`**

Sections, in order:

1. **Resolving paths** — the canonical move is `dagu config`. Show its output (placeholder values; the actual paths are user-specific). Note that the data directory differs by OS (macOS: `~/Library/Application Support/dagu/`, Linux: typically `~/.local/share/dagu/`).
2. **Tree of `data/`** — annotated:
   - `data/dag-runs/<dag>/dag-runs/YYYY/MM/DD/dag-run_<UTCstamp>_<runId>/attempt_<stamp>_<attemptId>/{status.jsonl,dag.json}`
   - `data/dag-runs/.../work/`
   - `data/proc/<dag>/<dag>/proc_*.proc`
   - `data/queue/<dag>/`
   - `data/scheduler/`
   - `data/gitsync/` (if dagu manages a DAG repo via git_sync)
3. **Tree of `logs/`** — annotated:
   - `logs/admin/` (server/scheduler logs — *not* DAG runs; common confusion)
   - `logs/<dag>/dag-run_<UTCstamp>_<runId>/dag-run_<localstamp>.<runIdShort>.log` (combined DAG-level)
   - `logs/<dag>/dag-run_*/run_<UTCstamp>_<attemptId>/<step>.<localstamp>.<runIdShort>.{out,err}` (per-step; one level deeper than the dag-run dir)
4. **`status.jsonl` schema** — append-only state machine, one JSON object per status change. Document every top-level field used by the watch loop: `dagRunId`, `attemptId`, `status` (integer, see enum), `triggerType`, `pid`, `nodes[]`, `startedAt`, `finishedAt`, `log`. For `nodes[]` document `step.name`, `status`, `stdout`, `stderr`, `startedAt`, `finishedAt`, `doneCount`. The status integer enum table (from Step 1).
5. **`.proc` file** — small JSON-ish heartbeat under `data/proc/<dag>/<dag>/`. Mere presence ⇒ run is alive and dagu is tracking it; absence ⇒ run is not currently executing.
6. **Step-log filename grammar** — explicit regex: `<step>\.<YYYYMMDD>\.<HHMMSS>\.<ms>\.<runIdShort>\.(out|err)`. Note the `runIdShort` is the first 8 chars of the run UUID.
7. **zsh nullglob trap** — bare `<step>.*.err` in zsh fails the whole command if no match. Either `setopt null_glob` first, or list the directory explicitly with `ls`/`find`.

Aim for ~120 lines.

- [ ] **Step 3: Validate sections present**

Run:

```bash
python3 -c "
with open('plugins/dagu/skills/using-dagu/references/on-disk.md') as f: txt = f.read()
for needle in ['status.jsonl', '.proc', 'step-log', 'nullglob', 'logs/admin']:
    assert needle in txt, f'missing: {needle}'
print('OK')
"
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add plugins/dagu/skills/using-dagu/references/on-disk.md
git commit -m "feat(dagu): on-disk layout reference with status.jsonl schema"
```

---

### Task 5: `references/watch-loop.md` — ScheduleWakeup pseudocode

**Files:**
- Create: `plugins/dagu/skills/using-dagu/references/watch-loop.md`

- [ ] **Step 1: Write `references/watch-loop.md`**

Sections:

1. **When to use this** — user wants a run watched to completion in the main session.
2. **State-carry format** — compact serialization passed in the wakeup prompt so the next firing knows what's new without re-reading history. Format:

   ```
   <step1>:<state>,<step2>:<state>,<step3>:<state>
   ```

   States: `pending`, `running`, `done`, `failed`, `skipped`. Example:

   ```
   sync-repo:done,catch-up:done,snaptrade-pull:running,plaid-pull:pending,finish:pending,prices:pending,reports:pending,push:pending,mirror-user-checkout:pending
   ```

3. **Per-tick decision tree** —

   ```
   read status (prefer status.jsonl tail; fall back to `dagu status --run-id $ID`)
   parse current node states
   diff against last-known states (passed in via wakeup prompt)
   for each transition:
     report it to the user as a single line: "[<HH:MM:SS>] <step>: <old> → <new>"
   if any node is in a failed state with no continueOn: read its .err and surface a short excerpt
   classify overall:
     - all nodes terminal → emit final timeline summary, do NOT schedule again
     - any node running → ScheduleWakeup again with updated state carry
     - run-level status is failed/aborted → emit summary + relevant .err, do NOT schedule again
   ```

4. **Cache-TTL guidance** —
   - Default delay: **270s** — stays inside the 5-minute prompt-cache TTL.
   - Slow runs (known to take >20 min): **1200s+** — pay the cache miss once for a long wait.
   - Don't pick **300s** — worst of both: cache miss without amortization.

5. **Terminal-state output format** — a single message to the user:

   ```
   <dag-name> run <run-id-short> finished: <status>  (<duration>)

   Timeline:
     [HH:MM:SS] step1: <duration>  ✓
     [HH:MM:SS] step2: <duration>  ✓
     [HH:MM:SS] step3: <duration>  ✗ failed
       (excerpt from .err)

   Logs: <path-to-dag-run-dir>
   ```

6. **Exit conditions** — terminal status, user interruption (skill is naturally pre-empted by next user message), max-tick safety bound (e.g. 100 ticks).

Aim for ~80 lines.

- [ ] **Step 2: Validate sections present**

Run:

```bash
python3 -c "
with open('plugins/dagu/skills/using-dagu/references/watch-loop.md') as f: txt = f.read()
for needle in ['state-carry', 'ScheduleWakeup', '270s', 'terminal']:
    assert needle.lower() in txt.lower(), f'missing: {needle}'
print('OK')
"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/dagu/skills/using-dagu/references/watch-loop.md
git commit -m "feat(dagu): ScheduleWakeup-driven watch loop reference"
```

---

### Task 6: `references/subagent-watch.md` — out-of-band fallback

**Files:**
- Create: `plugins/dagu/skills/using-dagu/references/subagent-watch.md`

- [ ] **Step 1: Write `references/subagent-watch.md`**

Sections:

1. **When to use this** — user wants the run watched while they continue unrelated work in the main session. Default is in-session `ScheduleWakeup`; only switch when the user asks for out-of-band handling.

2. **Subagent prompt template** — what to pass in the `Agent` tool invocation:

   ```
   Watch dagu run <run-id> of DAG <dag-name> until it reaches a terminal
   state. Use the `using-dagu` skill (Skill tool, name=using-dagu) and
   the watch-loop reference within it. Cadence: ScheduleWakeup every
   <N>s. Expected duration: ~<minutes> minutes.

   On terminal state, return:
   - Final status (succeeded / failed / aborted / partially_succeeded).
   - Total duration.
   - Per-step timeline.
   - For any failed step: excerpt of its .err and the full path to it.

   Keep your final summary under 200 words.
   ```

3. **Dispatch parameters** —
   - `subagent_type: general-purpose`
   - `run_in_background: true`
   - `description: "Watch dagu run <run-id-short>"`

4. **What the subagent returns** — the main agent gets one notification when the subagent completes. Surface its summary to the user verbatim, then offer: "Want me to drill into the failing step?" if applicable.

5. **Why this is not the default** — repeats the trade-off: heavier (full subagent context per watch), main agent loses real-time visibility, only worth it when the user explicitly wants out-of-band.

Aim for ~50 lines.

- [ ] **Step 2: Validate sections present**

Run:

```bash
python3 -c "
with open('plugins/dagu/skills/using-dagu/references/subagent-watch.md') as f: txt = f.read()
for needle in ['run_in_background', 'general-purpose', 'using-dagu', 'terminal']:
    assert needle in txt, f'missing: {needle}'
print('OK')
"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugins/dagu/skills/using-dagu/references/subagent-watch.md
git commit -m "feat(dagu): subagent-driven out-of-band watch reference"
```

---

### Task 7: Verify cross-file references resolve

The skill body and references point at each other. This task confirms every pointer resolves to an existing file/section.

- [ ] **Step 1: Resolve all `references/*.md` pointers**

Run:

```bash
python3 <<'EOF'
import re, os
root = 'plugins/dagu/skills/using-dagu'
broken = []
for dirpath, _, files in os.walk(root):
    for fname in files:
        if not fname.endswith('.md'): continue
        path = os.path.join(dirpath, fname)
        with open(path) as f: txt = f.read()
        for m in re.finditer(r'`?references/([a-z0-9-]+\.md)`?', txt):
            target = os.path.join(root, 'references', m.group(1))
            if not os.path.exists(target):
                broken.append((path, m.group(0)))
if broken:
    for p, ref in broken: print(f'BROKEN: {p} -> {ref}')
    raise SystemExit(1)
print('OK')
EOF
```

Expected: `OK`

- [ ] **Step 2: No commit** (verification only)

If broken refs are found, fix them inline (typo in a reference filename, missing file) and re-run Step 1 until it passes.

---

### Task 8: Manual install + behavioral verification

This is the only task that exercises the skill end-to-end. It runs **outside** the implementation worktree (a fresh Claude Code session is required).

- [ ] **Step 1: Install the plugin locally**

The plugin needs to be discoverable by Claude Code. Per the existing `git` plugin's pattern, add the local checkout of `claude-plugins` as a plugin source (or symlink) so Claude Code loads it. (Exact mechanism depends on user's plugin config — likely `claude code plugin add ./plugins/dagu` from the claude-plugins directory, or registering the directory in `~/.claude/plugins.json`.)

- [ ] **Step 2: Trigger check 1 — first-moves rule**

In a fresh Claude Code session in `~/Finances`, ask: *"Is the financial-data dagu pipeline still running?"*

Expected behavior:
- Skill `using-dagu` fires (visible via Skill tool invocation).
- First action is `dagu status financial-data` (or `dagu history financial-data --format json --status running`).
- Not `tail -f`, not `find ... -name '*.log'`.

- [ ] **Step 3: Trigger check 2 — watch loop**

Ask: *"Kick off the financial-data dagu run and watch it until it finishes."*

Expected behavior:
- `dagu start financial-data`, captures run ID.
- One `dagu status --run-id $ID` for baseline; reports state to user.
- `ScheduleWakeup` is called with delay 270–1800s and a prompt containing the run ID + state carry.
- On wake, transitions are surfaced one line at a time.
- On terminal, a timeline summary is reported.

- [ ] **Step 4: Trigger check 3 — drill into failure**

If the watched run failed, ask: *"What failed?"*

Expected behavior:
- The agent reads the failing step's `.err` directly (no globbing, no `find`).
- The path it reads matches the path printed by `dagu status`.

- [ ] **Step 5: Generic-ness audit**

Run:

```bash
grep -rE 'financial-data|/Users/eanderson|\.local/state/dagu|PIPELINE_DIR|/Finances' plugins/dagu/ && echo "FAIL: repo-specific content in skill" || echo "OK: skill is generic"
```

Expected: `OK: skill is generic`

(Repo-specific facts must live in `~/Finances/CLAUDE.md`, not in the skill.)

- [ ] **Step 6: If verification finds gaps**

If any expected behavior fails to land:
- Identify which section of `SKILL.md` or which reference is unclear.
- Edit inline. The skill description and the "First moves" section are the highest-leverage levers.
- Re-run the relevant trigger check.
- Commit the fix with `fix(dagu): <what was unclear>`.

---

## Self-Review

After completing all tasks, the implementer should walk through these checks before declaring done:

- **Spec coverage** — every section of the spec maps to a task: plugin scaffolding (T1), inline body (T2), each reference (T3–T6), data flow & error handling (covered by T2/T5/T6 content), testing (T7/T8). ✓
- **Placeholder scan** — search the produced files for "TBD", "TODO", "fill in", "Add appropriate". The plan body itself contains no placeholders that survive into committed content (the open question on status integers is resolved in T4 Step 1).
- **Type / name consistency** — skill name is `using-dagu` everywhere; plugin name is `dagu` everywhere; reference filenames match across SKILL.md pointers, link checks, and tasks.
- **Genericness** — T8 Step 5 asserts no repo-specific identifiers in any committed file under `plugins/dagu/`.
