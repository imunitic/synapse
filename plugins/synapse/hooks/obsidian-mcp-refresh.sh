#!/bin/bash
# SessionStart hook: keeps the `obsidian` MCP server registration current,
# automatically, every session -- the hook-driven replacement for manually
# running setup-obsidian-mcp.sh. Independent of, and never wired through,
# fetch-and-run.sh/synapse-hook: different domain (wiring up the connection
# to the vault, not Synapse's own code-graph/vault logic), no reason to be
# compiled Zig (once-per-session, shell-subprocess-heavy, and the working
# logic already exists as shell), and kept separate so a bug here can never
# risk the core Synapse injection. See designs/synapse/sb — Convert Synapse
# into a proper Claude Code plugin.md for the full reasoning.
#
# Every missing precondition is silence, same convention every other Synapse
# hook already follows -- this never blocks a turn, and produces no stdout
# (a SessionStart hook's stdout becomes injected context; this is a pure
# side-effecting maintenance task, nothing worth telling the model). Genuine
# problems go to stderr only, same as the original script already did.
#
# One real, pre-existing limitation, not new here: MCP servers connect at
# Claude Code startup, before any hook fires, so this can't fix the *current*
# session's connection -- first-time registration or a cert/key rotation
# still needs one restart to take effect.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# Same tiered resolution core.conf.vaultDir already uses in Zig, mirrored
# here rather than shelling out to a not-yet-cached synapse binary -- keeps
# this hook fully independent of the other one. The env var wins outright;
# otherwise each conf file is *sourced*, not parsed by hand, since
# synapse.conf is shell syntax by design (same technique setup.sh's own
# Index.md-seeding step already uses).
resolve_conf() {
    local name="$1" xdg="${XDG_CONFIG_HOME:-}"
    if [ -n "$xdg" ] && [ -f "$xdg/synapse/$name" ]; then echo "$xdg/synapse/$name"; return; fi
    if [ -f "$HOME/.config/synapse/$name" ]; then echo "$HOME/.config/synapse/$name"; return; fi
    if [ -f "$HOME/.claude/$name" ]; then echo "$HOME/.claude/$name"; return; fi
}

VAULT="${OBSIDIAN_VAULT_DIR:-}"
if [ -z "$VAULT" ]; then
    for name in synapse.conf second-brain.conf; do
        conf="$(resolve_conf "$name")"
        [ -n "$conf" ] || continue
        VAULT="$(. "$conf" 2>/dev/null; echo "${OBSIDIAN_VAULT_DIR:-}")"
        [ -n "$VAULT" ] && break
    done
fi
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 0

PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
[ -f "$PLUGIN_DATA" ] || exit 0

CERT_PATH="$HOME/.claude/obsidian-local-rest-api-ca.pem"
API_KEY="$(jq -r '.apiKey' "$PLUGIN_DATA")"
PORT="$(jq -r '.port' "$PLUGIN_DATA")"
[ -n "$API_KEY" ] && [ "$API_KEY" != "null" ] || exit 0
[ -n "$PORT" ] && [ "$PORT" != "null" ] || exit 0

jq -r '.crypto.cert' "$PLUGIN_DATA" > "$CERT_PATH"

# Verify it actually validates before wiring anything in.
endpoint_ok=1
if ! curl -s --cacert "$CERT_PATH" "https://127.0.0.1:$PORT/" -o /dev/null --max-time 5; then
    endpoint_ok=0
fi

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
TMP="$(mktemp "${TMPDIR:-/tmp}/obsidian-mcp-refresh.XXXXXX")"
jq --arg cert "$CERT_PATH" '.env = (.env // {}) | .env.NODE_EXTRA_CA_CERTS = $cert' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

# Registering means removing first -- `claude mcp add` will not overwrite an
# existing name, and there is no atomic replace. A registration that already
# exists is, by definition, one that worked at some point; replacing it with
# one pointing at a port that does not currently answer trades something
# working for nothing, so leave it alone in that case rather than risk it.
registered=0
claude mcp get obsidian >/dev/null 2>&1 && registered=1

if [ "$endpoint_ok" -eq 0 ] && [ "$registered" -eq 1 ]; then
    echo "synapse: obsidian MCP endpoint unreachable, left the existing registration in place" >&2
    exit 0
fi

claude mcp remove obsidian -s user >/dev/null 2>&1 || true
claude mcp add --transport http obsidian "https://127.0.0.1:$PORT/mcp/" \
    --header "Authorization: Bearer $API_KEY" \
    -s user >/dev/null 2>&1 || true
