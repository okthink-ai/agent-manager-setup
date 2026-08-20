#!/usr/bin/env bash
#
# mac-install.sh — Install Agent Manager on your Mac.
#
# Run this ON your Mac, as your normal user. This is the local-machine path:
# no VPS, no SSH hardening, no firewall. You choose how to reach the app:
#
#   localhost — just this Mac's browser (http://localhost:4801)
#   tailscale — also from your other devices, over your Tailscale network
#   hosted    — from the hosted web app at https://agents.okthink.ai, in any
#               browser on your tailnet. The page is a static bundle with no
#               backend: it connects straight to the server on this Mac.
#
# It:
#   1. Checks Homebrew and installs any missing base tools (git, tmux, gh)
#   2. Installs NVM + Node.js 22
#   3. Authenticates GitHub CLI (interactive, or GH_TOKEN)
#   4. Installs the AI coding agents you choose — Claude Code, Codex, Gemini, Pi
#   5. Clones Agent Manager into a directory you choose and builds it (prod mode)
#      (in tailscale/hosted mode, also installs Tailscale and signs you in)
#   6. Optionally starts the server in a tmux session
#
# Hosted mode additionally issues a Tailscale HTTPS certificate for this Mac and
# trusts the hosted origin, which is what the hosted app requires to connect:
# it is served over HTTPS, so a browser blocks it from calling an http:// server.
#
# Flags:
#   --hosted | --tailscale | --localhost   pick the access mode non-interactively
#
# Optional env vars:
#   GH_TOKEN — a GitHub PAT with repo + read:packages (skips the browser login)
#   PORT     — server port (default 4801; hosted mode requires 4801)
#
# Designed to be idempotent — safe to re-run after a failure. It won't clobber
# an existing checkout, .env files, or your Claude Code settings, and it skips
# the dependency install and frontend build when the checkout hasn't moved since
# the last successful run (--rebuild forces them).
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

# The hosted web app, and the one port it will connect to. The hosted client
# rejects a user-entered port and always normalizes to https://<host>:4801, so
# a custom PORT can't work in that mode.
HOSTED_APP_URL="https://agents.okthink.ai"
HOSTED_REQUIRED_PORT=4801

usage() {
    cat <<'USAGEEOF'
Usage: bash mac-install.sh [--localhost | --tailscale | --hosted] [--rebuild]

  --localhost   reach the dashboard at http://localhost:4801 (default)
  --tailscale   also reach it from your other devices at http://<ts-ip>:4801
  --hosted      reach it from the hosted web app at https://agents.okthink.ai
                (installs Tailscale, issues an HTTPS certificate for this Mac,
                and trusts the hosted origin)
  --rebuild     reinstall dependencies and rebuild the frontend even if the
                checkout hasn't changed since the last run

With no flag the script asks. Env: GH_TOKEN, PORT.
USAGEEOF
}

ACCESS_MODE_FLAG=""
FORCE_REBUILD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosted)    ACCESS_MODE_FLAG="hosted" ;;
        --tailscale) ACCESS_MODE_FLAG="tailscale" ;;
        --localhost) ACCESS_MODE_FLAG="localhost" ;;
        --rebuild)   FORCE_REBUILD=true ;;
        -h|--help)   usage; exit 0 ;;
        *)           err "Unknown option: $1"; echo ""; usage; exit 1 ;;
    esac
    shift
done

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

# checkout_already_built — true when this exact commit was installed and built by
# an earlier run and both outputs are still in place. Re-runs are the norm here,
# not the exception: a stall at Tailscale sign-in or a failed certificate sends
# people straight back through this script, and npm install plus the Expo export
# cost minutes to reproduce output that hasn't changed. A dirty working tree
# falls through to a rebuild rather than trusting a stamp that only names a
# commit.
checkout_already_built() {
    if [[ "$FORCE_REBUILD" == true ]]; then return 1; fi
    [[ -f "$BUILD_STAMP" ]] || return 1
    [[ -d "$INSTALL_DIR/node_modules" && -d "$INSTALL_DIR/apps/expo/dist" ]] || return 1
    git -C "$INSTALL_DIR" diff --quiet HEAD 2>/dev/null || return 1
    local head
    head=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || return 1
    [[ "$(cat "$BUILD_STAMP" 2>/dev/null)" == "$head" ]]
}

