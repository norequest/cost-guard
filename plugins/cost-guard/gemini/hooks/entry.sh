#!/usr/bin/env bash
# cost-guard :: Gemini extension entry shim.
#
# Gemini links plugins/cost-guard/gemini as the extension root and invokes this
# script as "${extensionPath}/hooks/entry.sh <event>". Keeping the manifest
# reference inside the extension directory (no ".." in hooks.json) means the
# wiring keeps working even if a future gemini-cli sandboxes hook command paths
# the way it already sandboxes context-file paths. The ".." lives here, in a
# plain shell script gemini-cli never inspects.
#
# We resolve the shared adapter from this script's own location and delegate.
# Fail open at every step: if anything cannot be resolved, exit 0 (allow) so the
# guard never disrupts the host agent.
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 0
PLUGIN=$(cd "$HERE/../.." 2>/dev/null && pwd) || exit 0
ADAPTER="$PLUGIN/adapters/gemini/adapter.sh"
[ -x "$ADAPTER" ] || exit 0
exec "$ADAPTER" "$@"
