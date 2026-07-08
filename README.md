# norequest plugins

[![ci](https://github.com/norequest/plugins/actions/workflows/ci.yml/badge.svg)](https://github.com/norequest/plugins/actions/workflows/ci.yml)

A plugin marketplace for AI coding agent CLIs: Claude Code, OpenAI Codex,
Google Gemini, GitHub Copilot, and Cursor. One repo, one marketplace, and each
plugin installs with a single command from your own CLI.

## Add the marketplace

**Claude Code**

```
/plugin marketplace add norequest/plugins
```

**OpenAI Codex**

```
codex plugin marketplace add norequest/plugins
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
| **Claude Code** | `/plugin marketplace add norequest/plugins` then `/plugin install cost-guard@norequest` |
| **OpenAI Codex** | `codex plugin marketplace add norequest/plugins` then `codex plugin install cost-guard@norequest` |
| **Google Gemini** | `gemini extensions link ./plugins/cost-guard/gemini` (from a repo clone) |
| **GitHub Copilot (CLI)** | `copilot plugin install norequest/plugins:plugins/cost-guard` |
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
├── LICENSE
├── README.md
└── plugins/
    └── cost-guard/                    # the plugin, fully self-contained
        ├── .claude-plugin/ .codex-plugin/ .cursor-plugin/   # per-IDE plugin manifests
        ├── plugin.json                # Copilot CLI manifest (norequest/plugins:plugins/cost-guard)
        ├── gemini/                    # Gemini extension, linked: gemini-extension.json + hooks/
        ├── core/  adapters/  install/  collector/  tests/
        └── README.md
```

Gemini and Copilot CLI have no marketplace concept, so they install the plugin
straight from its subdirectory: Copilot via the subdir path
`norequest/plugins:plugins/cost-guard`, Gemini by linking the
`plugins/cost-guard/gemini` extension folder from a local clone. Both manifests
live inside the plugin, so the marketplace root stays plugin-agnostic.

## License

MIT.