# The scheme this checkout's server will actually serve. It picks HTTPS purely
# from certificate presence, with no reference to the access mode — so a box
# that was once in hosted mode keeps serving HTTPS after switching back, and
# printing an http:// URL for it sends people to a dead page. Both the pointer
# layout and the older flat pair count as installed.
server_scheme() {
    if [[ -e "$INSTALL_DIR/.certs/current/cert.pem" || -e "$INSTALL_DIR/.certs/cert.pem" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

# Replace any running am-server with a fresh one and wait for the port. Always a
# brand-new session: the old pane may not be an idle shell (a leftover less, or
# the dying server) and would swallow the command. Returns non-zero if the
# server doesn't come up in time.
start_server_session() {
    if tmux has-session -t am-server 2>/dev/null; then
        info "Stopping the existing 'am-server' session..."
        tmux send-keys -t am-server C-c 2>/dev/null || true
        sleep 2
        tmux kill-session -t am-server 2>/dev/null || true
        # The old process can hold the port briefly after the session dies.
        for _ in $(seq 1 10); do
            port_listening "$PORT" || break
            sleep 1
        done
    fi
    info "Starting server in tmux session 'am-server'..."
    tmux new-session -d -s am-server -c "$INSTALL_DIR"
    # Single-quote so the pane's shell expands $HOME/$NVM_DIR and sources nvm itself.
    tmux send-keys -t am-server \
        'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '"$LAUNCH_ENV npx tsx server/index.ts" Enter
    # Poll for up to ~15s — a first `npx tsx` cold start (transpile + DB/model
    # init) can take several seconds before the port is listening.
    info "Waiting for the server to come up..."
    for _ in $(seq 1 15); do
        port_listening "$PORT" && return 0
        sleep 1
    done
    return 1
}

# Locate the Tailscale CLI. Homebrew's cask and the App Store app both ship it
# inside the app bundle rather than on PATH.
TAILSCALE_APP_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
tailscale_cli() {
    if command -v tailscale &>/dev/null; then
        echo "tailscale"
    elif [[ -x "$TAILSCALE_APP_CLI" ]]; then
        echo "$TAILSCALE_APP_CLI"
    else
        return 1
    fi
}

# This Mac's MagicDNS name (e.g. my-mac.tailnet-name.ts.net), or empty. Needs
# Tailscale signed in *and* MagicDNS enabled for the tailnet. Parsed with node
# rather than grep because the status JSON has several DNSName fields — only
# Self's is this machine's. Mirrors cleanDnsName() in the app's tailscale-https.
#   tailscale_dns_name <tailscale-binary>
tailscale_dns_name() {
    "$1" status --json 2>/dev/null | ( load_nvm; node -e '
        let raw = ""
        process.stdin.on("data", (chunk) => { raw += chunk })
        process.stdin.on("end", () => {
            try {
                const self = JSON.parse(raw).Self
                const name = String((self && self.DNSName) || "").trim().replace(/\.$/, "").toLowerCase()
                if (name.endsWith(".ts.net")) process.stdout.write(name)
            } catch (error) { /* not signed in, or no MagicDNS name yet */ }
        })
    ' ) 2>/dev/null
}

# Idempotent .env edits — exactly one KEY= line, or none. The server reads .env
# on every start, so settings written here survive UI-triggered restarts, which
# don't carry the launch environment. BSD sed needs the empty -i argument.
#   set_env_var <file> <KEY> <value>   /   unset_env_var <file> <KEY>
set_env_var() {
    touch "$1"
    sed -i '' "/^$2=/d" "$1"
    printf '%s=%s\n' "$2" "$3" >> "$1"
}
unset_env_var() {
    [[ -f "$1" ]] || return 0
    sed -i '' "/^$2=/d" "$1"
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

# Every step here is a prompt. Without a terminal each one reads EOF, and `set -e`
# turns that into an exit with no message partway through the install. Say so
# instead of dying without a word.
if [[ ! -t 0 ]]; then
    err "stdin is not a terminal, so the prompts can't be answered."
    err "Download the script and run it from a terminal rather than piping curl into bash:"
    err "  curl -fsSLO https://raw.githubusercontent.com/okthink-ai/agent-manager-setup/main/mac-install.sh"
    err "  bash mac-install.sh --hosted"
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

# Records the commit the last successful install and build ran against. It lives
# under data/ because that directory is gitignored and belongs to this checkout,
# so the stamp travels and is deleted with it instead of showing up as an
# untracked file in git status.
BUILD_STAMP="$INSTALL_DIR/data/.install-build-stamp"

# How you'll reach Agent Manager. This decides how the server binds, and in
# hosted mode also whether it serves HTTPS and which browser origins it trusts:
#   localhost → loopback (127.0.0.1) only; this Mac's browser. Most private.
#   tailscale → all interfaces (0.0.0.0); reach it from your other devices at
#               http://<this-mac's-tailscale-ip>:PORT.
#   hosted    → same binding as tailscale, plus a Tailscale HTTPS certificate
#               and CM_ALLOW_HOSTED_WEB_ORIGIN=1, so the static app served from
#               agents.okthink.ai can call this server. Both are required: the
#               hosted page is HTTPS (so a plaintext server is blocked as mixed
#               content) and the server refuses that origin unless told not to.
if [[ -n "$ACCESS_MODE_FLAG" ]]; then
    ACCESS_MODE="$ACCESS_MODE_FLAG"
else
    echo ""
    echo "  How will you reach Agent Manager?"
    echo "    1) localhost — just this Mac's browser (most private)"
    echo "    2) tailscale — also from your other devices, over your Tailscale network"
    echo "    3) hosted    — from $HOSTED_APP_URL, in any browser on your tailnet"
    echo ""
    read -rp "Access mode [1=localhost / 2=tailscale / 3=hosted] (default 1): " ACCESS_CHOICE
    case "$ACCESS_CHOICE" in
        2|t*|T*) ACCESS_MODE="tailscale" ;;
        3|h*|H*) ACCESS_MODE="hosted" ;;
        *)       ACCESS_MODE="localhost" ;;
    esac
fi

# The hosted client normalizes every address to https://<host>:4801 and rejects
# an explicit port, so a server on any other port is unreachable from it. Fail
# now rather than at the end, after a multi-minute build.
if [[ "$ACCESS_MODE" == "hosted" && "$PORT" != "$HOSTED_REQUIRED_PORT" ]]; then
    err "Hosted mode requires port $HOSTED_REQUIRED_PORT, but PORT=$PORT was set."
    err "The hosted app always connects to https://<machine>.<tailnet>.ts.net:$HOSTED_REQUIRED_PORT"
    err "and rejects a custom port, so it could never reach a server on :$PORT."
    err "Re-run without PORT set, or use --tailscale for a custom port."
    exit 1
fi

# Env prefix for launching the server. Tailscale and hosted modes set
# CM_TERMINAL_ALLOW_LAN=1 (bind 0.0.0.0) — without it the server binds loopback
# and no other device can reach it; localhost mode omits it.
case "$ACCESS_MODE" in
    hosted)    LAUNCH_ENV="CM_TERMINAL_ALLOW_LAN=1 CM_ALLOW_HOSTED_WEB_ORIGIN=1 PORT=$PORT" ;;
    tailscale) LAUNCH_ENV="CM_TERMINAL_ALLOW_LAN=1 PORT=$PORT" ;;
    *)         LAUNCH_ENV="PORT=$PORT" ;;
