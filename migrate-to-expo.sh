#!/usr/bin/env bash
#
# migrate-to-expo.sh — Upgrade an existing Agent Manager install from the old
# Vite frontend (web/) to the new Expo frontend (apps/expo).
#
# Run ON the box that hosts Agent Manager, as the user that owns the install:
#
#   bash migrate-to-expo.sh [--dir <path>] [--port <port>] [-y] [--clean]
#
# What it does:
#   1. Finds the install and checks Node + GitHub auth prerequisites
#   2. Translates web/.env Firebase config to apps/expo/.env (EXPO_PUBLIC_*)
#   3. Fast-forwards the checkout to origin/main (recording a rollback SHA)
#   4. Installs dependencies (one root npm ci — workspaces cover apps/expo)
#   5. Builds the Expo web export
#   6. Keeps the box reachable (CM_TERMINAL_ALLOW_LAN) and restarts the server
#   7. Verifies the server responds; with --clean, removes old Vite artifacts
#
# Flags:
#   --dir <path>   Install location (default: probes ~/dev/claude-manager, then
#                  ~/claude-manager; the INSTALL_DIR env var also works)
#   --port <port>  Server port (default 4801; PORT env var also works)
#   -y, --yes      Unattended: auto-accept prompts (never implies --clean)
#   --clean        After a verified migration, delete leftover web/ artifacts
#
# Idempotent — safe to re-run. On an already-migrated box it acts as a plain
# "update to latest" runner (pull, install, build, restart).
#
# NOTE: stays compatible with macOS's stock bash 3.2 — no associative arrays,
# no ${var,,}, etc.
#
set -euo pipefail

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
Usage: bash migrate-to-expo.sh [options]

Upgrade an existing Agent Manager install from the Vite frontend to Expo.
Also works as a plain updater on already-migrated installs.

Options:
  --dir <path>   Install location (default: probes ~/dev/claude-manager, then
                 ~/claude-manager; the INSTALL_DIR env var also works)
  --port <port>  Server port (default 4801)
  -y, --yes      Unattended: auto-accept prompts (never implies --clean)
  --clean        After a verified migration, delete leftover web/ artifacts
                 (web/node_modules, web/dist, web/.env — roughly 350 MB)
  -h, --help     Show this help and exit
EOF
}

INSTALL_DIR="${INSTALL_DIR:-}"
PORT="${PORT:-4801}"
ASSUME_YES=false
CLEAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            INSTALL_DIR="${2:-}"
            [[ -z "$INSTALL_DIR" ]] && { err "--dir needs a value"; exit 1; }
            shift ;;
        --dir=*)  INSTALL_DIR="${1#*=}" ;;
        --port)
            PORT="${2:-}"
            [[ -z "$PORT" ]] && { err "--port needs a value"; exit 1; }
            shift ;;
        --port=*) PORT="${1#*=}" ;;
        -y|--yes) ASSUME_YES=true ;;
        --clean)  CLEAN=true ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# Yes/no prompt. Empty input (just Enter) counts as yes. With --yes it
# auto-accepts, echoing what it implied so unattended runs stay auditable.
confirm() {
    if [[ "$ASSUME_YES" == true ]]; then
        ok "$1 → yes (auto, --yes)"
        return 0
    fi
    local reply
    read -rp "$1 [Y/n]: " reply || return 1
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# Load NVM into this shell so node/npm/npx resolve (nvm only wires itself into
# interactive shells). `set +u` because nvm.sh isn't written to survive set -u.
load_nvm() {
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        set +u
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh"
        set -u
    fi
}

# True if something is listening on the given TCP port. Prefers ss (Linux);
# falls back to lsof (ships with macOS, installed by setup.sh on Ubuntu).
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

# Print the local address of each listener on the port, one per line
# ("0.0.0.0", "127.0.0.1", "*", "[::1]", ...). Empty output = no listener.
listener_addrs() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -ltn "sport = :$port" 2>/dev/null | awk 'NR>1 { addr=$4; sub(/:[0-9]+$/, "", addr); print addr }'
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"$port" -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR>1 { addr=$9; sub(/:[0-9]+$/, "", addr); print addr }'
    fi
}

