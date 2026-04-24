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
- **git** — Detects GitHub vs Forgejo from the repo origin and steers Claude to the right CLI (`gh` vs `fj`). Ships the `forgejo-issue` and `forgejo-pr` skills plus a `PreToolUse` hook that blocks wrong-CLI calls before they hit the network.