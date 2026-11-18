#!/bin/bash
# The program of "Synapse Desktop Dev.app", which `just desktop-launcher` makes: it starts
# `just desktop` in the checkout the app was made from, detached, so the launcher quits at once and
# the dev build goes on with no terminal. What the build prints goes to a log, and a notification
# says when it stops with an error. A second click while it runs brings the window forward instead
# of starting another one, which would find the dev server's port taken.
set -euo pipefail

CONTENTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cat "$CONTENTS/Resources/repo")"
readonly CONTENTS REPO
readonly LOG="$HOME/Library/Logs/synapse-desktop-dev.log"
readonly APP_ID='io.github.imunitic.synapse-desktop'
readonly PORT=5173

notify() {
    osascript -e "display notification \"$1\" with title \"Synapse Desktop Dev\"" || true
}

running() {
    ps -axo comm= | grep -q 'target/debug/synapse-desktop$'
}

main() {
    if running; then
        osascript -e "tell application id \"$APP_ID\" to activate" >/dev/null 2>&1 || true
        exit 0
    fi
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
        notify "Port $PORT is taken by another program, so the dev build cannot start."
        exit 1
    fi
    if [[ ! -f "$REPO/justfile" ]]; then
        notify "The checkout $REPO is not there any more. Run just desktop-launcher again."
        exit 1
    fi

    mkdir -p "$(dirname "$LOG")"
    if [[ -f "$LOG" ]]; then
        mv -f "$LOG" "$LOG.1"
    fi
    printf 'Synapse Desktop Dev, started %s from %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REPO" >"$LOG"

    # An interactive login shell has the PATH a terminal has: Homebrew, cargo, and alr, which
    # .zshrc adds. A program started from the Dock has almost none of it.
    # REPO and LOG are readonly, so they are exported: bash refuses to set a readonly variable in
    # front of a command, even to its own value.
    export REPO LOG
    nohup /bin/zsh -lic '
        cd "$REPO" || exit 1
        if ! just desktop; then
            osascript -e "display notification \"The dev build stopped with an error. See ~/Library/Logs/synapse-desktop-dev.log\" with title \"Synapse Desktop Dev\""
        fi
    ' >>"$LOG" 2>&1 </dev/null &
    disown
}

main "$@"