# True if a listener on the port binds a non-loopback address (i.e. the box is
# reachable on this port from other machines).
binds_nonloopback() {
    local addrs a
    addrs=$(listener_addrs "$1")
    [[ -z "$addrs" ]] && return 1
    while IFS= read -r a; do
        case "$a" in
            127.*|::1|\[::1\]|localhost) ;;
            *) return 0 ;;
        esac
    done <<<"$addrs"
    return 1
}

# Stop whatever is listening on the port: SIGTERM, wait up to ~5s, then SIGKILL.
# Mirrors the upstream restart daemon. Covers servers started outside tmux or
# re-parented by a UI-triggered restart (which spawns detached).
kill_port_listeners() {
    local port="$1" pids
    if command -v lsof &>/dev/null; then
        pids=$(lsof -ti ":$port" -sTCP:LISTEN 2>/dev/null || true)
    else
        pids=$(ss -ltnp "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
    fi
    [[ -z "$pids" ]] && return 0
    info "Stopping process(es) still on port $port: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086 — pid list is intentionally word-split
    kill $pids 2>/dev/null || true
    for _ in $(seq 1 25); do
        port_listening "$port" || return 0
        sleep 0.2
    done
    warn "Still listening after SIGTERM — sending SIGKILL."
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    sleep 1
    return 0
}

# Run npm ci with retry on auth failures (403 from GitHub Packages). The
# repo's .npmrc points the @okthink-ai scope at GitHub Packages, which needs
# GITHUB_TOKEN — exported during preflight. npm ci (not install) so we get
# exactly the dependency tree upstream tested and never rewrite the lockfile —
# a rewritten lockfile would trip the clean-tree check on the next run.
npm_install_with_retry() {
    local DIR="$1" LABEL="$2" MAX_RETRIES=3 ATTEMPT=0
    while true; do
        ATTEMPT=$((ATTEMPT + 1))
        info "Installing $LABEL dependencies (attempt $ATTEMPT)..."
        if ( load_nvm; cd "$DIR" && npm ci ); then
            ok "$LABEL dependencies installed"
            return 0
        fi
        if [[ $ATTEMPT -ge $MAX_RETRIES ]]; then
            err "$LABEL install failed after $MAX_RETRIES attempts."
            err "Check your GitHub token has read:packages scope and your account can access okthink-ai."
            exit 1
        fi
        echo ""
        warn "Install failed — usually a GitHub Packages auth issue (403)."
        echo ""
        echo "  Possible fixes:"
        echo "    1. Refresh your token:  gh auth refresh -h github.com -s read:packages"
        echo "    2. Re-authenticate:     gh auth login -p ssh"
        echo "    3. Verify org access:   your GitHub account can access okthink-ai repos"
        echo ""
        if [[ "$ASSUME_YES" == true ]]; then
            warn "Retrying after refreshing GitHub credentials (--yes, no prompt)..."
        else
            read -rp "  Fix the issue and press Enter to retry, or Ctrl+C to quit... "
            echo ""
        fi
        command -v gh &>/dev/null && gh auth refresh -h github.com -s read:packages 2>/dev/null || true
    done
}

# Ensure exactly one CM_TERMINAL_ALLOW_LAN=1 line in the root .env. The -i.bak
# form works on both GNU and BSD sed.
enable_lan_flag() {
    sed -i.bak '/^CM_TERMINAL_ALLOW_LAN=/d' "$INSTALL_DIR/.env"
    rm -f "$INSTALL_DIR/.env.bak"
    echo 'CM_TERMINAL_ALLOW_LAN=1' >> "$INSTALL_DIR/.env"
    ok "Set CM_TERMINAL_ALLOW_LAN=1 in .env (server binds 0.0.0.0)"
}

# read_env_var <file> <name> — the value after the first '=', or empty.
read_env_var() {
    sed -n "s/^$2=//p" "$1" | head -1
}

# ─── Failure messaging ────────────────────────────────────────────────

# After the pull has moved the checkout, never fail silently — print the exact
# rollback recipe. --clean runs only after verification passes, so the old
# web/dist and web/node_modules are still on disk in every rollback scenario.
PREV_SHA=""
PULLED=false
HAD_WEB=false
on_exit() {
    local code=$?
    if [[ $code -ne 0 && "$PULLED" == true ]]; then
        echo "" >&2
        err "Migration failed after the code update. To roll back to the previous state:"
        echo "" >&2
        printf "    ${CYAN}cd %s${NC}\n" "$INSTALL_DIR" >&2
        printf "    ${CYAN}git checkout %s${NC}\n" "$PREV_SHA" >&2
        # The rollback commit only has a web/ workspace on first-time
        # migrations — already-migrated boxes roll back to the Expo layout.
        if [[ "$HAD_WEB" == true ]]; then
            printf "    ${CYAN}npm install && (cd web && npm install)${NC}\n" >&2
        else
            printf "    ${CYAN}npm install${NC}\n" >&2
        fi
        printf "    ${CYAN}PORT=%s npx tsx server/index.ts${NC}\n" "$PORT" >&2
        echo "" >&2
        err "Or fix the issue and re-run this script — every step is idempotent."
    fi
}
trap on_exit EXIT
trap 'echo; err "Interrupted. Re-run this script to resume — finished steps are skipped."; exit 130' INT

# ─── 1. Preflight ─────────────────────────────────────────────────────

section "1/8  Preflight"

# Without a TTY every prompt reads EOF and silently counts as a decline —
# including the one that keeps remote boxes reachable. Refuse to guess.
if [[ ! -t 0 && "$ASSUME_YES" != true ]]; then
    err "stdin is not a terminal, so prompts can't be answered."
    err "Re-run with -y for unattended mode, or allocate a TTY (ssh -t)."
    exit 1
fi

for cmd in git tmux curl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "'$cmd' is required but not installed."
        exit 1
    fi
done

# Resolve the install directory: --dir / INSTALL_DIR env, else probe the two
# installer defaults (setup.sh and ubuntu-install.sh use ~/dev/claude-manager;
# mac-install.sh uses ~/claude-manager).
if [[ -z "$INSTALL_DIR" ]]; then
    for candidate in "$HOME/dev/claude-manager" "$HOME/claude-manager"; do
        if [[ -d "$candidate/.git" ]]; then
            INSTALL_DIR="$candidate"
            break
        fi
    done
fi
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

if [[ -z "$INSTALL_DIR" ]]; then
    err "Could not find the Agent Manager checkout."
    err "Looked in ~/dev/claude-manager and ~/claude-manager."
    err "Point me at it:  bash migrate-to-expo.sh --dir /path/to/claude-manager"
    exit 1
elif [[ ! -d "$INSTALL_DIR/.git" ]]; then
    err "No git checkout at $INSTALL_DIR (missing .git)."
    err "Point --dir at the root of the claude-manager checkout."
    exit 1
fi

# The install belongs to a non-root user on VPS boxes — running as root would
# leave root-owned files in their checkout.
if [[ $EUID -eq 0 && ! -O "$INSTALL_DIR" ]]; then
    err "Run this as the user that owns $INSTALL_DIR, not as root."
    exit 1
fi

REMOTE_URL=$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null || true)
if [[ "$REMOTE_URL" != *claude-manager* ]]; then
    err "$INSTALL_DIR doesn't look like a claude-manager checkout (origin: ${REMOTE_URL:-none})."
    exit 1
