#!/usr/bin/env bash
# cost-guard :: install helper (multi-marketplace distribution)
#
# Four IDEs install cost-guard NATIVELY through their own package mechanism —
# there is nothing to copy, so for those this script just PRINTS the one-command
# install. Two paths are file-based and this script performs them:
#
#   * Cursor individuals   — no remote install exists, so we write the hook files
#                            + .cursor/hooks.json into a target project.
#   * Copilot cloud agent  — reads only repo .github/hooks/*.json, so we assemble
#                            .github/hooks/ into a target project to be committed.
#
# Usage:
#   install/install.sh                      # per-IDE menu (same as help / -h)
#   install/install.sh <ide>                # native IDEs: print the install command
#   install/install.sh cursor  <target-dir> # file install (individuals)
#   install/install.sh copilot <target-dir> # file install (cloud agent / repo hooks)
#
#   <ide> (native)  : claude | claude-code | codex | gemini | copilot-cli
#   <ide> (file)    : cursor | copilot
#
# Dependency-light on purpose: only cp / mkdir / chmod / printf touch the system.
# jq is optional (the runtime hook needs it, the installer does not).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")

SLUG="norequest/cost-guard"
GH_URL="https://github.com/norequest/cost-guard"

# --------------------------------------------------------------------- menu ----
menu() {
  cat <<EOF
cost-guard — install per IDE

Four IDEs install NATIVELY (no files to copy) — run the command in that IDE / shell:

  Claude Code    /plugin marketplace add $SLUG
                 /plugin install cost-guard@cost-guard

  Codex          codex plugin marketplace add $SLUG
                 codex plugin install cost-guard@cost-guard

  Gemini         gemini extensions install $GH_URL

  Copilot (CLI)  copilot plugin install $SLUG

Two paths are file-based — this script installs them into a target project:

  Cursor         install/install.sh cursor  <target-dir>
                 (file install for individuals; native path is Teams/official marketplace only)

  Copilot cloud  install/install.sh copilot <target-dir>
                 (writes .github/hooks/ for the cloud agent — commit it)

Reprint a native IDE's command:
  install/install.sh claude | codex | gemini | copilot-cli
EOF
}

# ------------------------------------------------- native install commands ----
print_claude() {
  cat <<EOF
Claude Code installs cost-guard through its plugin marketplace — no files to
copy. Inside Claude Code, run:

  /plugin marketplace add $SLUG
  /plugin install cost-guard@cost-guard

Then restart Claude Code. Requires bash + jq on PATH.
EOF
}

print_codex() {
  cat <<EOF
Codex installs cost-guard through its plugin marketplace — no files to copy.
Run:

  codex plugin marketplace add $SLUG
  codex plugin install cost-guard@cost-guard

Requires a Codex build with plugin marketplace support, plus bash + jq on PATH.
EOF
}

print_gemini() {
  cat <<EOF
Gemini installs cost-guard as an extension — no files to copy. Run:

  gemini extensions install $GH_URL

Requires Gemini CLI with extensions + hooks support, plus bash + jq on PATH.
EOF
}

print_copilot_cli() {
  cat <<EOF
GitHub Copilot CLI installs cost-guard as a plugin — no files to copy. Run:

  copilot plugin install $SLUG

Requires a Copilot CLI build with plugin support, plus bash + jq on PATH.

(For the Copilot CLOUD agent / repo hooks, use: install/install.sh copilot <target-dir>)
EOF
}

# ------------------------------------------------------- file-install helpers --
# require_target : the file installs need an existing target project dir.
require_target() {
  if [ -z "$TARGET" ]; then
    echo "error: <target-dir> is required for '$IDE' (file install)" >&2
    echo "usage: install/install.sh $IDE <target-dir>" >&2
    exit 2
  fi
  if [ ! -d "$TARGET" ]; then
    echo "error: target dir does not exist: $TARGET" >&2
    exit 2
  fi
}

# assemble <adapter-src-dir> <dest-dir>
#   copy adapter.sh (+ adapter.ps1 if shipped) and a bundled copy of core/
#   (guard.sh + guard.ps1 if shipped). The adapter self-resolves $HERE/core.
assemble() {
  src="$1"
  dest="$2"
  mkdir -p "$dest"
  cp "$src/adapter.sh" "$dest/adapter.sh"
  chmod +x "$dest/adapter.sh"
  if [ -f "$src/adapter.ps1" ]; then
    cp "$src/adapter.ps1" "$dest/adapter.ps1"
  fi
  mkdir -p "$dest/core"
  cp "$REPO/core/guard.sh" "$dest/core/guard.sh"
  chmod +x "$dest/core/guard.sh"
  if [ -f "$REPO/core/guard.ps1" ]; then
    cp "$REPO/core/guard.ps1" "$dest/core/guard.ps1"
  fi
}

