#!/usr/bin/env bash
#
# migrate-to-agent-manager.sh — move an existing install from the Claude
# Manager identity to Agent Manager.
#
# Upstream renamed the product and repository (okthink-ai/claude-manager →
# okthink-ai/agent-manager). GitHub redirects the old repo path and upstream
# kept every internal compatibility identifier, so nothing is broken today —
# but existing boxes still carry the old name in their git remote URL and
# install directory, and serve a frontend build that predates the rename.
#
# Run this ON the box, as the app user. It:
#   1. Runs every guard up front — no mutations until all of them pass
#   2. Repoints the git remote at okthink-ai/agent-manager (preserving form)
#   3. Stops the server (am-server tmux session, then port fallback)
#   4. Renames the install directory claude-manager → agent-manager
#   5. Delegates update + rebuild + restart + verify to migrate-to-expo.sh
#      (or, with --skip-update, relaunches the server itself from the new path)
#   6. Prints a summary with the two-layer rollback recipe
#
# There is no data migration: the database is <install>/data/agent-manager.db
# (the filename predates the rename) and resolves cwd-relative, so the
# directory rename carries data/, .env, node_modules, and .server-mode along.
#
# Flags:
#   --dir <path>   Install location (default: probe ~/dev/claude-manager,
#                  ~/claude-manager, then the already-renamed equivalents)
#   -y, --yes      Unattended: auto-accept prompts
#   --port <n>     Server port (default 4801)
#   --skip-update  Rename + remote only; relaunch the server without updating
#
# Idempotent — on an already-renamed box it acts as a plain "update to latest".
# Portable: Ubuntu and macOS (stock bash 3.2 — no associative arrays, etc.).
#
set -euo pipefail

OLD_REPO="okthink-ai/claude-manager"
NEW_REPO="okthink-ai/agent-manager"
SETUP_RAW_BASE="https://raw.githubusercontent.com/okthink-ai/agent-manager-setup/main"

PORT="${PORT:-4801}"
ASSUME_YES=false
SKIP_UPDATE=false
INSTALL_DIR="${INSTALL_DIR:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}==> %s${NC}\n" "$*"; }
ok()    { printf "${GREEN}==> %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}==> %s${NC}\n" "$*"; }
err()   { printf "${RED}==> %s${NC}\n" "$*" >&2; }

section() {
    echo ""
    printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
    printf "${BOLD}  %s${NC}\n" "$*"
    printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
    echo ""
}

usage() {
    cat <<EOF
Usage: bash migrate-to-agent-manager.sh [--dir <path>] [--port <port>] [-y] [--skip-update]

Move an existing Agent Manager install off the old Claude Manager identity:
repoint the git remote, rename the install directory, update and rebuild.
Also works as a plain updater on already-renamed installs.

Options:
  --dir <path>   Install location (default: probe the standard locations)
  -y, --yes      Unattended: auto-accept prompts
  --port <n>     Server port (default 4801)
  --skip-update  Rename + remote only — skip the pull/build, but still
                 relaunch the server from the new path if one was running
  -h, --help     Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)   INSTALL_DIR="${2:-}"; [[ -z "$INSTALL_DIR" ]] && { err "--dir needs a value"; exit 1; }; shift ;;
        --dir=*) INSTALL_DIR="${1#*=}" ;;
        --port)   PORT="${2:-}"; [[ -z "$PORT" ]] && { err "--port needs a value"; exit 1; }; shift ;;
        --port=*) PORT="${1#*=}" ;;
        -y|--yes) ASSUME_YES=true ;;
        --skip-update) SKIP_UPDATE=true ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

confirm() {
    if [[ "$ASSUME_YES" == true ]]; then
        ok "$1 → yes (auto, --yes)"
        return 0
    fi
    read -rp "$1 (y/n): " REPLY
    [[ "$REPLY" =~ ^[Yy] ]]
}

# True if something is listening on the given TCP port. Prefers ss (Linux);
# falls back to lsof (ships with macOS).
port_listening() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN
    elif command -v lsof &>/dev/null; then
        lsof -i ":$port" -sTCP:LISTEN &>/dev/null
    else
        return 1
    fi
}

