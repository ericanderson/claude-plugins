# EA's Claude Plugins

Claude Code plugin marketplace and plugin host.

## Usage

Add this marketplace:

```bash
/plugin marketplace add ericanderson/claude-plugins
```

Install a plugin:

```bash
/plugin install <plugin-name>@ea-claude
```

## Plugins

- **cleanroom** — Launch isolated background agents for unbiased codebase analysis
- **git** — Detects GitHub vs Forgejo from the repo origin and steers Claude to the right CLI (`gh` vs `fj`). Ships the `forgejo-issue` and `forgejo-pr` skills, a `forgejo-api.sh` REST helper for things `fj` can't do (milestones), and a `PreToolUse` hook that blocks wrong-CLI calls before they hit the network.
## Contributing: this is a public repo

Everything here — code, commit messages, PR and issue text — is public. Don't commit private repo or project names, personal hostnames or IPs, local paths, usernames, emails, tokens, or details of other projects. Use placeholders such as `example.org` and `owner/repo` in examples and tests.

Claude Code sessions in this repo get a guard (`.claude/hooks/public-repo-guard.sh`, wired up in `.claude/settings.json`). Before `git commit`, `git push`, or `gh pr|issue|release|gist|api`, it scans the command, any `--body-file`/`-F` file, and the added lines against a private denylist and blocks on a match; otherwise it adds a public-repo checklist to Claude's context. The denylist is deliberately kept outside the repo — one case-insensitive regex per line in `~/.config/claude/public-repo-denylist` (override with `PUBLIC_REPO_DENYLIST`).
