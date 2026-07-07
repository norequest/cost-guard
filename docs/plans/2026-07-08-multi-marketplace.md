# cost-guard — multi-marketplace distribution (2026-07-08)

Supersedes the single-marketplace "Distribution" section of the original design
doc. Goal: every supported IDE gets a **real one-command install of its own**,
not a manual copy — modeled on `wshobson/agents`' "one repo, one marketplace per
harness" pattern, adapted for a **hook** (that repo ships agents/skills).

## Key finding (why this is possible)

`cost-guard` is a lifecycle **hook**. Three research passes established that, as
of mid-2026, **four** agent CLIs can install a hook through their native
package mechanism — not just Claude Code:

| IDE | Native one-command hook install | Mechanism |
|---|---|---|
| Claude Code | ✅ | plugin marketplace; `plugin.json` `hooks` |
| OpenAI Codex | ✅ | plugin marketplace; `.codex-plugin/plugin.json` `hooks` field |
| Google Gemini | ✅ | extensions; `hooks/hooks.json` convention in the extension |
| GitHub Copilot (CLI) | ✅ | plugin; root `plugin.json` `hooks` field |
| Cursor | ⚠️ | plugin format carries hooks, but no remote install for individuals (official reviewed marketplace or Teams import only) → installer for individuals |
| GitHub Copilot (cloud agent) | config-file | reads only repo `.github/hooks/*.json` |

The reference repo's own generator marks codex/cursor/gemini/copilot as
`hooks:false` — but that reflects **its** transform (agents/skills only), not the
IDEs' current capability. The live IDE docs (2026) show first-class `hooks`
support. We verified against those docs directly.

## Layout: root-as-plugin, one plugin, many marketplaces

The repo root is **simultaneously** a Claude plugin, a Codex plugin, a Gemini
extension, and a Copilot plugin — each IDE reads a differently-named manifest, so
there is no collision:

```
cost-guard/                          (repo root == the plugin/extension)
├── .claude-plugin/
│   ├── marketplace.json             # Claude marketplace  (source "./")
│   └── plugin.json                  # hooks -> ./adapters/claude-code/hooks.json
├── .agents/plugins/marketplace.json # Codex marketplace   (source {local, "./"})
├── .codex-plugin/plugin.json        # hooks -> ./adapters/codex/hooks.json
├── .cursor-plugin/
│   ├── marketplace.json             # Cursor marketplace  (source "./", Teams/official)
│   └── plugin.json                  # hooks -> ./adapters/cursor/hooks.json
├── gemini-extension.json            # Gemini extension manifest
├── hooks/hooks.json                 # Gemini hooks (convention path; ${extensionPath})
├── plugin.json                      # Copilot CLI plugin  (hooks -> adapters/copilot/hooks.json)
├── core/{guard.sh, guard.ps1}       # unchanged, tested engine
├── adapters/<ide>/{adapter.sh, adapter.ps1, hooks.json|cost-guard.json|settings.hooks.json}
├── install/install.sh               # Cursor individuals + Copilot cloud + native-command printer
├── tests/  collector/  docs/
```

### Per-IDE wiring file + path variable

Each IDE's plugin manifest points at its own hooks file, because the hook
schemas differ (event names, decision shape, path variable):

| IDE | manifest → hooks file | path variable | event names |
|---|---|---|---|
| Claude Code | `.claude-plugin/plugin.json` → `adapters/claude-code/hooks.json` | `${CLAUDE_PLUGIN_ROOT}` | PreToolUse/PostToolUse/SessionStart/SessionEnd |
| Codex | `.codex-plugin/plugin.json` → `adapters/codex/hooks.json` | `${CLAUDE_PLUGIN_ROOT:-.}` (compat) | PreToolUse/PostToolUse/SessionStart/Stop |
| Gemini | `gemini-extension.json` + convention → `hooks/hooks.json` | `${extensionPath}` | SessionStart/BeforeTool/AfterTool/SessionEnd |
| Copilot CLI | `plugin.json` → `adapters/copilot/hooks.json` | (plugin-root relative) | sessionStart/preToolUse/postToolUse/errorOccurred/sessionEnd |
| Cursor | `.cursor-plugin/plugin.json` → `adapters/cursor/hooks.json` | (plugin-root relative) | sessionStart/preToolUse/postToolUse/postToolUseFailure/sessionEnd |

All of them invoke `adapters/<ide>/adapter.sh <canonical-event>`, which
self-resolves `core/` via `${BASH_SOURCE}` regardless of cwd. Nothing about the
tested core/adapter logic changed.

## Install commands (what the README leads with)

```
Claude Code   /plugin marketplace add norequest/cost-guard
              /plugin install cost-guard@cost-guard
Codex         codex plugin marketplace add norequest/cost-guard
              codex plugin install cost-guard@cost-guard
Gemini        gemini extensions install https://github.com/norequest/cost-guard
Copilot CLI   copilot plugin install norequest/cost-guard
Cursor        install/install.sh cursor .        (writes .cursor/hooks.json)
Copilot cloud commit .github/hooks/cost-guard.json  (install/install.sh copilot .)
```

## Honest verification status

- **Fully tested (unchanged):** core + 5 bash adapters + PowerShell engine —
  106-check suite green. The *guard behavior* is proven.
- **Schema-verified, not runtime-tested:** the native install manifests. None of
  Codex/Gemini/Copilot/Cursor CLIs are installed on the build machine, and these
  are bleeding-edge features (Codex `plugin marketplace` ~v0.121, Copilot CLI
  plugins preview-era, Gemini extensions+hooks ≥ v0.26.0). Manifests match the
  current official docs; JSON validates; every marketplace→source and
  manifest→hooks cross-reference resolves. Treat native paths as "documented and
  wired," to be smoke-tested on a machine with each CLI before a v1 announcement.
- **Known risks to smoke-test:**
  1. Whether Claude Code also auto-loads the convention `hooks/hooks.json`
     (Gemini's file) in addition to the explicit manifest path. If it does, the
     Gemini file's `${extensionPath}` (unset under Claude) makes the command a
     harmless no-op, but confirm no double-fire.
  2. Copilot CLI / Cursor plugin hook command cwd (plugin-root-relative paths
     assume cwd = plugin dir).
  3. Codex `${CLAUDE_PLUGIN_ROOT}` actually set on plugin hook execution.
- **Cursor individuals:** no remote install exists today; the installer writing
  `.cursor/hooks.json` is the real path. The `.cursor-plugin/` manifests are for
  the reviewed official marketplace / Teams import (forward-compatible, unverified).
```
