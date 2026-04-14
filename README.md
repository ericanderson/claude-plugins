# EA's Claude Plugins

Claude Code plugin marketplace and plugin host.

## Usage

Add this marketplace:

```bash
/plugin marketplace add ericanderson/claude
```

Install a plugin:

```bash
/plugin install <plugin-name>@ea-claude
```

## Plugins

- **cleanroom** — Launch isolated background agents for unbiased codebase analysis

## Structure

```
.claude-plugin/
  marketplace.json    # Plugin catalog
plugins/
  <plugin-name>/
    .claude-plugin/
      plugin.json     # Plugin manifest
    skills/           # Skills provided by the plugin
    agents/           # Subagent definitions
    hooks/            # Event handlers
```

## Adding a Plugin

Each plugin lives in `plugins/<name>/` and needs at minimum a `.claude-plugin/plugin.json` manifest, then an entry in `.claude-plugin/marketplace.json`.
