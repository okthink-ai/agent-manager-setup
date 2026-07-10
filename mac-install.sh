#!/usr/bin/env bash
#
# mac-install.sh — Install Agent Manager on your Mac.
#
# Run this ON your Mac, as your normal user. This is the local-machine path:
# no VPS, no SSH hardening, no Tailscale, no firewall — you reach the app at
# http://localhost:4801 in your own browser.
#
# It:
#   1. Checks Homebrew and installs any missing base tools (git, tmux, gh)
#   2. Installs NVM + Node.js 22
#   3. Authenticates GitHub CLI (interactive, or GH_TOKEN)
#   4. Installs the AI coding agents you choose — Claude Code, Codex, Gemini, Pi
#   5. Clones Agent Manager into a directory you choose and builds it (prod mode)
#   6. Optionally starts the server in a tmux session
#
# Optional env vars:
#   GH_TOKEN — a GitHub PAT with repo + read:packages (skips the browser login)
#   PORT     — server port (default 4801)
#
# Designed to be idempotent — safe to re-run after a failure. It won't clobber
# an existing checkout, .env files, or your Claude Code settings.
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

REPO_URL="https://github.com/okthink-ai/claude-manager.git"
PORT="${PORT:-4801}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# The shell profile future terminals read. Macs default to zsh; respect a bash
# user if that's what they run.
if [[ "${SHELL:-}" == *zsh* ]]; then
    SHELL_PROFILE="$HOME/.zshrc"
else
    SHELL_PROFILE="$HOME/.bashrc"
fi

# Load NVM into the current shell so node/npm/npx resolve. NVM only wires itself
# into future *interactive* shells via the profile; this script's shell needs it
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