esac

# Where your projects live — the dashboard lists projects and launch targets
# from here, and shows nothing until it's configured. Seeded into .env as
# CODE_DIRS later; the UI's Settings panel (stored in the DB) takes priority,
# so don't re-ask if a previous run already seeded it.
CODE_DIRS_INPUT=""
if ! grep -q '^CODE_DIRS=' "$INSTALL_DIR/.env" 2>/dev/null; then
    DEFAULT_CODE_DIRS="$HOME/dev"
    read -rp "Projects directory to show in Agent Manager (first-run default) [$DEFAULT_CODE_DIRS]: " CODE_DIRS_INPUT
    CODE_DIRS_INPUT="${CODE_DIRS_INPUT:-$DEFAULT_CODE_DIRS}"
    CODE_DIRS_INPUT="${CODE_DIRS_INPUT/#\~/$HOME}"
fi

echo ""
info "Installing Agent Manager into: $INSTALL_DIR"
info "Access mode: $ACCESS_MODE"
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

# A checkout from before the Expo frontend lacks apps/expo — the steps below
# would die with a bare "No such file or directory". Point at the migration script.
if [[ ! -d "$INSTALL_DIR/apps/expo" ]]; then
    err "The checkout at $INSTALL_DIR predates the Expo frontend."
    err "Update it first with:  bash migrate-to-expo.sh --dir $INSTALL_DIR"
    exit 1
fi

