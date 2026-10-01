---
name: forgejo-issue
description: Use this skill when the user asks to file, open, create, update, close, or comment on an issue in a Forgejo-hosted repository (e.g. `git.anderson.haus`, `codeberg.org`). The `git` plugin's PreToolUse hook will automatically block `gh` commands in Forgejo repos and block `fj` in GitHub repos — so if you see such a block, come here for the correct `fj` syntax. Trigger phrases: "file an issue", "open an issue", "create a ticket", "comment on issue #N", "close issue", in a Forgejo repo.
---

# Filing Forgejo issues with `fj`

Forgejo's CLI is `fj` ([forgejo-cli](https://codeberg.org/Cyborus/forgejo-cli)). It does not share syntax with `gh`. This skill targets fj 0.6.x — check with `fj version`; `cargo search forgejo-cli --limit 1` shows the latest release, and `cargo install forgejo-cli --locked` upgrades.

The `git` plugin's hook catches wrong-CLI calls, so trust that layer — this skill focuses on getting `fj` right.

## Host auto-detection

Inside a Forgejo-backed repo, `fj` reads the origin from git and figures out the host + repo on its own. **No `-H` flag needed for the common case.** Just:

```sh
fj issue create "Title" --body-file "$BODY_FILE"
```

You only need `-H <host>` when running outside a Forgejo-backed repo (e.g. from `~/`). Since fj 0.6 it's a global flag, so it can go anywhere on the command line:

```sh
fj -H https://git.anderson.haus issue create "Title"
```

Alternative: set `FJ_FALLBACK_HOST=https://git.anderson.haus` in the environment.

## Always use `--body-file`, never inline `--body`

Shell quoting mangles multi-line bodies — backticks, `$(…)`, `!`, code fences, and nested quotes all get interpreted before `fj` sees them. Write the body to a temp file first:

```sh
BODY_FILE="$TMPDIR/fj-issue-body-$$.md"
cat > "$BODY_FILE" <<'EOF'
## Summary
1–3 sentences on what the bug/feature is.

## Context
- concrete details
- file paths, commands, error messages

## Suggested direction
(optional) how we might approach this
EOF

fj issue create "Short imperative title" --body-file "$BODY_FILE"
rm "$BODY_FILE"
```

Two things to get right:
- Use `$TMPDIR` (sandbox-writable), not `/tmp`.
- Quote the heredoc delimiter (`<<'EOF'`, not `<<EOF`) so backticks and `$vars` inside the body stay literal.

## Title conventions

- Short and imperative, under ~70 characters.
- No trailing period.
- If the repo uses conventional-commit prefixes (`fix(scope): …`, `feat(scope): …`), match that style. Check recent issues with `fj issue search` to see the convention.

## Authenticate once per host

Self-hosted Forgejo instances can't use `fj auth login` (OAuth only works for a hardcoded list of public hosts). Use a personal access token from `<host>/user/settings/applications`:

```sh
fj -H https://git.anderson.haus auth add-token
```

It reads the token from stdin when no argument is given. (fj 0.6 renamed `add-key <username>` to `add-token [token]`. `add-key` still works as an alias, but the old `add-key <username>` form now stores the username **as the token**.)

## Parsing `fj` output: strip Unicode isolates first

fj 0.6 renders every message through Fluent, which wraps each substituted value in invisible Unicode isolate characters (U+2068 … U+2069) — even when output is piped. `fj issue create` prints `created issue #⁨254⁩: ⁨Title⁩`, so a regex like `#[0-9]+` silently fails to match. It can't be turned off (`--style minimal` doesn't help). Strip the isolates before parsing anything:

```sh
LC_ALL=C sed $'s/\xe2\x81[\xa8\xa9]//g'
```

`LC_ALL=C` is required — without it BSD sed fails with "illegal byte sequence".

Also note that `fj issue create` writes its success line to **stderr**, not stdout.

## Report the issue

`fj issue create` prints `created issue #N: <title>` (on stderr) — it does **not** print a URL. To capture the number and give the user a link, run the create like this (in place of the plain `fj issue create` above):

