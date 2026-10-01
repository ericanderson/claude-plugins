---
name: forgejo-pr
description: Use this skill when the user asks to open, create, submit, review, merge, close, or comment on a pull request in a Forgejo-hosted repository (e.g. `git.anderson.haus`, `codeberg.org`). The `git` plugin's PreToolUse hook will automatically block `gh pr` commands in Forgejo repos and block `fj pr` in GitHub repos — so if you see such a block, come here for the correct `fj` syntax. Trigger phrases: "open a PR", "create a pull request", "send it up for review", "ship this branch", "merge the PR", in a Forgejo repo.
---

# Opening Forgejo pull requests with `fj`

Forgejo's CLI is `fj` ([forgejo-cli](https://codeberg.org/Cyborus/forgejo-cli)). It does not share syntax with `gh`. This skill targets fj 0.6.x — check with `fj version`; `cargo search forgejo-cli --limit 1` shows the latest release, and `cargo install forgejo-cli --locked` upgrades.

The `git` plugin's hook catches wrong-CLI calls, so trust that layer — this skill focuses on getting `fj` right.

## Branch state before opening a PR

Three preconditions — check each before running `fj pr create`:

1. **On a feature branch, not `main`** — `git branch --show-current` should not print `main`.
2. **Commits exist beyond `main`** — `git log origin/main..HEAD --oneline` should show at least one.
3. **Branch is pushed to origin** — `git push -u origin HEAD` on first push; plain `git push` after.

Skip these and you'll see a confusing "empty PR" error; "my PR looks empty" is almost always an unpushed-branch problem.

**Never force-push without the user's say-so.** If `git push` is rejected as non-fast-forward, stop and ask — don't reach for `--force` or `--force-with-lease`.

## Host auto-detection

Inside a Forgejo-backed repo, `fj` reads the origin from git and figures out host + repo automatically. **No `-H` flag needed for the common case.**

You only need `-H <host>` when running outside a Forgejo-backed repo. Since fj 0.6 it's a global flag, so it can go anywhere on the command line:

```sh
fj -H https://git.anderson.haus pr create …
```

Alternative: `FJ_FALLBACK_HOST=https://git.anderson.haus`.

## Always use `--body-file`, never inline `--body`

Shell quoting mangles multi-line bodies. Write to a temp file and use `--body-file`:

```sh
BODY_FILE="$TMPDIR/fj-pr-body-$$.md"
cat > "$BODY_FILE" <<'EOF'
## Summary
- bullet 1
- bullet 2

## Test plan
- [ ] `./scripts/foo.sh` runs clean
- [ ] `bean-check main.beancount` passes

Closes #42
EOF

fj pr create "fix(scope): short imperative title" \
    --base main \
    --head "$(git branch --show-current)" \
    --body-file "$BODY_FILE"

rm "$BODY_FILE"
```

Two things to get right:
- `$TMPDIR`, not `/tmp`.
- Quoted heredoc delimiter (`<<'EOF'`) so backticks and `$vars` stay literal.

## Title and body conventions

- **Title**: short, imperative, under ~70 characters. If the repo uses conventional-commit prefixes (`fix(scope): …`), match them. Check `fj pr search` for recent PRs.
- **Body**: `## Summary` (1–3 bullets of what + why), then `## Test plan` (markdown checklist). Reference the issue with `Closes #NN` when applicable.
- If you have exactly one commit with a good message, `--autofill` will populate title and body from it.

## Submit and report the URL

`fj pr create` prints `created pull request #N: <title>` on stdout — it does **not** print a URL. fj 0.6 wraps every substituted value in invisible Unicode isolates (U+2068 … U+2069), so strip them before parsing the number (`LC_ALL=C` is required, or BSD sed fails with "illegal byte sequence"):

```sh
out="$(fj pr create "…" --base main --head "$(git branch --show-current)" --body-file "$BODY_FILE")"
num="$(printf '%s\n' "$out" | LC_ALL=C sed $'s/\xe2\x81[\xa8\xa9]//g' \
    | sed -nE 's/^created pull request #([0-9]+):.*/\1/p')"
"${CLAUDE_PLUGIN_ROOT}/scripts/forgejo-api.sh" GET "{repo}/pulls/$num" | jq -r .html_url
```

Relay the URL to the user.

Common failures:
- Branch not pushed → `git push -u origin HEAD`
- PR already exists for this branch → `fj pr search --head <branch>`, then `fj pr edit …`
- Not authenticated → `fj -H <host> auth add-token` and paste a PAT on stdin (fj 0.6 renamed `add-key <username>`; the old form now stores the username **as the token**)
- Wrong base → pass `--base main` explicitly

## Other PR operations

| Task | Command |
|------|---------|
| View #42 | `fj pr view 42` |
| Check CI/merge status | `fj pr status 42` |
| Comment | `fj pr comment 42 --body-file "$BODY_FILE"` |
| Edit title/body | `fj pr edit 42 …` (see `fj pr edit --help`) |
| Merge | `fj pr merge 42` (confirm with user — shared state) |
| Close without merging | `fj pr close 42` |
| Checkout someone else's PR | `fj pr checkout 42` |
| Search | `fj pr search <query>` |
| Add/remove labels | `fj pr edit 42 labels --add bug --rm wip` |
| Assign / unassign | `fj pr assign --pr 42 <user>…` / `fj pr unassign --pr 42 <user>…` |
| Set/move/clear milestone | `forgejo-api.sh PATCH '{repo}/issues/42' '{"milestone":<id>}'` (`0` clears) |

## Milestones

fj 0.6 can't set a milestone on a PR (`fj pr create` has no milestone option, and there's no `fj milestone` command). Use the plugin's REST helper, which reuses fj's stored token — PRs are issues in the Forgejo API, so the issues endpoint works for them:

```sh
api="${CLAUDE_PLUGIN_ROOT}/scripts/forgejo-api.sh"
"$api" GET '{repo}/milestones?state=open' | jq -r '.[] | "\(.id)\t\(.title)"'
"$api" PATCH "{repo}/issues/$num" '{"milestone":3}'   # numeric ID, not title; 0 clears
```

Follow the repo's own milestone policy (`CLAUDE.md` / `README`) if it has one — e.g. a PR usually goes in the same milestone as the issue it closes. The forgejo-issue skill's Milestones section has the full helper reference.

## What NOT to do

- ❌ `gh pr create …` in a Forgejo repo (the hook will block it)
- ❌ `fj pr create --body "$(cat <<EOF … EOF)"` (shell mangling)
- ❌ `fj auth add-key <username>` (fj 0.6 stores the username as the token — use `fj auth add-token`)
- ❌ Grepping `fj` output for `#[0-9]+` without stripping the Unicode isolates first
- ❌ `fj pr create …` before pushing the branch
- ❌ `git push --force` to fix a push rejection without asking
- ❌ `fj pr merge` without the user's approval