# Hosted mode leans on the app's own certificate tooling, which landed with the
# hosted web app. Check it here, next to the guard above and before the install
# and build, so an old checkout fails in seconds rather than after the export.
if [[ "$ACCESS_MODE" == "hosted" ]] && ! grep -q '"tailscale:https:setup"' "$INSTALL_DIR/package.json"; then
    err "The checkout at $INSTALL_DIR predates the hosted web app, so it has no"
    err "certificate tooling. Update it first with:"
    err "  bash migrate-to-expo.sh --dir $INSTALL_DIR"
    exit 1
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

# One root install covers the frontend too (npm workspaces: apps/*). Both this
# and the build below are skipped together — the stamp is only written after
# both succeed, so a matching stamp means node_modules and the export are the
# ones this commit produced. Everything between them still runs: the access
# mode, project directories, and Firebase config all have to be re-applied on
# a re-run, and none of them affect the build output.
mkdir -p "$INSTALL_DIR/data"
SKIP_BUILD=false
if checkout_already_built; then
    SKIP_BUILD=true
    ok "Dependencies and frontend are already built for this checkout — skipping both"
    info "Pass --rebuild to force them."
else
    npm_install_with_retry "$INSTALL_DIR" "root"
fi

# Copy .env.example → .env if present and .env is absent.
if [[ -f "$INSTALL_DIR/.env.example" && ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    ok "Copied .env.example to .env"
fi

# Configure the access mode in .env. The server reads .env on every start, so
# writing the flags here (rather than only inline at launch) keeps UI-triggered
# restarts — which don't carry the launch environment — on the same settings.
# Each mode clears the flags it doesn't use, so re-running with a different mode
# actually switches rather than accumulating.
touch "$INSTALL_DIR/.env"
case "$ACCESS_MODE" in
    hosted)
        set_env_var "$INSTALL_DIR/.env" CM_TERMINAL_ALLOW_LAN 1
        set_env_var "$INSTALL_DIR/.env" CM_ALLOW_HOSTED_WEB_ORIGIN 1
        ok "Set CM_TERMINAL_ALLOW_LAN=1 and CM_ALLOW_HOSTED_WEB_ORIGIN=1 in .env"
        info "The second one is the opt-in that lets $HOSTED_APP_URL call this"
        info "server. It grants any page from that origin the same API access as"
        info "your tailnet — the app reports it in Settings so it stays visible."
        ;;
    tailscale)
        set_env_var "$INSTALL_DIR/.env" CM_TERMINAL_ALLOW_LAN 1
        unset_env_var "$INSTALL_DIR/.env" CM_ALLOW_HOSTED_WEB_ORIGIN
        ok "Set CM_TERMINAL_ALLOW_LAN=1 in .env (Tailscale access, binds 0.0.0.0)"
        ;;
    *)
        # Localhost only: strip both flags so the server binds loopback and
        # trusts no remote origin.
        if grep -qE '^(CM_TERMINAL_ALLOW_LAN|CM_ALLOW_HOSTED_WEB_ORIGIN)=' "$INSTALL_DIR/.env" 2>/dev/null; then
            unset_env_var "$INSTALL_DIR/.env" CM_TERMINAL_ALLOW_LAN
            unset_env_var "$INSTALL_DIR/.env" CM_ALLOW_HOSTED_WEB_ORIGIN
            ok "Cleared remote-access flags from .env (localhost only, binds loopback)"
        else
            ok "Localhost only — server binds loopback (127.0.0.1)"
        fi
        ;;
esac

# Seed the projects directory so the dashboard isn't empty on first load. The
# UI's Settings panel writes to the DB, which takes priority over this value.
if [[ -n "$CODE_DIRS_INPUT" ]]; then
    # The answer may be a comma-separated list (same format as the Settings
    # field) — create each entry, not one path with commas in the middle.
    echo "$CODE_DIRS_INPUT" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
            mkdir -p "${dir/#\~/$HOME}"
        fi
    done
    echo "CODE_DIRS=$CODE_DIRS_INPUT" >> "$INSTALL_DIR/.env"
    ok "Projects directory seeded: $CODE_DIRS_INPUT (a value set in the app's Settings wins)"
else
    ok "CODE_DIRS already set in .env — keeping it"
fi

# Write Firebase config for the frontend (client-side keys, not secrets). Must be
# in place BEFORE the build — Expo inlines EXPO_PUBLIC_* env at export time.
# Fallback copy — canonical values live in firebase-defaults.env; keep all four scripts in sync.
EXPO_ENV="$INSTALL_DIR/apps/expo/.env"
if [[ -f "$EXPO_ENV" ]]; then
    ok "apps/expo/.env already exists"