# Kill whatever listens on the port: TERM, wait, then KILL. Returns cleanly
# when nothing is listening.
kill_port_listeners() {
    local port="$1" pids="" i
    if command -v lsof &>/dev/null; then
        pids=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null || true)
    elif command -v ss &>/dev/null; then
        pids=$(ss -ltnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)
    fi
    [[ -z "$pids" ]] && return 0
    info "Stopping process(es) still on port $port: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        port_listening "$port" || return 0
        sleep 1
    done
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
}

# In-place sed that works with both GNU sed (Ubuntu) and BSD sed (macOS).
sed_inplace() {
    local expr="$1" file="$2"
    if sed --version >/dev/null 2>&1; then
        sed -i "$expr" "$file"
    else
        sed -i '' "$expr" "$file"
    fi
}

# ─── Preflight: locate the install, run every guard, mutate nothing ───

section "Preflight"

for cmd in git tmux curl; do
    command -v "$cmd" &>/dev/null || { err "'$cmd' is required but not found."; exit 1; }
done

# Locate the install. Old-name paths first (the thing this script exists to
# fix), then already-renamed paths so re-runs act as a plain update. If an old
# directory and its renamed sibling BOTH exist, refuse to guess which is real.
if [[ -z "$INSTALL_DIR" ]]; then
    for parent in "$HOME/dev" "$HOME"; do
        if [[ -d "$parent/claude-manager" && -d "$parent/agent-manager" ]]; then
            err "Both $parent/claude-manager and $parent/agent-manager exist."
            err "Refusing to guess which is the real install — pass --dir explicitly"
            err "and remove or rename the other directory first."
            exit 1
        fi
    done
    for candidate in "$HOME/dev/claude-manager" "$HOME/claude-manager" \
                     "$HOME/dev/agent-manager" "$HOME/agent-manager"; do
        if [[ -d "$candidate" ]]; then
            INSTALL_DIR="$candidate"
            break
        fi
    done
    if [[ -z "$INSTALL_DIR" ]]; then
        err "No install found. Probed: ~/dev/claude-manager, ~/claude-manager,"
        err "~/dev/agent-manager, ~/agent-manager. Pass --dir <path>."
        exit 1
    fi
fi
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
[[ -d "$INSTALL_DIR" ]] || { err "Not a directory: $INSTALL_DIR"; exit 1; }
info "Install: $INSTALL_DIR"

# Decide the rename. A custom directory name is left alone: the remote update
# and the delegated update still apply, the mv just isn't ours to make.
NEEDS_RENAME=false
NEW_DIR="$INSTALL_DIR"
case "$(basename "$INSTALL_DIR")" in
    claude-manager)
        NEEDS_RENAME=true
        NEW_DIR="$(dirname "$INSTALL_DIR")/agent-manager"
        if [[ -e "$NEW_DIR" ]]; then
            err "Rename target already exists: $NEW_DIR"
            err "Refusing to guess which install is real. Remove or rename one, then re-run."
            exit 1
        fi
        ;;
    agent-manager)
        ok "Directory already renamed"
        ;;
    *)
        warn "Directory has a custom name ($(basename "$INSTALL_DIR")) — leaving it; updating remote only."
        ;;
esac

cd "$INSTALL_DIR"
git rev-parse --is-inside-work-tree &>/dev/null || { err "$INSTALL_DIR is not a git checkout."; exit 1; }

# Same clean-tree rules as migrate-to-expo.sh: tolerate package-lock.json
# metadata churn (npm version drift rewrites it), refuse anything else, and
# require main. All of this BEFORE any mutation — never leave a half-renamed box.
if [[ -n "$(git status --porcelain)" ]] \
   && [[ -z "$(git status --porcelain | grep -vE '^ M (.+/)?package-lock\.json$')" ]]; then
    info "Only package-lock.json metadata churn — restoring pristine lockfile(s)"
    git checkout -- ':(glob)**/package-lock.json'
fi
if [[ -n "$(git status --porcelain)" ]]; then
    err "The checkout has uncommitted changes — refusing to migrate over them."
    err "Inspect with 'git -C $INSTALL_DIR status', stash or commit, then re-run."
    exit 1
