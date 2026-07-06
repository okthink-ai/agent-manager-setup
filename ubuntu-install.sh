#!/usr/bin/env bash
#
# ubuntu-install.sh — Install Agent Manager on an Ubuntu server you already own.
#
# Run this ON the server, as your normal sudo user (NOT root). Unlike setup.sh
# (which provisions a fresh, root-owned Hetzner VPS), this script assumes the box
# already exists, your user and SSH access are already set up. You choose how to
# reach the app: localhost-only (loopback; reach it via an SSH tunnel — most
# secure) or direct IP (bound to all interfaces).
#
# It:
#   1. Optionally installs any missing base packages (skips ones you already have)
#   2. Installs NVM + Node.js 22
#   3. Installs GitHub CLI and authenticates (interactive, or GH_TOKEN)
#   4. Installs Claude Code; optionally Codex / Gemini / Pi CLIs
#   5. Clones Agent Manager into a directory you choose and builds it
#   6. Optionally starts the server (localhost-only or direct IP — your choice)
#
# It deliberately does NOT create a user, touch SSH config, or install a
# firewall/fail2ban/Tailscale — this is your own box.
#
# Optional env vars:
#   GH_TOKEN — a GitHub PAT with repo + read:packages (skips the browser login)
#   PORT     — server port (default 4801)
#
# Designed to be idempotent — safe to re-run after a failure.
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

REPO_URL="https://github.com/okthink-ai/claude-manager.git"
PORT="${PORT:-4801}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# Load NVM into the current shell so node/npm/npx resolve. NVM only wires itself
# into future *interactive* shells via ~/.bashrc; this script's shell needs it
# sourced explicitly. `set +u` around the source because nvm.sh isn't written to
# survive `set -u`.
NVM_DIR="$HOME/.nvm"
load_nvm() {
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        set +u
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh"
        set -u
    fi
}

# True if something is listening on the given TCP port. Prefers ss (iproute2,
# present by default); falls back to lsof, which is only an optional package.
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

# Install an optional global npm CLI (idempotent). A failed install warns and
# continues rather than aborting the whole setup.
#   install_npm_cli <binary> <npm-package> <label> [auth-hint]
install_npm_cli() {
    local bin="$1" pkg="$2" label="$3" auth="${4:-}"
    if ( load_nvm; command -v "$bin" ) &>/dev/null; then
        ok "$label already installed"
    elif ( load_nvm; npm install -g "$pkg" ); then
        ok "$label installed"
    else
        warn "$label install failed — skipping. Install later with: npm install -g $pkg"
        return 0
    fi
    [[ -n "$auth" ]] && echo "    auth: $auth"
    return 0
}

# ─── Pre-flight checks ───────────────────────────────────────────────

section "Agent Manager — Ubuntu Server Install"

if [[ $EUID -eq 0 ]]; then
    err "Run this as your normal sudo user, NOT as root."
    err "It uses 'sudo' only for package installs; everything else runs as you."
    exit 1
fi

if ! command -v sudo &>/dev/null; then
    err "'sudo' is required but not found. Install it (as root: apt install sudo)"
    err "and make sure your user is in the sudo group, then re-run."
    exit 1
fi

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Proceed with caution on other distros."
fi

# ─── Collect info upfront ─────────────────────────────────────────────

read -rp "Git name (for commits, e.g. 'Jane Smith'): " GIT_NAME
read -rp "Git email (for commits): " GIT_EMAIL

DEFAULT_DIR="$HOME/dev/claude-manager"
read -rp "Install directory for Agent Manager [$DEFAULT_DIR]: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
# Expand a leading ~ to $HOME (the shell won't, since it's inside a variable).
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

# How you'll reach Agent Manager. This decides how the server binds:
#   localhost → loopback (127.0.0.1) only; reach it via an SSH tunnel. Most secure.
#   direct    → all interfaces (0.0.0.0); reach it at http://<server-ip>:PORT.
echo ""
echo "  How will you reach Agent Manager on this box?"
echo "    1) localhost — bind loopback only; reach it via an SSH tunnel (most secure)"
echo "    2) direct IP — bind all interfaces; reach it at http://<server-ip>:$PORT"
echo ""
read -rp "Access mode [1=localhost / 2=direct IP] (default 1): " ACCESS_CHOICE
case "$ACCESS_CHOICE" in
    2|direct|d|ip|IP) ACCESS_MODE="direct" ;;
    *)                ACCESS_MODE="localhost" ;;