# The Cursor wiring, generated INLINE with project-root-relative paths
# (.cursor/hooks/cost-guard/adapter.sh) — NOT the repo-relative plugin form in
# adapters/cursor/hooks.json. preToolUse runs fail-open (failClosed:false).
cursor_hooks_json() {
  cat <<'JSON'
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": ".cursor/hooks/cost-guard/adapter.sh session-start", "timeout": 10 }
    ],
    "preToolUse": [
      { "command": ".cursor/hooks/cost-guard/adapter.sh pre-tool", "timeout": 5, "failClosed": false }
    ],
    "postToolUse": [
      { "command": ".cursor/hooks/cost-guard/adapter.sh post-tool", "timeout": 5 }
    ],
    "postToolUseFailure": [
      { "command": ".cursor/hooks/cost-guard/adapter.sh error", "timeout": 5 }
    ],
    "sessionEnd": [
      { "command": ".cursor/hooks/cost-guard/adapter.sh session-end", "timeout": 15 }
    ]
  }
}
JSON
}

# ----------------------------------------------------------------- dispatch ----
IDE="${1:-}"
TARGET="${2:-}"

case "$IDE" in

  ""|help|-h|--help)
    menu
    exit 0
    ;;

  # --- native installs: just print the command(s) ---------------------------
  claude|claude-code)
    print_claude
    exit 0
    ;;
  codex)
    print_codex
    exit 0
    ;;
  gemini)
    print_gemini
    exit 0
    ;;
  copilot-cli)
    print_copilot_cli
    exit 0
    ;;

  # --- file install: Cursor individuals -------------------------------------
  cursor)
    require_target
    DEST="$TARGET/.cursor/hooks/cost-guard"
    assemble "$REPO/adapters/cursor" "$DEST"

    HOOKS_JSON="$TARGET/.cursor/hooks.json"
    if [ -e "$HOOKS_JSON" ]; then
      cat <<EOF

Installed cost-guard hook files for Cursor into:
  $DEST/adapter.sh
  $DEST/core/guard.sh

$HOOKS_JSON already exists — NOT overwriting it. Merge the "hooks" entries from
the block below into your existing file (add each event; keep your other hooks):

EOF
      cursor_hooks_json
      printf '\n'
    else
      cursor_hooks_json > "$HOOKS_JSON"
      cat <<EOF

Installed cost-guard for Cursor into:
  $DEST/adapter.sh
  $DEST/core/guard.sh
  $HOOKS_JSON            (wrote hook wiring)
EOF
    fi

    cat <<EOF

Next steps:
  - Ensure bash + jq are on PATH for Cursor's agent environment.
  - Reload Cursor so it picks up .cursor/hooks.json.
  - Commit .cursor/ if you want the guard to travel with the repo.
EOF
    ;;

  # --- file install: Copilot cloud agent / repo hooks -----------------------
  copilot)
    require_target
    HOOKS_DIR="$TARGET/.github/hooks"
    assemble "$REPO/adapters/copilot" "$HOOKS_DIR/cost-guard"
    mkdir -p "$HOOKS_DIR"
    cp "$REPO/adapters/copilot/cost-guard.json" "$HOOKS_DIR/cost-guard.json"

    cat <<EOF

Installed cost-guard for the GitHub Copilot cloud agent into:
  $HOOKS_DIR/cost-guard.json          (hook manifest)
  $HOOKS_DIR/cost-guard/adapter.sh
  $HOOKS_DIR/cost-guard/core/guard.sh

Next steps:
  - Copilot auto-discovers .github/hooks/cost-guard.json — no extra config.
  - Ensure bash + jq are on PATH in the agent's environment.
  - Commit .github/hooks/ so the guard travels with the repo.
EOF
    ;;

  # --- anything else --------------------------------------------------------
  *)
    echo "error: unknown IDE '$IDE'" >&2
    echo >&2
    menu >&2
    exit 2
    ;;
esac