```sh
out="$(fj issue create "Short imperative title" --body-file "$BODY_FILE" 2>&1)"
num="$(printf '%s\n' "$out" | LC_ALL=C sed $'s/\xe2\x81[\xa8\xa9]//g' \
    | sed -nE 's/^created issue #([0-9]+):.*/\1/p')"
[ -n "$num" ] || { printf '%s\n' "$out" >&2; exit 1; }
"${CLAUDE_PLUGIN_ROOT}/scripts/forgejo-api.sh" GET "{repo}/issues/$num" | jq -r .html_url
```

On failure, read the error. Common causes:
- Not authenticated → add a token with `fj auth add-token` (above)
- Repo requires a template → pass `--template <name>` or `--no-template`
- Outside a Forgejo repo and no `-H` → pass `-H` or set `FJ_FALLBACK_HOST`

## Other issue operations

| Task | Command |
|------|---------|
| Comment on #42 | `fj issue comment 42 --body-file "$BODY_FILE"` |
| Edit title | `fj issue edit 42 title "New title"` |
| Edit body (in $EDITOR) | `fj issue edit 42 body` |
| Close | `fj issue close 42` |
| View | `fj issue view 42` |
| Search | `fj issue search <query>` |
| Add/remove labels | `fj issue edit 42 labels --add bug --rm triage` |
| Assign / unassign | `fj issue assign 42 <user>…` / `fj issue unassign 42 <user>…` |
| Set/move/clear milestone | `forgejo-api.sh` — see [Milestones](#milestones) |

All follow the same `-H` and body-file rules as `create`.

## Milestones

fj 0.6 has no milestone support at all — there's no `fj milestone` command, and `fj issue create` always sends `milestone: None`. Use the plugin's REST helper, which reuses fj's stored token:

```sh
"${CLAUDE_PLUGIN_ROOT}/scripts/forgejo-api.sh" METHOD PATH [JSON_BODY]
```

`PATH` is relative to `/api/v1`; a literal `{repo}` expands to `repos/<owner>/<name>` from the origin remote (override with `FORGEJO_HOST` / `FORGEJO_REPO`). It prints the JSON response on stdout and exits 1 with the body on stderr on a non-2xx status.

**If the repo has a milestone policy, follow it.** Check `CLAUDE.md` / `README` / `CONTRIBUTING` for how milestones are named, ordered, and when an issue goes into which one (e.g. a "Triage" milestone for unsorted issues). Don't invent milestones the policy doesn't call for — ask the user.

| Task | Command |
|------|---------|
| List open milestones | `forgejo-api.sh GET '{repo}/milestones?state=open' \| jq -r '.[] \| "\(.id)\t\(.title)"'` |
| Create a milestone | `forgejo-api.sh POST '{repo}/milestones' '{"title":"Triage"}'` (ask first — shared state) |
| Set or move an issue's milestone | `forgejo-api.sh PATCH '{repo}/issues/42' '{"milestone":3}'` |
| Clear an issue's milestone | `forgejo-api.sh PATCH '{repo}/issues/42' '{"milestone":0}'` |

The `milestone` value is the milestone's numeric **ID**, not its title — look it up from the list first.

To file an issue straight into a milestone, create it, parse the number (see [Report the issue](#report-the-issue)), then PATCH:

```sh
api="${CLAUDE_PLUGIN_ROOT}/scripts/forgejo-api.sh"
ms_id="$("$api" GET '{repo}/milestones?state=open' \
    | jq -r --arg t "Triage" '.[] | select(.title == $t) | .id')"
[ -n "$ms_id" ] || { echo "no open milestone named Triage" >&2; exit 1; }
# ... fj issue create → $num, as above ...
"$api" PATCH "{repo}/issues/$num" "{\"milestone\":$ms_id}" | jq -r .html_url
```

## What NOT to do

- ❌ `gh issue create …` in a Forgejo repo (the hook will block it)
- ❌ `fj auth add-key <username>` (fj 0.6 stores the username as the token — use `fj auth add-token`)
- ❌ Grepping `fj` output for `#[0-9]+` without stripping the Unicode isolates first
- ❌ Passing a milestone **title** to the API — it takes the numeric ID
- ❌ `fj issue create "…" --body "$(cat <<EOF … EOF)"` (shell mangling)
- ❌ Running from `~/` without `-H` and expecting `fj` to find the repo