fi
ok "Found install: $INSTALL_DIR"

load_nvm
if ! command -v node &>/dev/null; then
    err "node is not on PATH (checked nvm at ~/.nvm too). Install Node 20+ and re-run."
    exit 1
fi
NODE_MAJOR=$(node -v | sed 's/^v//' | cut -d. -f1)
if [[ "$NODE_MAJOR" -lt 20 ]]; then
    err "Node $(node -v) is too old — the Expo frontend needs Node 20+."
    err "Upgrade (e.g. 'nvm install 22') and re-run."
    exit 1
fi
ok "Node $(node -v)"

# GitHub Packages auth: the repo's .npmrc references \${GITHUB_TOKEN}; npm
# errors at install time if it's unset.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    ok "GITHUB_TOKEN already set"
elif command -v gh &>/dev/null && gh auth token &>/dev/null; then
    GITHUB_TOKEN=$(gh auth token)
    export GITHUB_TOKEN
    ok "GITHUB_TOKEN taken from 'gh auth token'"
else
    err "No GITHUB_TOKEN and no authenticated gh CLI. Installing dependencies needs a token"
    err "with read:packages for the okthink-ai org. Fix with one of:"
    err "  gh auth login -p ssh                       (then re-run)"
    err "  GITHUB_TOKEN=<PAT> bash migrate-to-expo.sh"
    exit 1