else
    info "Writing Firebase config to apps/expo/.env..."
    cat > "$EXPO_ENV" <<'ENVEOF'
EXPO_PUBLIC_FIREBASE_API_KEY=AIzaSyCGCFvt5iN93rQkH6R5zStANc2ZGj_YL8E
EXPO_PUBLIC_FIREBASE_AUTH_DOMAIN=claude-manager-chat.firebaseapp.com
EXPO_PUBLIC_FIREBASE_PROJECT_ID=claude-manager-chat
EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET=claude-manager-chat.firebasestorage.app
EXPO_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=1041886556076
EXPO_PUBLIC_FIREBASE_APP_ID=1:1041886556076:web:22e67ff4818b56c80e9409
ENVEOF
    ok "Firebase config written to apps/expo/.env"
fi

# Build the Expo web export for prod mode (served by the single server on $PORT).
if [[ "$SKIP_BUILD" == true ]]; then
    ok "Frontend already built for this checkout — skipping the export"
else
    info "Building frontend for production (expo export — takes a few minutes)..."
    ( load_nvm; cd "$INSTALL_DIR" && npm run build )
    ok "Frontend built"
    # Written only now, so a stamp always means both steps finished. A failure
    # anywhere above leaves the old stamp (or none) and the next run redoes both.
    git -C "$INSTALL_DIR" rev-parse HEAD > "$BUILD_STAMP" 2>/dev/null || true
fi

# Set server mode to prod so future restarts preserve the mode.
echo "prod" > "$INSTALL_DIR/.server-mode"
ok "Server mode set to prod"

# ─── Optional: Tailscale access ──────────────────────────────────────

