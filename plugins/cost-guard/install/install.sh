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
# Usage (from the repo root):
#   plugins/cost-guard/install/install.sh                                # per-IDE menu (same as help / -h)
#   plugins/cost-guard/install/install.sh <ide>                          # native IDEs: print the install command
#   plugins/cost-guard/install/install.sh cursor  <target-dir>           # file install (individuals)
#   plugins/cost-guard/install/install.sh copilot <target-dir>           # file install (cloud agent / repo hooks)
#   plugins/cost-guard/install/install.sh uninstall cursor  <target-dir> # remove a cursor file install
#   plugins/cost-guard/install/install.sh uninstall copilot <target-dir> # remove a copilot file install
#
#   <ide> (native)  : claude | claude-code | codex | gemini | copilot-cli
#   <ide> (file)    : cursor | copilot
#
# The copilot file install refuses to overwrite an existing install; set FORCE=1
# to overwrite, or run the uninstall subcommand first.
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
                 /plugin install cost-guard@norequest

  Codex          codex plugin marketplace add $SLUG
                 codex plugin install cost-guard@norequest

  Gemini         gemini extensions install $GH_URL

  Copilot (CLI)  copilot plugin install $SLUG

Two paths are file-based — this script installs them into a target project:

  Cursor         plugins/cost-guard/install/install.sh cursor  <target-dir>
                 (file install for individuals; native path is Teams/official marketplace only)

  Copilot cloud  plugins/cost-guard/install/install.sh copilot <target-dir>
                 (writes .github/hooks/ for the cloud agent — commit it)

Uninstall a file-based install (removes the files this script wrote):

  plugins/cost-guard/install/install.sh uninstall cursor  <target-dir>
  plugins/cost-guard/install/install.sh uninstall copilot <target-dir>

Reprint a native IDE's command:
  plugins/cost-guard/install/install.sh claude | codex | gemini | copilot-cli
EOF
}

# ------------------------------------------------- native install commands ----
print_claude() {
  cat <<EOF
Claude Code installs cost-guard through its plugin marketplace — no files to
copy. Inside Claude Code, run:

  /plugin marketplace add $SLUG
  /plugin install cost-guard@norequest

Then restart Claude Code. Requires bash + jq on PATH.
EOF
}

print_codex() {
  cat <<EOF
Codex installs cost-guard through its plugin marketplace — no files to copy.
Run:

  codex plugin marketplace add $SLUG
  codex plugin install cost-guard@norequest

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

(For the Copilot CLOUD agent / repo hooks, use: plugins/cost-guard/install/install.sh copilot <target-dir>)
EOF
}

# ------------------------------------------------------- file-install helpers --
# require_target : the file installs (and uninstalls) need an existing target
# project dir. $MODE is "uninstall " when dispatched via the uninstall
# subcommand, empty otherwise (only used for the usage message).
require_target() {
  if [ -z "$TARGET" ]; then
    echo "error: <target-dir> is required for '${MODE}${IDE}'" >&2
    echo "usage: plugins/cost-guard/install/install.sh ${MODE}${IDE} <target-dir>" >&2
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
# plugins/cost-guard/adapters/cursor/hooks.json. preToolUse runs fail-open
# (failClosed:false).
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

# ---------------------------------------------------------------- uninstall ----
MODE=""
if [ "${1:-}" = "uninstall" ]; then
  MODE="uninstall "
  IDE="${2:-}"
  TARGET="${3:-}"

  case "$IDE" in

    cursor)
      require_target
      DEST="$TARGET/.cursor/hooks/cost-guard"
      if [ ! -d "$DEST" ]; then
        echo "nothing to remove: $DEST does not exist" >&2
        exit 0
      fi
      rm -rf "$DEST"
      cat <<EOF
Removed:
  $DEST/

Left in place (this script never edits your hooks wiring on uninstall):
  $TARGET/.cursor/hooks.json

Remove the cost-guard entries (the ".cursor/hooks/cost-guard/adapter.sh ..."
commands) from that file yourself, or delete the file if cost-guard was the
only thing in it.
EOF
      exit 0
      ;;

    copilot)
      require_target
      HOOKS_DIR="$TARGET/.github/hooks"
      REMOVED=0
      if [ -d "$HOOKS_DIR/cost-guard" ]; then
        rm -rf "$HOOKS_DIR/cost-guard"
        echo "Removed: $HOOKS_DIR/cost-guard/"
        REMOVED=1
      fi
      if [ -f "$HOOKS_DIR/cost-guard.json" ]; then
        rm -f "$HOOKS_DIR/cost-guard.json"
        echo "Removed: $HOOKS_DIR/cost-guard.json"
        REMOVED=1
      fi
      if [ "$REMOVED" -eq 0 ]; then
        echo "nothing to remove: no cost-guard files under $HOOKS_DIR" >&2
      fi
      exit 0
      ;;

    "")
      echo "error: uninstall needs an IDE: uninstall cursor|copilot <target-dir>" >&2
      exit 2
      ;;

    *)
      echo "error: unknown uninstall target '$IDE' (expected: cursor | copilot)" >&2
      exit 2
      ;;
  esac
fi

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

    # No-clobber: refuse to overwrite an existing install (same protection the
    # cursor branch gives .cursor/hooks.json). FORCE=1 overrides.
    if [ "${FORCE:-0}" != "1" ]; then
      if [ -e "$HOOKS_DIR/cost-guard.json" ] || [ -e "$HOOKS_DIR/cost-guard" ]; then
        {
          echo "error: cost-guard already appears to be installed in $TARGET:"
          if [ -e "$HOOKS_DIR/cost-guard.json" ]; then
            echo "  $HOOKS_DIR/cost-guard.json"
          fi
          if [ -e "$HOOKS_DIR/cost-guard" ]; then
            echo "  $HOOKS_DIR/cost-guard/"
          fi
          echo
          echo "NOT overwriting. To replace it, re-run with FORCE=1:"
          echo "  FORCE=1 plugins/cost-guard/install/install.sh copilot $TARGET"
          echo "or remove the old install first:"
          echo "  plugins/cost-guard/install/install.sh uninstall copilot $TARGET"
        } >&2
        exit 3
      fi
    fi

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
