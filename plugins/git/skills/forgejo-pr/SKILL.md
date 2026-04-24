---
name: forgejo-pr
description: Use this skill when the user asks to open, create, submit, review, merge, close, or comment on a pull request in a Forgejo-hosted repository (e.g. `git.anderson.haus`, `codeberg.org`). The `git` plugin's PreToolUse hook will automatically block `gh pr` commands in Forgejo repos and block `fj pr` in GitHub repos — so if you see such a block, come here for the correct `fj` syntax. Trigger phrases: "open a PR", "create a pull request", "send it up for review", "ship this branch", "merge the PR", in a Forgejo repo.
---

# Opening Forgejo pull requests with `fj`

Forgejo's CLI is `fj` ([forgejo-cli](https://codeberg.org/Cyborus/forgejo-cli)). It does not share syntax with `gh`.

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

You only need `-H <host>` when running outside a Forgejo-backed repo. When required, it goes **before** the subcommand:

```sh
fj -H https://git.anderson.haus pr create …   # correct
fj pr -H https://git.anderson.haus create …   # WRONG
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

`fj pr create` prints the PR URL on success — relay it to the user.

Common failures:
- Branch not pushed → `git push -u origin HEAD`
- PR already exists for this branch → `fj pr search --head <branch>`, then `fj pr edit …`
- Not authenticated → `fj -H <host> auth add-key <username>` with a PAT
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

## What NOT to do

- ❌ `gh pr create …` in a Forgejo repo (the hook will block it)
- ❌ `fj pr create --body "$(cat <<EOF … EOF)"` (shell mangling)
- ❌ `fj pr -H … create …` (flag order wrong — `-H` goes before `pr`)
- ❌ `fj pr create …` before pushing the branch
- ❌ `git push --force` to fix a push rejection without asking
- ❌ `fj pr merge` without the user's approval
