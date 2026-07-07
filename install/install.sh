#!/usr/bin/env bash
# cost-guard :: install helper
#
# Assembles cost-guard into a target project's hook directory for a given
# platform, then prints the wiring you still need to add. Claude Code installs
# via its plugin marketplace instead of copying, so for that platform this
# script just prints the marketplace commands.
#
# Usage:
#   install/install.sh <platform> <target-dir>
#     platform   : claude-code | copilot | cursor | codex | gemini
#     target-dir : the project root to install into (required for all but
#                  claude-code)
#
# Dependency-light on purpose: only cp / mkdir / chmod touch the filesystem.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")

usage() {
  cat >&2 <<EOF
usage: install/install.sh <platform> <target-dir>
  platform   : claude-code | copilot | cursor | codex | gemini
  target-dir : project root to install into (not needed for claude-code)
EOF
}

PLATFORM="${1:-}"
TARGET="${2:-}"

if [ -z "$PLATFORM" ]; then
  echo "error: <platform> is required" >&2
  usage
  exit 2
fi

# --- Claude Code installs via the plugin marketplace, no file copying. --------
if [ "$PLATFORM" = "claude-code" ]; then
  cat <<EOF
cost-guard installs on Claude Code through its plugin marketplace — there are no
files to copy. Inside Claude Code, run:

  From this local checkout:
    /plugin marketplace add $REPO
    /plugin install cost-guard@cost-guard

  Or from GitHub once published:
    /plugin marketplace add prixioge/cost-guard
    /plugin install cost-guard@cost-guard

Then restart Claude Code. The hooks declared in
adapters/claude-code/hooks.json activate automatically (they reference the
adapter + core via \${CLAUDE_PLUGIN_ROOT}). Requires bash + jq on PATH.
EOF
  exit 0
fi

# --- Validate platform + target for the copy-based installs. ------------------
case "$PLATFORM" in
  copilot|cursor|codex|gemini) ;;
  *)
    echo "error: unknown platform '$PLATFORM'" >&2
    usage
    exit 2
    ;;
esac

if [ -z "$TARGET" ]; then
  echo "error: <target-dir> is required for $PLATFORM" >&2
  usage
  exit 2
fi
if [ ! -d "$TARGET" ]; then
  echo "error: target dir does not exist: $TARGET" >&2
  exit 2
fi

ADAPTER_SRC="$REPO/adapters/$PLATFORM"

# assemble <dest-dir> : copy adapter(.sh/.ps1) + a bundled copy of core/ in.
assemble() {
  dest="$1"
  mkdir -p "$dest"
  cp "$ADAPTER_SRC/adapter.sh" "$dest/adapter.sh"
  chmod +x "$dest/adapter.sh"
  # PowerShell twin is optional — copy only if the repo ships one.
  if [ -f "$ADAPTER_SRC/adapter.ps1" ]; then
    cp "$ADAPTER_SRC/adapter.ps1" "$dest/adapter.ps1"
  fi
  # Bundle the neutral core next to the adapter (adapter resolves $HERE/core).
  mkdir -p "$dest/core"
  cp "$REPO/core/guard.sh" "$dest/core/guard.sh"
  chmod +x "$dest/core/guard.sh"
  if [ -f "$REPO/core/guard.ps1" ]; then
    cp "$REPO/core/guard.ps1" "$dest/core/guard.ps1"
  fi
}

case "$PLATFORM" in

  copilot)
    HOOKS_DIR="$TARGET/.github/hooks"
    assemble "$HOOKS_DIR/cost-guard"
    cp "$ADAPTER_SRC/cost-guard.json" "$HOOKS_DIR/cost-guard.json"
    cat <<EOF

Installed cost-guard for GitHub Copilot into:
  $HOOKS_DIR/cost-guard.json      (hook manifest)
  $HOOKS_DIR/cost-guard/adapter.sh
  $HOOKS_DIR/cost-guard/core/guard.sh

Next steps:
  - Copilot auto-discovers .github/hooks/cost-guard.json — no extra config.
  - Ensure bash + jq are on PATH for the agent's environment.
  - Commit .github/hooks/ so the guard travels with the repo.
EOF
    ;;

  cursor)
    DEST="$TARGET/.cursor/hooks/cost-guard"
    assemble "$DEST"
    cat <<EOF

Installed cost-guard for Cursor into:
  $DEST/adapter.sh
  $DEST/core/guard.sh

Next step — add (or merge) this into $TARGET/.cursor/hooks.json:

EOF
    cat "$ADAPTER_SRC/hooks.json"
    printf '\n'
    ;;

  codex)
    DEST="$TARGET/.codex/hooks/cost-guard"
    assemble "$DEST"
    cat <<EOF

Installed cost-guard for OpenAI Codex into:
  $DEST/adapter.sh
  $DEST/core/guard.sh

Next steps:
  - Requires Codex >= ~v0.117 with hooks enabled (set features.hooks in your
    Codex config, e.g. ~/.codex/config.toml).
  - Add (or merge) this hooks wiring into your Codex hooks config:

EOF
    cat "$ADAPTER_SRC/hooks.json"
    printf '\n'
    ;;

  gemini)
    DEST="$TARGET/.gemini/hooks/cost-guard"
    assemble "$DEST"
    cat <<EOF

Installed cost-guard for Google Gemini CLI into:
  $DEST/adapter.sh
  $DEST/core/guard.sh

Next steps:
  - Requires Gemini CLI >= v0.26.0 (hooks GA).
  - Merge the "hooks" block below into your Gemini settings.json
    ($TARGET/.gemini/settings.json or ~/.gemini/settings.json):

EOF
    cat "$ADAPTER_SRC/settings.hooks.json"
    printf '\n'
    ;;
esac