fi

# Refuse to guess around local changes — deployed boxes should be clean, on main.
# Exception: package-lock.json metadata churn. npm rewrites the lockfile when
# the local npm version differs from the one that generated it (e.g. npm 10
# strips the `libc` fields npm 11 writes), so any box where npm install ever
# ran is permanently "dirty" through no fault of the user. If lockfiles are
# the ONLY modification, restore them and move on; anything else still aborts.
cd "$INSTALL_DIR"
if [[ -n "$(git status --porcelain)" ]] \
   && [[ -z "$(git status --porcelain | grep -vE '^ M (.+/)?package-lock\.json$')" ]]; then
    info "Only package-lock.json metadata churn (differing npm versions) — restoring pristine lockfile(s)"
    git checkout -- ':(glob)**/package-lock.json'
fi
if [[ -n "$(git status --porcelain)" ]]; then
    err "The checkout has uncommitted changes — refusing to update over them."
    err "Inspect with 'git -C $INSTALL_DIR status', stash or commit, then re-run."
    exit 1
fi
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    err "The checkout is on '$BRANCH', not main — refusing to switch branches for you."
    err "Run 'git -C $INSTALL_DIR checkout main' if that's what you want, then re-run."
    exit 1
fi
ok "Checkout is clean and on main"

# Remember which layout we're rolling back to (pre-pull): the Vite layout has
# web/package.json; an already-migrated box doesn't. on_exit uses this to
# print the matching rollback recipe.
[[ -f "$INSTALL_DIR/web/package.json" ]] && HAD_WEB=true

# ─── 2. Capture the old frontend config ───────────────────────────────

section "2/8  Frontend Config (Firebase)"

# Defaults: the shared okthink Firebase project the installers ship
# (client-side keys, not secrets).
# Fallback copy — canonical values live in firebase-defaults.env; keep all
# four scripts (setup.sh, ubuntu-install.sh, mac-install.sh, this one) in sync.
FB_API_KEY="AIzaSyCGCFvt5iN93rQkH6R5zStANc2ZGj_YL8E"
FB_AUTH_DOMAIN="claude-manager-chat.firebaseapp.com"
FB_PROJECT_ID="claude-manager-chat"
FB_STORAGE_BUCKET="claude-manager-chat.firebasestorage.app"
FB_SENDER_ID="1041886556076"
FB_APP_ID="1:1041886556076:web:22e67ff4818b56c80e9409"
DROPPED_VAPID=""

# When run from a checkout of this repo (rather than curl'd standalone),
# prefer the canonical firebase-defaults.env next to this script so a key
# rotation only has to land in one place.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$SCRIPT_DIR/firebase-defaults.env" ]]; then
    # shellcheck source=firebase-defaults.env
    . "$SCRIPT_DIR/firebase-defaults.env"
    if [[ -n "${EXPO_PUBLIC_FIREBASE_API_KEY:-}" ]]; then FB_API_KEY="$EXPO_PUBLIC_FIREBASE_API_KEY"; fi
    if [[ -n "${EXPO_PUBLIC_FIREBASE_AUTH_DOMAIN:-}" ]]; then FB_AUTH_DOMAIN="$EXPO_PUBLIC_FIREBASE_AUTH_DOMAIN"; fi
    if [[ -n "${EXPO_PUBLIC_FIREBASE_PROJECT_ID:-}" ]]; then FB_PROJECT_ID="$EXPO_PUBLIC_FIREBASE_PROJECT_ID"; fi
    if [[ -n "${EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET:-}" ]]; then FB_STORAGE_BUCKET="$EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET"; fi
    if [[ -n "${EXPO_PUBLIC_FIREBASE_MESSAGING_SENDER_ID:-}" ]]; then FB_SENDER_ID="$EXPO_PUBLIC_FIREBASE_MESSAGING_SENDER_ID"; fi
    if [[ -n "${EXPO_PUBLIC_FIREBASE_APP_ID:-}" ]]; then FB_APP_ID="$EXPO_PUBLIC_FIREBASE_APP_ID"; fi
    ok "Loaded shared Firebase defaults from firebase-defaults.env"