esac

# Env prefix for launching the server. Direct mode sets CM_TERMINAL_ALLOW_LAN=1
# (bind 0.0.0.0); localhost mode omits it so the server binds loopback.
if [[ "$ACCESS_MODE" == "direct" ]]; then
    LAUNCH_ENV="CM_TERMINAL_ALLOW_LAN=1 PORT=$PORT"
else
    LAUNCH_ENV="PORT=$PORT"
fi

echo ""
info "Installing Agent Manager into: $INSTALL_DIR"
info "Access mode: $ACCESS_MODE"
[[ -n "$GH_TOKEN" ]] && ok "GitHub token detected — will authenticate non-interactively"
echo ""

# ─── 1. System packages (optional) ───────────────────────────────────

section "1/6  Base Packages"

# Detect with `dpkg -s` rather than `command -v`: build-essential is a metapackage
# with no binary of its own, so command-lookup can't see it.
BASE_PKGS=(build-essential curl wget git unzip tmux htop lsof)
MISSING_PKGS=()
for pkg in "${BASE_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done

if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
    ok "All base packages already installed — skipping"
else
    info "Missing packages: ${MISSING_PKGS[*]}"
    read -rp "Install them now with apt? (y/n): " WANT_PKGS
    if [[ "$WANT_PKGS" =~ ^[Yy] ]]; then
        sudo apt-get update
        sudo apt-get install -y "${MISSING_PKGS[@]}"
        ok "Installed: ${MISSING_PKGS[*]}"
    else
        warn "Skipped. Agent Manager may fail to build without: ${MISSING_PKGS[*]}"
    fi
fi

# ─── 2. NVM + Node.js ────────────────────────────────────────────────

section "2/6  NVM & Node.js 22"

load_nvm
if command -v node &>/dev/null; then
    ok "Node.js already installed: $(node --version)"
else
    info "Installing NVM..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    load_nvm
    info "Installing Node.js 22..."
    # nvm's functions aren't set -u safe (they reference unset internals like
    # $STABLE), so drop unset-variable checking just for the nvm call.
    set +u
    nvm install 22
    set -u
    ok "Node.js installed: $(node --version)"
fi

# ─── 3. GitHub CLI + auth ────────────────────────────────────────────

section "3/6  GitHub CLI & Authentication"

if ! command -v gh &>/dev/null; then
    info "Installing GitHub CLI..."
    # Refresh the index first — the base-packages step above skips apt-get update
    # when nothing was missing, so gh could otherwise install against a stale index.
    sudo apt-get update
    sudo apt-get install -y gh
fi

if gh auth status &>/dev/null; then
    ok "GitHub CLI already authenticated"
elif [[ -n "$GH_TOKEN" ]]; then
    info "Authenticating with GitHub using the provided token (non-interactive)..."
    # Hand the token to gh via a 0600 temp file so it never appears in the
    # process list. Clean it up whether login succeeds or fails.
    GH_TOKEN_FILE=$(mktemp)
    chmod 600 "$GH_TOKEN_FILE"
    printf '%s\n' "$GH_TOKEN" > "$GH_TOKEN_FILE"
    if gh auth login --with-token < "$GH_TOKEN_FILE"; then
        rm -f "$GH_TOKEN_FILE"
        ok "GitHub authenticated via token"
    else
        rm -f "$GH_TOKEN_FILE"
        err "GitHub token authentication failed."
        err "Check the token is valid and has repo + read:packages scopes."
        exit 1
    fi