TS_IP=""
TS_DNS_NAME=""
TS_CERT_OK=false
if [[ "$ACCESS_MODE" != "localhost" ]]; then
    if [[ "$ACCESS_MODE" == "hosted" ]]; then
        section "Tailscale Access & HTTPS Certificate"
    else
        section "Tailscale Access"
    fi

    if tailscale_cli >/dev/null; then
        # Already installed — cask, App Store, or Homebrew formula all count.
        if [[ -e "/Applications/Tailscale.app" ]]; then
            ok "Tailscale already installed (Tailscale.app)"
        else
            ok "Tailscale already installed (CLI on PATH)"
        fi
    else
        info "Tailscale isn't installed."
        read -rp "Install it now with Homebrew (brew install --cask tailscale)? (y/n): " WANT_TS
        if [[ "$WANT_TS" =~ ^[Yy] ]]; then
            brew install --cask tailscale
            ok "Tailscale installed"
        else
            warn "Skipping Tailscale install — the server will still bind all interfaces,"
            warn "but the Tailscale URL won't work until you install the app and sign in."
        fi
    fi

    if TS_BIN=$(tailscale_cli); then
        # Poll until Tailscale reports an IP (i.e. it's signed in) or the user
        # skips. Sign-in lives in the menu-bar app for the cask/App Store
        # variants, but in the terminal for the Homebrew-formula daemon —
        # the app bundle's presence tells the two worlds apart.
        TS_OPENED=false
        while true; do
            TS_IP=$("$TS_BIN" ip -4 2>/dev/null | head -1) || TS_IP=""
            [[ -n "$TS_IP" ]] && break
            echo ""
            if [[ -e "/Applications/Tailscale.app" ]]; then
                # Open the app once, not per retry — re-running `open` yanks it
                # back to the foreground while the user is mid-sign-in.
                if [[ "$TS_OPENED" == false ]]; then
                    open -a Tailscale 2>/dev/null || true
                    TS_OPENED=true
                fi
                echo "  Tailscale isn't signed in yet. Sign in via the Tailscale menu-bar app,"
                echo "  with the same tailnet as the devices that will connect."
            else
                echo "  Tailscale isn't signed in yet. In another terminal, run:"
                echo ""
                printf "    ${CYAN}sudo brew services start tailscale${NC}   # if the daemon isn't running\n"
                printf "    ${CYAN}sudo tailscale up${NC}                    # sign in via the printed URL\n"
            fi
            echo ""
            read -rp "  Press Enter to re-check, or 's' to skip for now: " TS_SKIP
            [[ "$TS_SKIP" =~ ^[Ss] ]] && break
        done
        if [[ -n "$TS_IP" ]]; then
            ok "Tailscale is up — this Mac's Tailscale IP: $TS_IP"
        else
            warn "Continuing without Tailscale sign-in. Sign in later via the menu-bar"
            warn "app; this Mac's IP appears there and the URL below will start working."
        fi

        # Hosted mode needs more than an IP. The hosted page is served over
        # HTTPS, so the browser will only let it call an HTTPS server, and the
        # certificate has to match the name it dials — which is why the hosted
        # app takes a MagicDNS name and rejects an IP or a short machine name.
        # Tailscale issues a real certificate for exactly that name.
        if [[ "$ACCESS_MODE" == "hosted" && -n "$TS_IP" ]]; then
            while true; do
                TS_DNS_NAME=$(tailscale_dns_name "$TS_BIN")
                [[ -n "$TS_DNS_NAME" ]] && break
                echo ""
                warn "Tailscale reports no MagicDNS name (.ts.net) for this Mac."
                echo "  Turn on MagicDNS and HTTPS Certificates for your tailnet — both are"
                echo "  switches on this page, and you need to be a tailnet admin:"
                echo ""
                printf "    ${CYAN}https://login.tailscale.com/admin/dns${NC}\n"
                echo ""
                read -rp "  Press Enter to re-check, or 's' to skip for now: " TS_DNS_SKIP
                [[ "$TS_DNS_SKIP" =~ ^[Ss] ]] && break
            done
        fi

        if [[ -n "$TS_DNS_NAME" ]]; then
            ok "MagicDNS name: $TS_DNS_NAME"
            # The app owns certificate issuance, validation, and installation
            # into the runtime cert directory the server reads at startup —
            # don't reimplement `tailscale cert` here and guess where it lands.
            # The checkout was verified back in section 5.
            while true; do
                info "Issuing a Tailscale HTTPS certificate for $TS_DNS_NAME..."
                # CM_TAILSCALE_BIN points the app at the same CLI we found — the
                # cask keeps it inside the app bundle, off PATH.
                if ( load_nvm; export CM_TAILSCALE_BIN="$TS_BIN"; cd "$INSTALL_DIR" && npm run tailscale:https:setup ); then
                    TS_CERT_OK=true
                    ok "Certificate installed — the server serves HTTPS on port $PORT"
                    break
                fi
                echo ""
                warn "Certificate setup failed. The usual cause is HTTPS Certificates being"
                warn "off for the tailnet — a tailnet admin enables it here:"
                echo ""
                printf "    ${CYAN}https://login.tailscale.com/admin/dns${NC}\n"
                echo ""
                read -rp "  Press Enter to retry, or 's' to skip for now: " TS_CERT_SKIP
                [[ "$TS_CERT_SKIP" =~ ^[Ss] ]] && break
            done
        fi

    fi

    # Outside the CLI check on purpose: declining the Tailscale install lands
    # here too, and that is exactly the case that needs the warning.
    if [[ "$ACCESS_MODE" == "hosted" && "$TS_CERT_OK" != true ]]; then
        warn "Without a certificate this server speaks plain HTTP, and the hosted app"
        warn "will refuse it as mixed content. You can finish later from the app's"
        warn "Settings → Tailscale HTTPS, then restart the server."
    fi
fi

# ─── 6. Optionally start the server ──────────────────────────────────

section "6/6  Start the Server"