fi

WEB_ENV="$INSTALL_DIR/web/.env"
CONFIG_SOURCE="installer defaults"
if [[ -f "$WEB_ENV" ]]; then
    # Take the old install's values wholesale — never mix two Firebase projects.
    CONFIG_SOURCE="translated from web/.env"
    FB_API_KEY=$(read_env_var "$WEB_ENV" VITE_FIREBASE_API_KEY)
    FB_AUTH_DOMAIN=$(read_env_var "$WEB_ENV" VITE_FIREBASE_AUTH_DOMAIN)
    FB_PROJECT_ID=$(read_env_var "$WEB_ENV" VITE_FIREBASE_PROJECT_ID)
    FB_STORAGE_BUCKET=$(read_env_var "$WEB_ENV" VITE_FIREBASE_STORAGE_BUCKET)
    FB_SENDER_ID=$(read_env_var "$WEB_ENV" VITE_FIREBASE_MESSAGING_SENDER_ID)
    FB_APP_ID=$(read_env_var "$WEB_ENV" VITE_FIREBASE_APP_ID)
    DROPPED_VAPID=$(read_env_var "$WEB_ENV" VITE_FIREBASE_VAPID_KEY)
    ok "Read Firebase config from web/.env"
    if [[ -n "$DROPPED_VAPID" ]]; then
        warn "web/.env sets VITE_FIREBASE_VAPID_KEY — the Expo app has no equivalent; dropping it."
    fi
    if [[ -z "$FB_API_KEY" || -z "$FB_AUTH_DOMAIN" || -z "$FB_PROJECT_ID" || -z "$FB_APP_ID" ]]; then
        warn "Some required Firebase values are empty — team features will be disabled."
        warn "(The app runs fine without them.)"
    fi
else
    ok "No web/.env found — using the installer's shared Firebase defaults"
fi

# ─── 3. Update the code ───────────────────────────────────────────────

section "3/8  Update to origin/main"

PREV_SHA=$(git rev-parse HEAD)
info "Current commit: $PREV_SHA (rollback point)"

if ! git pull --ff-only origin main; then
    err "Fast-forward pull failed — local main has diverged from origin/main."
    err "Inspect with 'git log --oneline origin/main..HEAD'. Nothing was changed."
    exit 1
fi
[[ "$(git rev-parse HEAD)" != "$PREV_SHA" ]] && PULLED=true
ok "Now at $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

if [[ ! -f "$INSTALL_DIR/apps/expo/package.json" ]]; then
    err "apps/expo is missing after the pull — origin/main doesn't have the Expo layout yet?"
    exit 1
fi

# ─── 4. Write apps/expo/.env ──────────────────────────────────────────

section "4/8  Write apps/expo/.env"

# Expo inlines EXPO_PUBLIC_* env at export time (the CLI auto-loads this file).
# No EXPO_PUBLIC_API_URL / EXPO_PUBLIC_WS_URL here: the root build script pins
# them to same-origin '/' and '/ws', and shell env beats .env in Expo's loader.
EXPO_ENV="$INSTALL_DIR/apps/expo/.env"
if [[ -f "$EXPO_ENV" ]]; then
    ok "apps/expo/.env already exists — leaving it untouched"
else
    info "Writing Firebase config ($CONFIG_SOURCE)..."
    cat > "$EXPO_ENV" <<ENVEOF
EXPO_PUBLIC_FIREBASE_API_KEY=$FB_API_KEY
EXPO_PUBLIC_FIREBASE_AUTH_DOMAIN=$FB_AUTH_DOMAIN
EXPO_PUBLIC_FIREBASE_PROJECT_ID=$FB_PROJECT_ID
EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET=$FB_STORAGE_BUCKET
EXPO_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=$FB_SENDER_ID
EXPO_PUBLIC_FIREBASE_APP_ID=$FB_APP_ID
ENVEOF
    ok "Firebase config written to apps/expo/.env"
fi

# ─── 5. Install dependencies ──────────────────────────────────────────

section "5/8  Install Dependencies"

# One root install now covers the frontend too (npm workspaces: apps/*).
npm_install_with_retry "$INSTALL_DIR" "root"

# ─── 6. Build ─────────────────────────────────────────────────────────

