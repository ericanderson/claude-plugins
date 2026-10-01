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
## Maintaining

- Each plugin's `.claude-plugin/plugin.json` is the single source for its `description`; `marketplace.json` entries carry only `name` and `source`.
- Plugins deliberately have no `version`, so installs track commits and a merge to `main` reaches users without a version bump (`claude plugin update <name>@ea-claude`). Ignore `claude plugin validate`'s "No version specified" warning.
