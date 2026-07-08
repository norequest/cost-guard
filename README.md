# norequest plugins

[![ci](https://github.com/norequest/cost-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/norequest/cost-guard/actions/workflows/ci.yml)

A plugin marketplace for AI coding agent CLIs: Claude Code, OpenAI Codex,
Google Gemini, GitHub Copilot, and Cursor. One repo, one marketplace, and each
plugin installs with a single command from your own CLI.

## Add the marketplace

**Claude Code**

```
/plugin marketplace add norequest/cost-guard
```

**OpenAI Codex**

```
codex plugin marketplace add norequest/cost-guard
```

Gemini and Copilot CLI have no marketplace concept; they install a plugin
directly from this repo (see the per-IDE rows below).

## Plugins

| Plugin | What it does | Docs |
|---|---|---|
| **cost-guard** | Cost and runaway control for AI coding agents: loop detection, failure streaks, call and time budgets, deny or checkpoint before spend runs away | [plugins/cost-guard/README.md](plugins/cost-guard/README.md) |

## Install cost-guard: pick your IDE

| IDE | Install |
|---|---|
| **Claude Code** | `/plugin marketplace add norequest/cost-guard` then `/plugin install cost-guard@norequest` |
| **OpenAI Codex** | `codex plugin marketplace add norequest/cost-guard` then `codex plugin install cost-guard@norequest` |
| **Google Gemini** | `gemini extensions install https://github.com/norequest/cost-guard` |
| **GitHub Copilot (CLI)** | `copilot plugin install norequest/cost-guard` |
| **Cursor** | `plugins/cost-guard/install/install.sh cursor .` (from a repo clone) |
| **GitHub Copilot (cloud agent)** | `plugins/cost-guard/install/install.sh copilot .` then commit `.github/hooks/cost-guard.json` |

Full per-IDE details, requirements, and caveats:
[plugins/cost-guard/README.md](plugins/cost-guard/README.md).

## Repo layout

The repo root holds the marketplace manifests. Each plugin lives under
`plugins/<name>/` with its own core, adapters, installer, tests, and README.

```
norequest (this repo)
├── .claude-plugin/marketplace.json    # Claude Code marketplace "norequest"
├── .agents/plugins/marketplace.json   # Codex marketplace "norequest"
├── .cursor-plugin/marketplace.json    # Cursor marketplace (Teams / official import)
├── gemini-extension.json              # Gemini extension manifest (direct install)
├── hooks/hooks.json                   # Gemini hooks → plugins/cost-guard/adapters/gemini/
├── plugin.json                        # Copilot CLI plugin → plugins/cost-guard/adapters/copilot/hooks.json
└── plugins/
    └── cost-guard/                    # core + adapters + installer + tests + README
```

Gemini and Copilot CLI install directly from this repo because those CLIs have
no marketplace concept; their root-level manifests point into
`plugins/cost-guard/`.

## License

MIT.