section "6/8  Build the Expo Frontend"

info "Building (expo export) — this can take a few minutes..."
( load_nvm; cd "$INSTALL_DIR" && npm run build )
ok "Frontend built to apps/expo/dist"

# Set server mode to prod so UI-triggered restarts preserve the mode.
echo "prod" > "$INSTALL_DIR/.server-mode"
ok "Server mode set to prod"

# ─── 7. Keep the box reachable, then restart ──────────────────────────

section "7/8  Restart the Server"

# The new server binds 127.0.0.1 unless CM_TERMINAL_ALLOW_LAN=1 (the in-app
# terminal is on by default). Boxes reached over Tailscale or a LAN IP need the
# flag persisted in .env — otherwise this upgrade takes them offline. On
# provisioned VPSes this is safe: the Hetzner firewall admits only SSH and ICMP
# inbound, and Tailscale traffic arrives via its own interface regardless.
touch "$INSTALL_DIR/.env"
if grep -q '^CM_TERMINAL_ALLOW_LAN=1' "$INSTALL_DIR/.env"; then
    ok "CM_TERMINAL_ALLOW_LAN=1 already set in .env"
elif binds_nonloopback "$PORT"; then
    info "The current server on port $PORT is bound to a non-loopback address —"
    info "this box is reached over the network (e.g. a Tailscale or LAN IP)."
    if confirm "Set CM_TERMINAL_ALLOW_LAN=1 in .env so it stays reachable remotely?"; then
        enable_lan_flag
    else
        warn "Skipped — the new server will bind 127.0.0.1 and remote access will stop working."
        warn "Fix later with: echo 'CM_TERMINAL_ALLOW_LAN=1' >> $INSTALL_DIR/.env  (then restart)"
    fi
elif port_listening "$PORT"; then
    ok "The current server binds loopback only (localhost access) — leaving .env as is"
elif command -v tailscale &>/dev/null && tailscale ip -4 &>/dev/null; then
    info "No server is running, but Tailscale is connected — treating this as a"
    info "remotely-accessed box (setup.sh installs are reached at http://<tailscale-ip>:$PORT)."
    if confirm "Set CM_TERMINAL_ALLOW_LAN=1 in .env so it stays reachable remotely?"; then
        enable_lan_flag
    else
        warn "Skipped — the new server will bind 127.0.0.1 and remote access will stop working."
        warn "Fix later with: echo 'CM_TERMINAL_ALLOW_LAN=1' >> $INSTALL_DIR/.env  (then restart)"
    fi
else
    # No running server, no Tailscale — can't tell how this box is accessed.
    # Silently widening a localhost-only box to 0.0.0.0 is the worse default,
    # so under --yes we leave it unset and say so loudly.
    if [[ "$ASSUME_YES" == true ]]; then
        warn "Can't tell whether this box is accessed remotely (no server running,"
        warn "no Tailscale). Leaving .env unchanged — the server will bind 127.0.0.1."
        warn "If you reach it from another machine, run:"
        warn "  echo 'CM_TERMINAL_ALLOW_LAN=1' >> $INSTALL_DIR/.env   (then restart the server)"
    else
        echo "  Do you access Agent Manager from another machine (Tailscale/LAN IP),"
        echo "  or only via http://localhost:$PORT on this box?"
        if confirm "Accessed remotely — set CM_TERMINAL_ALLOW_LAN=1?"; then
            enable_lan_flag
        else
            ok "Leaving .env unchanged (localhost only)"
        fi
    fi
fi

# ── Stop the old server ──
if tmux has-session -t am-server 2>/dev/null; then
    info "Interrupting the server in tmux session 'am-server'..."
    tmux send-keys -t am-server C-c
    sleep 2
fi
kill_port_listeners "$PORT"
ok "Port $PORT is free"

# ── Start the new server ──
# CM_FRONTEND_DIST isn't needed — the server defaults to apps/expo/dist.
# CM_TERMINAL_ALLOW_LAN comes from .env via dotenv.
# Always launch in a brand-new session: the old pane may not be an idle shell
# (a leftover less/vim, or the dying server) and would swallow the command.
tmux kill-session -t am-server 2>/dev/null || true
info "Creating tmux session 'am-server'..."
tmux new-session -d -s am-server -c "$INSTALL_DIR"
info "Starting the server..."
# Single-quote so the pane's shell expands $HOME/$NVM_DIR and sources nvm itself.
tmux send-keys -t am-server \
    'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; cd "'"$INSTALL_DIR"'"; '"PORT=$PORT npx tsx server/index.ts" Enter