else
    echo "  Agent Manager needs read access to the okthink-ai GitHub repos."
    echo "  gh will print a one-time code and a URL — open the URL, enter the code,"
    echo "  and make sure you're signed into the right GitHub account."
    echo "  (To skip this, re-run with GH_TOKEN=<your PAT> set.)"
    echo ""
    info "Authenticating with GitHub..."
    echo ""
    # BROWSER=echo prints the URL instead of trying to launch a browser.
    BROWSER=echo gh auth login -p ssh
    echo ""
fi

# Ensure read:packages scope. A PAT carries its own scopes; only OAuth logins
# can refresh, so we skip the refresh when we authenticated with a token.
if [[ -n "$GH_TOKEN" ]]; then
    info "Using the token's existing scopes (PAT must include repo + read:packages)."
else
    info "Ensuring read:packages scope..."
    if ! gh auth refresh -h github.com -s read:packages; then
        warn "Couldn't refresh scopes (expected for token-based logins) — continuing."
        warn "If npm install hits a 403 later, ensure your login has repo + read:packages."
    fi
fi

info "Setting up git credential helper..."
gh auth setup-git

# Export GITHUB_TOKEN in .bashrc for future interactive shells (npm registry auth).
if ! grep -q 'GITHUB_TOKEN' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export GITHUB_TOKEN=$(gh auth token)' >> "$HOME/.bashrc"
    ok "GITHUB_TOKEN added to .bashrc"
else
    ok "GITHUB_TOKEN already in .bashrc"
fi

info "Configuring git identity..."
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
ok "Git configured: $GIT_NAME <$GIT_EMAIL>"

# ─── 4. Claude Code ──────────────────────────────────────────────────

section "4/6  Claude Code"

if ( load_nvm; command -v claude ) &>/dev/null; then
    ok "Claude Code already installed: $( ( load_nvm; claude --version ) 2>/dev/null || echo unknown)"
else
    info "Installing Claude Code..."
    ( load_nvm; npm install -g @anthropic-ai/claude-code )
    ok "Claude Code installed"
fi

# Skip the YOLO-mode consent prompt — but never clobber existing settings.
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
    if grep -q "skipDangerousModePermissionPrompt" "$CLAUDE_SETTINGS" 2>/dev/null; then
        ok "skipDangerousModePermissionPrompt already set"
    else
        warn "~/.claude/settings.json exists but lacks skipDangerousModePermissionPrompt."
        warn "Add it manually if you want unattended YOLO-mode launches."
    fi
else
    info "Creating ~/.claude/settings.json..."
    mkdir -p "$HOME/.claude"
    cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true
}
EOF
    ok "Claude Code settings configured"
fi

echo ""
info "Claude Code needs to authenticate. In another shell on this box, run:"
echo ""
printf "  ${CYAN}claude --dangerously-skip-permissions${NC}\n"
echo ""
echo "  Follow the OAuth URL, accept the YOLO-mode prompt, then /exit."
echo ""
read -rp "  Press Enter after authenticating Claude Code (or Enter to skip)... "

# ─── Optional: other AI coding CLIs ──────────────────────────────────

section "Optional: Other AI Coding CLIs"

echo "  Agent Manager can drive other terminal coding agents too. Install any"
echo "  you have accounts or API keys for — skip the rest, you can add them later."
echo ""

read -rp "Install OpenAI Codex CLI? (y/n): " WANT_CODEX
[[ "$WANT_CODEX" =~ ^[Yy] ]] && install_npm_cli codex "@openai/codex" "Codex CLI" \
    "run 'codex' and sign in, or set OPENAI_API_KEY"

read -rp "Install Google Gemini CLI? (y/n): " WANT_GEMINI
[[ "$WANT_GEMINI" =~ ^[Yy] ]] && install_npm_cli gemini "@google/gemini-cli" "Gemini CLI" \
    "run 'gemini' and sign in with Google, or set GEMINI_API_KEY"

read -rp "Install Pi coding agent (pi.dev)? (y/n): " WANT_PI
[[ "$WANT_PI" =~ ^[Yy] ]] && install_npm_cli pi "@earendil-works/pi-coding-agent" "Pi coding agent" \
    "run 'pi' and follow the prompts, or set your provider API key"

