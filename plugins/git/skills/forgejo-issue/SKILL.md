---
name: forgejo-issue
description: Use this skill when the user asks to file, open, create, update, close, or comment on an issue in a Forgejo-hosted repository (e.g. `git.anderson.haus`, `codeberg.org`). The `git` plugin's PreToolUse hook will automatically block `gh` commands in Forgejo repos and block `fj` in GitHub repos — so if you see such a block, come here for the correct `fj` syntax. Trigger phrases: "file an issue", "open an issue", "create a ticket", "comment on issue #N", "close issue", in a Forgejo repo.
---

# Filing Forgejo issues with `fj`

Forgejo's CLI is `fj` ([forgejo-cli](https://codeberg.org/Cyborus/forgejo-cli), installed via `cargo install forgejo-cli`). It does not share syntax with `gh`.

The `git` plugin's hook catches wrong-CLI calls, so trust that layer — this skill focuses on getting `fj` right.

## Host auto-detection

Inside a Forgejo-backed repo, `fj` reads the origin from git and figures out the host + repo on its own. **No `-H` flag needed for the common case.** Just:

```sh
fj issue create "Title" --body-file "$BODY_FILE"
```

You only need `-H <host>` when running outside a Forgejo-backed repo (e.g. from `~/`). When required, it goes **before** the subcommand:

```sh
fj -H https://git.anderson.haus issue create "Title"   # correct
fj issue -H https://git.anderson.haus create "Title"   # WRONG — fj treats -H as an arg to create
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
fj -H https://git.anderson.haus auth add-key <username>
```

## Report the URL

`fj issue create` prints the issue URL on success — relay it to the user.

On failure, read the error. Common causes:
- Not authenticated → add a PAT (above)
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

All follow the same `-H` and body-file rules as `create`.

## What NOT to do

- ❌ `gh issue create …` in a Forgejo repo (the hook will block it)
- ❌ `fj issue create -H https://… …` (flag order wrong)
- ❌ `fj issue create "…" --body "$(cat <<EOF … EOF)"` (shell mangling)
- ❌ Running from `~/` without `-H` and expecting `fj` to find the repo