info "Waiting for the server to come up (up to 30s)..."
STARTED=false
for _ in $(seq 1 30); do
    if port_listening "$PORT"; then STARTED=true; break; fi
    sleep 1
done
if [[ "$STARTED" == true ]]; then
    ok "Server is listening on port $PORT"
else
    err "Server didn't come up within 30s — check: tmux attach -t am-server"
    exit 1
fi

# ─── 8. Verify + cleanup ──────────────────────────────────────────────

section "8/8  Verify"

# HTTPS iff the repo has TLS certs, same rule the server itself uses.
# -k tolerates self-signed certs.
PROTO=http
[[ -f "$INSTALL_DIR/.certs/key.pem" && -f "$INSTALL_DIR/.certs/cert.pem" ]] && PROTO=https

STATUS_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$PROTO://localhost:$PORT/api/status" || echo 000)
if [[ "$STATUS_CODE" == 200 ]]; then
    ok "API responds: $PROTO://localhost:$PORT/api/status"
else
    err "API check failed (HTTP $STATUS_CODE) — check: tmux attach -t am-server"
    exit 1
fi

ROOT_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$PROTO://localhost:$PORT/" || echo 000)
if [[ "$ROOT_CODE" == 200 ]]; then
    ok "Frontend serves: $PROTO://localhost:$PORT/"
else
    err "Frontend check failed (HTTP $ROOT_CODE) — the Expo export may be missing."
    err "Re-run this script, or check apps/expo/dist and: tmux attach -t am-server"
    exit 1
fi

# Cleanup runs only here, after verification passed — so a rollback always
# finds the old build and dependencies still on disk.
if [[ "$CLEAN" == true ]]; then
    if [[ -d "$INSTALL_DIR/web" ]]; then
        info "Removing old Vite artifacts (web/)..."
        rm -rf "$INSTALL_DIR/web/node_modules" "$INSTALL_DIR/web/dist"
        [[ -f "$EXPO_ENV" ]] && rm -f "$INSTALL_DIR/web/.env"
        rmdir "$INSTALL_DIR/web" 2>/dev/null || true
        ok "Old Vite artifacts removed (~350 MB reclaimed)"
    else
        ok "No web/ leftovers to clean"
    fi
elif [[ -d "$INSTALL_DIR/web" ]]; then
    info "Old Vite artifacts remain in web/ (~350 MB). Reclaim with: bash migrate-to-expo.sh --clean"
fi

# ─── Done ─────────────────────────────────────────────────────────────

section "Migration Complete!"

printf "  ${GREEN}Install:${NC}   %s\n" "$INSTALL_DIR"
printf "  ${GREEN}Was:${NC}       %s\n" "$PREV_SHA"
printf "  ${GREEN}Now:${NC}       %s\n" "$(git -C "$INSTALL_DIR" rev-parse HEAD)"
printf "  ${GREEN}Config:${NC}    apps/expo/.env (%s)\n" "$CONFIG_SOURCE"
if grep -q '^CM_TERMINAL_ALLOW_LAN=1' "$INSTALL_DIR/.env" 2>/dev/null; then
    ACCESS_IP=""
    if command -v tailscale &>/dev/null; then
        ACCESS_IP=$(tailscale ip -4 2>/dev/null || true)
    fi
    if [[ -z "$ACCESS_IP" ]]; then
        ACCESS_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    printf "  ${GREEN}URL:${NC}       %s://%s:%s\n" "$PROTO" "${ACCESS_IP:-<this-box-ip>}" "$PORT"
else
    printf "  ${GREEN}URL:${NC}       %s://localhost:%s\n" "$PROTO" "$PORT"
fi
if [[ -n "$DROPPED_VAPID" ]]; then
    printf "  ${YELLOW}Note:${NC}      VITE_FIREBASE_VAPID_KEY had no Expo equivalent and was dropped.\n"
fi
echo ""
echo "  Rollback point (if anything is off): git checkout $PREV_SHA"
echo ""