SERVER_STALE=false
read -rp "Start the server now in a tmux session? (y/n): " START_NOW
if [[ "$START_NOW" =~ ^[Yy] ]]; then
    STARTED=false
    # A server already on the port started before this run, so it predates the
    # .env settings written above and any certificate issued during it. For
    # localhost that's harmless; for the remote modes it's the whole point of
    # the run, so offer the restart rather than describing one.
    if port_listening "$PORT" && [[ "$ACCESS_MODE" == "localhost" ]]; then
        ok "Server is already running on port $PORT"
        STARTED=true
    elif port_listening "$PORT"; then
        warn "A server is already running on port $PORT. It started before this run, so"
        warn "it doesn't have the settings written above — $ACCESS_MODE access won't work"
        warn "until it restarts."
        read -rp "Restart it now? (Y/n): " WANT_RESTART
        WANT_RESTART="${WANT_RESTART:-y}"
        if [[ "$WANT_RESTART" =~ ^[Yy] ]]; then
            if start_server_session; then
                STARTED=true
                ok "Server restarted on port $PORT"
            else
                warn "Server didn't come back within 15s — check: tmux attach -t am-server"
            fi
        else
            STARTED=true
            SERVER_STALE=true
            warn "Leaving it running on the old settings."
        fi
    else
        if start_server_session; then
            STARTED=true
            ok "Server is running on port $PORT"
        else
            warn "Server didn't come up within 15s — check: tmux attach -t am-server"
        fi
    fi
    if [[ "$STARTED" == true && "$ACCESS_MODE" == "hosted" && "$TS_CERT_OK" == true ]]; then
        # Prove the whole chain before claiming success: HTTPS reachable at the
        # MagicDNS name, and the server actually reporting that it trusts the
        # hosted origin. /api/status reports the flag precisely so the person
        # connecting doesn't have to read the server's environment.
        if [[ "$SERVER_STALE" == true ]]; then
            warn "Skipping the hosted check — the server you kept running predates this setup."
        elif [[ -n "$TS_DNS_NAME" ]]; then
            info "Verifying the hosted app can reach this server..."
            HOSTED_STATUS=$(curl -fsS --max-time 10 "https://$TS_DNS_NAME:$PORT/api/status" 2>/dev/null || echo "")
            if [[ -z "$HOSTED_STATUS" ]]; then
                warn "Couldn't reach https://$TS_DNS_NAME:$PORT/api/status from this Mac."
                warn "Either the server didn't load the certificate — check how it came up with"
                warn "'tmux attach -t am-server' — or Tailscale isn't routing to this name yet."
            elif [[ "${HOSTED_STATUS// /}" == *'"hostedWebOriginTrusted":true'* ]]; then
                ok "Verified: HTTPS is live and the server trusts $HOSTED_APP_URL"
            else
                warn "The server answered but reports hostedWebOriginTrusted=false, so it will"
                warn "refuse the hosted app. Restart it and it will pick the setting up from"
                warn "$INSTALL_DIR/.env:  tmux kill-session -t am-server"
            fi
        fi
        read -rp "Open $HOSTED_APP_URL in your browser now? (y/n): " OPEN_NOW
        [[ "$OPEN_NOW" =~ ^[Yy] ]] && open "$HOSTED_APP_URL"
    elif [[ "$STARTED" == true ]]; then
        # Scheme comes from the certificate, not the mode — a box that was once
        # hosted still serves HTTPS here.
        LOCAL_URL="$(server_scheme)://localhost:$PORT"
        read -rp "Open $LOCAL_URL in your browser now? (y/n): " OPEN_NOW
        [[ "$OPEN_NOW" =~ ^[Yy] ]] && open "$LOCAL_URL"
    fi
fi

# ─── Done ─────────────────────────────────────────────────────────────

section "Install Complete!"

# The server picks HTTPS from certificate presence alone, so the scheme has to
# be read off the box rather than inferred from the access mode.
SCHEME="$(server_scheme)"

# Hosted access needs the certificate as much as it needs the flags. Without one
# the setup is unfinished, and saying otherwise here is worse than saying nothing
# — this is the last thing on screen, and it outlives the warnings above it.
HOSTED_READY=false
if [[ "$ACCESS_MODE" == "hosted" && "$TS_CERT_OK" == true ]]; then
    HOSTED_READY=true
fi

printf "  ${GREEN}App dir:${NC}  %s\n" "$INSTALL_DIR"
if [[ "$HOSTED_READY" == true ]]; then
    printf "  ${GREEN}Open:${NC}     %s  (any browser on your tailnet)\n" "$HOSTED_APP_URL"
    printf "  ${GREEN}Connect to:${NC} %s\n" "$TS_DNS_NAME"
    # Only the MagicDNS name matches the certificate, so that is the local URL too.
    printf "  ${GREEN}Local:${NC}    https://%s:%s\n" "$TS_DNS_NAME" "$PORT"
elif [[ "$ACCESS_MODE" == "hosted" ]]; then
    printf "  ${YELLOW}Status:${NC}   unfinished — no HTTPS certificate on this Mac\n"
    printf "  ${GREEN}Local:${NC}    %s://localhost:%s\n" "$SCHEME" "$PORT"
elif [[ "$ACCESS_MODE" == "tailscale" ]]; then
    printf "  ${GREEN}URL:${NC}      %s://%s:%s  (any device on your tailnet)\n" "$SCHEME" "${TS_IP:-<tailscale-ip>}" "$PORT"
    printf "  ${GREEN}Local:${NC}    %s://localhost:%s\n" "$SCHEME" "$PORT"