fi
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    err "The checkout is on '$BRANCH', not main — refusing to migrate a working branch."
    exit 1
fi
ok "Checkout is clean and on main"

# CM_DB_PATH guard. Unset (the default) or cwd-relative values move with the
# directory. An absolute path inside the old install gets rewritten after the
# move. Any other absolute path means this box was hand-configured in a way
# this script shouldn't guess about.
REWRITE_DB_PATH=false
DB_PATH_VALUE=""
if [[ -f .env ]] && grep -q '^CM_DB_PATH=' .env; then
    DB_PATH_VALUE=$(grep '^CM_DB_PATH=' .env | head -1 | cut -d= -f2-)
    if [[ "$DB_PATH_VALUE" == "$INSTALL_DIR"/* ]]; then
        # Inside the install: fine as-is when we're not renaming; needs a
        # rewrite when we are.
        if [[ "$NEEDS_RENAME" == true ]]; then
            REWRITE_DB_PATH=true
            info "CM_DB_PATH points inside the install — will rewrite it after the rename"
        fi
    elif [[ "$DB_PATH_VALUE" == /* ]]; then
        err "CM_DB_PATH is set to an absolute path outside the install: $DB_PATH_VALUE"
        err "This box was hand-configured — move the database yourself, then re-run"
        err "with the value updated (or removed, to use the default)."
        exit 1
    fi
fi

# Remote plan (computed here, applied after consent).
ORIGIN_URL=$(git remote get-url origin)
NEW_URL="$ORIGIN_URL"
if [[ "$ORIGIN_URL" == *"$OLD_REPO"* ]]; then
    NEW_URL="${ORIGIN_URL/$OLD_REPO/$NEW_REPO}"
elif [[ "$ORIGIN_URL" == *"$NEW_REPO"* ]]; then
    ok "Remote already points at $NEW_REPO"
else
    warn "Origin is neither the old nor the new upstream ($ORIGIN_URL) — leaving it untouched."
fi

ok "All guards passed"

# ─── Consent ──────────────────────────────────────────────────────────

echo ""
echo "  This will:"
[[ "$NEW_URL" != "$ORIGIN_URL" ]] && echo "    - repoint origin: $ORIGIN_URL → $NEW_URL"
if [[ "$NEEDS_RENAME" == true ]]; then
    echo "    - stop the server and rename: $INSTALL_DIR → $NEW_DIR"
fi
if [[ "$SKIP_UPDATE" == true ]]; then
    echo "    - relaunch the server from the new path (no update — --skip-update)"
else
    echo "    - update to latest main, rebuild, and restart (via migrate-to-expo.sh)"
fi
echo ""
if ! confirm "Proceed?"; then
    err "Aborted — nothing was changed."
    exit 1
fi

# From here on, mutations happen. If anything fails after the mv, print the
# identity rollback (the delegated updater prints its own content rollback).
MOVED=false
on_exit() {
    local code=$?
    if [[ $code -ne 0 && "$MOVED" == true ]]; then
        echo "" >&2
        warn "Something failed after the rename. Identity rollback:"
        printf "    ${CYAN}mv %s %s${NC}\n" "$NEW_DIR" "$INSTALL_DIR" >&2
        printf "    ${CYAN}git -C %s remote set-url origin %s${NC}\n" "$INSTALL_DIR" "$ORIGIN_URL" >&2
        warn "(A failed update inside the new path has its own rollback recipe above.)"
    fi
}
trap on_exit EXIT

# ─── Remote ──────────────────────────────────────────────────────────

section "Repoint the Git Remote"

if [[ "$NEW_URL" != "$ORIGIN_URL" ]]; then
    git remote set-url origin "$NEW_URL"
    ok "origin: $ORIGIN_URL → $NEW_URL"
else
    ok "origin unchanged: $ORIGIN_URL"
fi

# ─── Stop, rename, rewrite ───────────────────────────────────────────

WAS_RUNNING=false
if [[ "$NEEDS_RENAME" == true ]]; then
    section "Stop the Server & Rename"

    port_listening "$PORT" && WAS_RUNNING=true
    if tmux has-session -t am-server 2>/dev/null; then
        info "Interrupting the server in tmux session 'am-server'..."
        tmux send-keys -t am-server C-c 2>/dev/null || true
        sleep 2
    fi
    kill_port_listeners "$PORT"
    ok "Port $PORT is free"

    cd "$(dirname "$INSTALL_DIR")"
    mv "$INSTALL_DIR" "$NEW_DIR"
    MOVED=true
    ok "Renamed: $INSTALL_DIR → $NEW_DIR"

    if [[ "$REWRITE_DB_PATH" == true ]]; then
        NEW_DB_VALUE="${DB_PATH_VALUE/#$INSTALL_DIR/$NEW_DIR}"
        sed_inplace "s|^CM_DB_PATH=.*|CM_DB_PATH=$NEW_DB_VALUE|" "$NEW_DIR/.env"
        ok "CM_DB_PATH rewritten: $DB_PATH_VALUE → $NEW_DB_VALUE"
    fi
fi

# ─── Update (delegated) or relaunch ──────────────────────────────────

if [[ "$SKIP_UPDATE" == true ]]; then
    section "Relaunch (update skipped)"

    if [[ "$WAS_RUNNING" == true ]]; then
        # Mirror the updater's relaunch: kill any half-dead session, start
        # fresh from the NEW path so the server's cwd (and its cwd-relative
        # data/) follow the rename.
        tmux kill-session -t am-server 2>/dev/null || true
        tmux new-session -d -s am-server -c "$NEW_DIR"
        tmux send-keys -t am-server \
            'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '"PORT=$PORT npx tsx server/index.ts" Enter
        info "Waiting for the server to come up (up to 30s)..."
        STARTED=false
        for _ in $(seq 1 30); do
            if port_listening "$PORT"; then STARTED=true; break; fi
            sleep 1
        done
        if [[ "$STARTED" == true ]]; then
            ok "Server is listening on port $PORT"
            STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/api/status" 2>/dev/null || echo 000)
            if [[ "$STATUS" == "200" ]]; then
                ok "API responds: http://localhost:$PORT/api/status"
            else
                warn "Server is up but /api/status returned $STATUS — check: tmux attach -t am-server"
            fi
        else
            err "Server didn't come up within 30s — check: tmux attach -t am-server"
            exit 1
        fi
    else
        info "No server was running before the rename — leaving it stopped."
    fi
else
    section "Update & Rebuild (delegated)"

    # migrate-to-expo.sh is the established updater: clean-tree guard,
    # ff-only pull (now riding the new remote URL), npm ci, expo export,
    # restart from its --dir, /api/status verify, content-rollback recipe.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    COMPANION="$SCRIPT_DIR/migrate-to-expo.sh"
    if [[ ! -f "$COMPANION" ]]; then
        info "Fetching migrate-to-expo.sh (not adjacent on disk)..."
        COMPANION=$(mktemp)
        curl -fsSL "$SETUP_RAW_BASE/migrate-to-expo.sh" -o "$COMPANION"
    fi
    bash "$COMPANION" --dir "$NEW_DIR" --port "$PORT" -y
fi

# ─── Done ────────────────────────────────────────────────────────────

section "Migration Complete!"

printf "  ${GREEN}Install:${NC}  %s\n" "$NEW_DIR"
printf "  ${GREEN}Remote:${NC}   %s\n" "$NEW_URL"
printf "  ${GREEN}URL:${NC}      http://localhost:%s  (or this box's Tailscale/LAN IP)\n" "$PORT"
echo ""
if [[ "$NEEDS_RENAME" == true ]]; then
    echo "  Things that still reference the old path and need a human:"
    echo "    - shell history, personal scripts, and open SSH sessions"
    echo "    - running agent sessions: they keep working (their cwd followed the"
    echo "      rename), but display stale paths until you restart them"
    echo ""
    echo "  Rollback, if needed (two independent layers):"
    printf "    identity:  ${CYAN}mv %s %s && git -C %s remote set-url origin %s${NC}\n" \
        "$NEW_DIR" "$INSTALL_DIR" "$INSTALL_DIR" "$ORIGIN_URL"
    echo "    content:   the pre-pull SHA recipe printed by the updater above"
    echo ""
fi