# ─── 5. Clone & build Agent Manager ──────────────────────────────────

section "5/6  Clone & Install Agent Manager"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    ok "Agent Manager already cloned at $INSTALL_DIR"
else
    info "Cloning Agent Manager into $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
    ok "Cloned to $INSTALL_DIR"
fi

# Run npm install with retry on auth failures (403 from GitHub Packages). The
# repo's .npmrc points the @okthink-ai scope at GitHub Packages, which needs
# GITHUB_TOKEN — exported inline here because ~/.bashrc doesn't affect this shell.
npm_install_with_retry() {
    local DIR="$1" LABEL="$2" MAX_RETRIES=3 ATTEMPT=0
    while true; do
        ATTEMPT=$((ATTEMPT + 1))
        info "Installing $LABEL dependencies (attempt $ATTEMPT)..."
        if ( load_nvm; export GITHUB_TOKEN=$(gh auth token); cd "$DIR" && npm install ); then
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
        read -rp "  Fix the issue and press Enter to retry, or Ctrl+C to quit... "
        echo ""
        gh auth refresh -h github.com -s read:packages 2>/dev/null || true
    done
}

npm_install_with_retry "$INSTALL_DIR" "root"
npm_install_with_retry "$INSTALL_DIR/web" "web"

# Copy .env.example → .env if present and .env is absent.
if [[ -f "$INSTALL_DIR/.env.example" && ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    ok "Copied .env.example to .env"
fi

# Configure the bind mode in .env. The server reads .env via dotenv and binds
# 0.0.0.0 only when CM_TERMINAL_ALLOW_LAN=1; otherwise it binds loopback. We set
# it here (rather than only inline at launch) so UI-triggered restarts — which
# don't pass the env var themselves — keep the same binding.
touch "$INSTALL_DIR/.env"
if [[ "$ACCESS_MODE" == "direct" ]]; then
    # Ensure exactly one CM_TERMINAL_ALLOW_LAN=1 line.
    sed -i '/^CM_TERMINAL_ALLOW_LAN=/d' "$INSTALL_DIR/.env"
    echo 'CM_TERMINAL_ALLOW_LAN=1' >> "$INSTALL_DIR/.env"
    ok "Set CM_TERMINAL_ALLOW_LAN=1 in .env (direct-IP access, binds 0.0.0.0)"
else
    # Localhost only: strip any LAN flag so the server binds loopback.
    if grep -q '^CM_TERMINAL_ALLOW_LAN=' "$INSTALL_DIR/.env" 2>/dev/null; then
        sed -i '/^CM_TERMINAL_ALLOW_LAN=/d' "$INSTALL_DIR/.env"
        ok "Removed CM_TERMINAL_ALLOW_LAN from .env (localhost only, binds loopback)"
    else
        ok "Localhost only — server binds loopback (127.0.0.1)"
    fi
fi

# Write Firebase config for the frontend (client-side keys, not secrets). Must be
# in place BEFORE the build — Vite inlines VITE_* env at build time.
WEB_ENV="$INSTALL_DIR/web/.env"
if [[ -f "$WEB_ENV" ]]; then
    ok "web/.env already exists"
else
    info "Writing Firebase config to web/.env..."
    cat > "$WEB_ENV" <<'ENVEOF'
VITE_FIREBASE_API_KEY=AIzaSyCGCFvt5iN93rQkH6R5zStANc2ZGj_YL8E
VITE_FIREBASE_AUTH_DOMAIN=claude-manager-chat.firebaseapp.com
VITE_FIREBASE_PROJECT_ID=claude-manager-chat
VITE_FIREBASE_STORAGE_BUCKET=claude-manager-chat.firebasestorage.app
VITE_FIREBASE_MESSAGING_SENDER_ID=1041886556076
VITE_FIREBASE_APP_ID=1:1041886556076:web:22e67ff4818b56c80e9409
ENVEOF
    ok "Firebase config written to web/.env"
fi

# Build frontend for prod mode (served over plain HTTP by the single server).
info "Building frontend for production..."
( load_nvm; cd "$INSTALL_DIR/web" && npx vite build )
ok "Frontend built"

# Set server mode to prod so future restarts preserve the mode.
echo "prod" > "$INSTALL_DIR/.server-mode"
ok "Server mode set to prod"

# ─── 6. Optionally start the server ──────────────────────────────────

section "6/6  Start the Server"

read -rp "Start the server now in a tmux session? (y/n): " START_NOW
if [[ "$START_NOW" =~ ^[Yy] ]]; then
    info "Starting server in tmux session 'am-server'..."
    tmux new-session -d -s am-server -c "$INSTALL_DIR"
    # Single-quote so the pane's shell expands $HOME/$NVM_DIR and sources nvm itself.
    tmux send-keys -t am-server \
        'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '"$LAUNCH_ENV npx tsx server/index.ts" Enter
    # Poll for up to ~15s — a first `npx tsx` cold start (transpile + DB/model
    # init) can take several seconds before the port is listening.
    info "Waiting for the server to come up..."
    STARTED=false
    for _ in $(seq 1 15); do
        if port_listening "$PORT"; then STARTED=true; break; fi
        sleep 1
    done
    if [[ "$STARTED" == true ]]; then
        ok "Server is running on port $PORT"
    else
        warn "Server didn't come up within 15s — check: tmux attach -t am-server"
    fi
fi

# ─── Done ─────────────────────────────────────────────────────────────

SERVER_IP=$(hostname -I | awk '{print $1}')

section "Install Complete!"

printf "  ${GREEN}App dir:${NC}      %s\n" "$INSTALL_DIR"
printf "  ${GREEN}Access mode:${NC}  %s\n" "$ACCESS_MODE"
if [[ "$ACCESS_MODE" == "direct" ]]; then
    printf "  ${GREEN}URL:${NC}          http://%s:%s\n" "$SERVER_IP" "$PORT"
else
    printf "  ${GREEN}URL:${NC}          http://localhost:%s  (over an SSH tunnel)\n" "$PORT"
fi
echo ""

if [[ ! "$START_NOW" =~ ^[Yy] ]]; then
    echo "  Start the server (in a tmux session so it persists after disconnect):"
    echo ""
    printf "    ${CYAN}tmux new-session -d -s am-server -c %s${NC}\n" "$INSTALL_DIR"
    printf "    ${CYAN}tmux send-keys -t am-server '%s npx tsx server/index.ts' Enter${NC}\n" "$LAUNCH_ENV"
    echo ""
fi

if [[ "$ACCESS_MODE" == "direct" ]]; then
    echo "  Access Agent Manager:"
    echo ""
    printf "    ${CYAN}http://%s:%s${NC}\n" "$SERVER_IP" "$PORT"
    echo ""
    warn "hostname -I returned '$SERVER_IP' (the first address). If the box has"
    warn "multiple interfaces, substitute the IP you actually reach it on."
    echo ""
    if [[ "$SERVER_IP" != 10.* && "$SERVER_IP" != 192.168.* && "$SERVER_IP" != 172.1[6-9].* && "$SERVER_IP" != 172.2[0-9].* && "$SERVER_IP" != 172.3[0-1].* ]]; then
        warn "This looks like a PUBLIC IP. With no firewall, port $PORT is reachable"
        warn "from the internet. The terminal token gates the terminal, but consider"
        warn "restricting the port (ufw / cloud firewall) if this box faces the internet."
        echo ""
    fi
else
    echo "  The server binds to localhost only. Reach it from your laptop with an"
    echo "  SSH tunnel (run this on your laptop, leave it open):"
    echo ""
    printf "    ${CYAN}ssh -L %s:localhost:%s %s@%s${NC}\n" "$PORT" "$PORT" "$USER" "${SERVER_IP:-<server-ip>}"
    echo ""
    echo "  then open on your laptop:"
    echo ""
    printf "    ${CYAN}http://localhost:%s${NC}\n" "$PORT"
    echo ""
fi
printf "  ${YELLOW}Remember:${NC} Set an Anthropic spend cap at console.anthropic.com\n"
echo "  before running unattended agents."
echo ""