else
    printf "  ${GREEN}URL:${NC}      %s://localhost:%s\n" "$SCHEME" "$PORT"
fi
echo ""

if [[ ! "$START_NOW" =~ ^[Yy] ]]; then
    echo "  Start the server (in a tmux session so it survives closing the terminal):"
    echo ""
    printf "    ${CYAN}tmux new-session -d -s am-server -c %s${NC}\n" "$INSTALL_DIR"
    printf "    ${CYAN}tmux send-keys -t am-server '%s npx tsx server/index.ts' Enter${NC}\n" "$LAUNCH_ENV"
    echo ""
fi

if [[ "$HOSTED_READY" == true ]]; then
    echo "  Then, from any device signed into your tailnet, open:"
    echo ""
    printf "    ${CYAN}%s${NC}\n" "$HOSTED_APP_URL"
    echo ""
    echo "  and enter this address when it asks which server to connect to:"
    echo ""
    printf "    ${CYAN}%s${NC}\n" "$TS_DNS_NAME"
    echo ""
    echo "  Enter the name on its own — no https://, no port. The app adds both."
    echo ""
    printf "  ${YELLOW}First connection:${NC} your browser will ask whether the page may reach\n"
    echo "  devices on your local network. Allow it — that prompt is the hosted page"
    echo "  asking to talk to this Mac, which is the only way it works. Blocking it"
    echo "  fails the connection with an error that won't mention the permission."
    echo ""
    printf "  ${YELLOW}Certificate:${NC} Tailscale certificates don't renew themselves. Renew from\n"
    echo "  the app's Settings → Tailscale HTTPS (it warns before expiry) and restart"
    echo "  Agent Manager afterwards."
    echo ""
    printf "  ${YELLOW}Note:${NC} Hosted mode binds all interfaces, so this Mac's local network\n"
    echo "  (e.g. home Wi-Fi) can reach the port too — not just the tailnet. It also"
    echo "  trusts every page served from $HOSTED_APP_URL. Turn it off by deleting"
    echo "  CM_ALLOW_HOSTED_WEB_ORIGIN from $INSTALL_DIR/.env and restarting."
elif [[ "$ACCESS_MODE" == "hosted" ]]; then
    echo "  Hosted access isn't finished. This Mac has no Tailscale HTTPS certificate,"
    echo "  and the hosted app is served over HTTPS, so a browser won't let it call a"
    echo "  plaintext server. Don't bother trying $HOSTED_APP_URL until this is done."
    echo ""
    echo "  To finish:"
    echo ""
    echo "    1. Turn on MagicDNS and HTTPS Certificates for your tailnet (admin only):"
    printf "         ${CYAN}https://login.tailscale.com/admin/dns${NC}\n"
    echo "    2. Make sure Tailscale is signed in on this Mac."
    echo "    3. Re-run this script, or use Settings → Tailscale HTTPS in the app and"
    echo "       restart Agent Manager afterwards."
    echo ""
    printf "  Meanwhile the dashboard works here: ${CYAN}%s://localhost:%s${NC}\n" "$SCHEME" "$PORT"
else
    echo "  Then open in your browser:"
    echo ""
    if [[ "$ACCESS_MODE" == "tailscale" ]]; then
        printf "    ${CYAN}%s://%s:%s${NC}  (from any device on your tailnet)\n" "$SCHEME" "${TS_IP:-<tailscale-ip>}" "$PORT"
        echo ""
        printf "  ${YELLOW}Note:${NC} Tailscale mode binds all interfaces, so the dashboard is also\n"
        echo "  reachable from this Mac's local network (e.g. home Wi-Fi) — not just the"
        echo "  tailnet. Fine on a network you trust; worth knowing on one you don't."
    else
        printf "    ${CYAN}%s://localhost:%s${NC}\n" "$SCHEME" "$PORT"
    fi
    if [[ "$SCHEME" == "https" ]]; then
        echo ""
        printf "  ${YELLOW}Note:${NC} a Tailscale HTTPS certificate from an earlier hosted setup is\n"
        echo "  still installed, so the server serves HTTPS rather than plain HTTP — hence"
        echo "  the scheme above. Only this Mac's MagicDNS name matches that certificate,"
        echo "  so other addresses will warn. Delete $INSTALL_DIR/.certs and restart the"
        echo "  server to go back to HTTP."
    fi
fi
echo ""
printf "  ${YELLOW}Remember:${NC} Set an Anthropic spend cap at console.anthropic.com\n"
echo "  before running unattended agents."
echo ""