# True if something is listening on the given TCP port. lsof ships with macOS.
port_listening() {
    lsof -i ":$1" -sTCP:LISTEN &>/dev/null
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

section "Agent Manager — Mac Install"

if [[ "$(uname)" != "Darwin" ]]; then
    err "This script is for macOS. On an Ubuntu server, use ubuntu-install.sh instead."
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    err "Run this as your normal user, not root/sudo — everything installs into your home."
    exit 1
fi

# Homebrew is the one hard prerequisite: it's how we install anything missing,
# and having it implies the Xcode Command Line Tools (git, compilers) are set up.
if ! command -v brew &>/dev/null; then
    err "Homebrew is required but not found. Install it first:"
    err '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    err "then re-run this script."
    exit 1
fi
ok "Homebrew found"

# ─── Collect info upfront ─────────────────────────────────────────────

# Git identity: your Mac likely has this already — only prompt when it's absent.
if git config --global user.name &>/dev/null && git config --global user.email &>/dev/null; then
    ok "Git identity already configured: $(git config --global user.name) <$(git config --global user.email)>"
else
    read -rp "Git name (for commits, e.g. 'Jane Smith'): " GIT_NAME
    read -rp "Git email (for commits): " GIT_EMAIL
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    ok "Git configured: $GIT_NAME <$GIT_EMAIL>"
fi

DEFAULT_DIR="$HOME/claude-manager"
read -rp "Install directory for Agent Manager [$DEFAULT_DIR]: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_DIR}"
# Expand a leading ~ to $HOME (the shell won't, since it's inside a variable).
INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"

echo ""
info "Installing Agent Manager into: $INSTALL_DIR"
[[ -n "$GH_TOKEN" ]] && ok "GitHub token detected — will authenticate non-interactively"
echo ""

# ─── 1. Base tools ────────────────────────────────────────────────────

section "1/6  Base Tools"

# Everything here has a real binary, so command -v detection works. curl and
# unzip ship with macOS; the compiler toolchain comes with the Xcode CLT that
# Homebrew already requires.
BASE_TOOLS=(git tmux gh)
MISSING_TOOLS=()
for tool in "${BASE_TOOLS[@]}"; do
    command -v "$tool" &>/dev/null || MISSING_TOOLS+=("$tool")
done

if [[ ${#MISSING_TOOLS[@]} -eq 0 ]]; then
    ok "All base tools already installed — skipping"
else
    info "Missing tools: ${MISSING_TOOLS[*]}"
    read -rp "Install them now with Homebrew? (y/n): " WANT_TOOLS
    if [[ "$WANT_TOOLS" =~ ^[Yy] ]]; then
        brew install "${MISSING_TOOLS[@]}"
        ok "Installed: ${MISSING_TOOLS[*]}"
    else
        err "These are required (git to clone, gh to authenticate, tmux to run the server)."
        err "Install them and re-run: brew install ${MISSING_TOOLS[*]}"
        exit 1
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

# ─── 3. GitHub auth ──────────────────────────────────────────────────

section "3/6  GitHub Authentication"

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
    echo "  Your browser will open to approve the login — make sure you're signed"
    echo "  into the right GitHub account."
    echo ""
    info "Authenticating with GitHub..."
    echo ""
    gh auth login -p ssh
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

# Export GITHUB_TOKEN in the shell profile for future terminals (npm registry auth).
if ! grep -q 'GITHUB_TOKEN' "$SHELL_PROFILE" 2>/dev/null; then
    echo 'export GITHUB_TOKEN=$(gh auth token)' >> "$SHELL_PROFILE"
    ok "GITHUB_TOKEN added to $SHELL_PROFILE"
else
    ok "GITHUB_TOKEN already in $SHELL_PROFILE"
fi

# ─── 4. Claude Code ──────────────────────────────────────────────────

section "4/6  Claude Code"

echo "  Agent Manager can drive Claude Code, Codex, Gemini, or Pi — install any"
echo "  combination (Claude Code is the default; the others are offered next)."
echo ""

WANT_CLAUDE=y
if ( load_nvm; command -v claude ) &>/dev/null; then
    ok "Claude Code already installed: $( ( load_nvm; claude --version ) 2>/dev/null || echo unknown)"
else
    read -rp "Install Claude Code? (Y/n): " WANT_CLAUDE
    WANT_CLAUDE="${WANT_CLAUDE:-y}"
    if [[ "$WANT_CLAUDE" =~ ^[Yy] ]]; then
        info "Installing Claude Code..."
        ( load_nvm; npm install -g @anthropic-ai/claude-code )
        ok "Claude Code installed"
    else
        warn "Skipping Claude Code — pick at least one agent in the next step."
    fi
fi

if [[ "$WANT_CLAUDE" =~ ^[Yy] ]]; then
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
    info "Claude Code needs to be authenticated. If you already use Claude Code on"
    info "this Mac, you're set — just press Enter. Otherwise, in another terminal run:"
    echo ""
    printf "  ${CYAN}claude --dangerously-skip-permissions${NC}\n"
    echo ""
    echo "  Follow the OAuth URL, accept the YOLO-mode prompt, then /exit."
    echo ""
    read -rp "  Press Enter to continue... "
fi

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

# Agent Manager needs at least one agent CLI to drive. Check what's actually on
# PATH (covers pre-installed agents too), and warn — don't abort — if none is.
if ! ( load_nvm; command -v claude || command -v codex || command -v gemini || command -v pi ) &>/dev/null; then
    warn "No AI coding agent is installed. Agent Manager will run, but sessions"
    warn "won't work until you install one — re-run this script and answer yes to"
    warn "an agent (it also configures settings and walks you through auth)."
fi

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
# GITHUB_TOKEN — exported inline here because the profile doesn't affect this shell.
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

# Copy .env.example → .env if present and .env is absent. No CM_TERMINAL_ALLOW_LAN
# here: the server binds loopback by default, and localhost works either way on
# your own machine.
if [[ -f "$INSTALL_DIR/.env.example" && ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    ok "Copied .env.example to .env"
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

# Build frontend for prod mode (served by the single server on $PORT).
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
    STARTED=false
    # Re-runs: never create the session twice — a duplicate `tmux new-session`
    # fails hard and set -e would kill the script right before the summary.
    if port_listening "$PORT"; then
        ok "Server is already running on port $PORT"
        STARTED=true
    elif tmux has-session -t am-server 2>/dev/null; then
        warn "tmux session 'am-server' already exists but nothing is listening on :$PORT."
        warn "Attach to see what happened: tmux attach -t am-server"
    else
        info "Starting server in tmux session 'am-server'..."
        tmux new-session -d -s am-server -c "$INSTALL_DIR"
        # Single-quote so the pane's shell expands $HOME/$NVM_DIR and sources nvm itself.
        tmux send-keys -t am-server \
            'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '"PORT=$PORT npx tsx server/index.ts" Enter
        # Poll for up to ~15s — a first `npx tsx` cold start (transpile + DB/model
        # init) can take several seconds before the port is listening.
        info "Waiting for the server to come up..."
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
    if [[ "$STARTED" == true ]]; then
        read -rp "Open http://localhost:$PORT in your browser now? (y/n): " OPEN_NOW
        [[ "$OPEN_NOW" =~ ^[Yy] ]] && open "http://localhost:$PORT"
    fi
fi

# ─── Done ─────────────────────────────────────────────────────────────

section "Install Complete!"

printf "  ${GREEN}App dir:${NC}  %s\n" "$INSTALL_DIR"
printf "  ${GREEN}URL:${NC}      http://localhost:%s\n" "$PORT"
echo ""

if [[ ! "$START_NOW" =~ ^[Yy] ]]; then
    echo "  Start the server (in a tmux session so it survives closing the terminal):"
    echo ""
    printf "    ${CYAN}tmux new-session -d -s am-server -c %s${NC}\n" "$INSTALL_DIR"
    printf "    ${CYAN}tmux send-keys -t am-server 'PORT=%s npx tsx server/index.ts' Enter${NC}\n" "$PORT"
    echo ""
fi

echo "  Then open in your browser:"
echo ""
printf "    ${CYAN}http://localhost:%s${NC}\n" "$PORT"
echo ""
printf "  ${YELLOW}Remember:${NC} Set an Anthropic spend cap at console.anthropic.com\n"
echo "  before running unattended agents."
echo ""
