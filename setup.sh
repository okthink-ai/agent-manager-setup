#!/usr/bin/env bash
#
# setup.sh — Run on a fresh Ubuntu 24.04 VPS (as root) to set up Agent Manager.
#
# This script:
#   1. Creates a non-root user and hardens SSH
#   2. Installs fail2ban
#   3. Installs system packages, NVM, Node.js 22
#   4. Installs Tailscale (interactive, or TS_AUTHKEY for non-interactive)
#   5. Installs GitHub CLI and authenticates (interactive, or GH_TOKEN)
#   6. Installs the AI coding agents you choose — Claude Code, Codex, Gemini, Pi
#   7. Clones Agent Manager and installs dependencies — all as the non-root user
#   8. Prints a summary with access URLs
#
# After SSH hardening, the script switches to the new non-root user for all
# application work (auth, checkout, build, server). Only apt and `tailscale up`
# still use root.
#
# Optional env vars for unattended runs:
#   TS_AUTHKEY  — Tailscale auth key (skips the browser login)
#   TS_TAGS     — Tailscale tags for this node (e.g. tag:demo). The tag must be
#                 declared under tagOwners in your tailnet ACL first, or
#                 tailscale up refuses it. Used for demo boxes so guest access
#                 can be scoped by ACL to the dashboard port only.
#   GH_TOKEN    — GitHub PAT with repo + read:packages (skips the browser login)
#   SSH_ALIAS   — the Host alias provisioning wrote to your laptop's SSH config
#                 (default agent-manager-vps; demo boxes use agent-manager-demo).
#                 Only affects the printed summary.
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

# ─── Pre-flight checks ───────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    err "If root SSH is disabled, connect as your user and run: sudo bash setup.sh"
    exit 1
fi

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu 24.04. Proceed with caution on other distros."
fi

# ─── Collect info upfront ─────────────────────────────────────────────

section "Setup Configuration"

read -rp "Username for the new non-root user: " NEW_USER

if [[ -z "$NEW_USER" ]]; then
    err "Username cannot be empty."
    exit 1
fi

read -rp "Git name (for commits, e.g. 'Jane Smith'): " GIT_NAME
read -rp "Git email (for commits): " GIT_EMAIL

REPO_URL="https://github.com/okthink-ai/claude-manager.git"

# Optional non-interactive auth. Export these before running to skip the
# browser/device flows (e.g. for unattended setup):
#   TS_AUTHKEY     — a Tailscale auth key (tskey-…) for `tailscale up --authkey`
#   GH_TOKEN       — a GitHub PAT with repo + read:packages scopes
# When unset, the script falls back to the interactive login for that service.
TS_AUTHKEY="${TS_AUTHKEY:-${TAILSCALE_AUTHKEY:-}}"
TS_TAGS="${TS_TAGS:-}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

# SSH alias the completion summary tells you to edit/use on your laptop.
# provision.sh writes agent-manager-vps for production, agent-manager-demo
# for --demo boxes.
SSH_ALIAS="${SSH_ALIAS:-agent-manager-vps}"

# Extra args for tailscale up. --advertise-tags requires the tag to be declared
# in the tailnet ACL's tagOwners — see the README's Demo Box section.
TS_UP_ARGS=()
[[ -n "$TS_TAGS" ]] && TS_UP_ARGS+=("--advertise-tags=$TS_TAGS")

echo ""
info "Will create user '$NEW_USER' and install everything under /home/$NEW_USER"
[[ -n "$TS_AUTHKEY" ]] && ok "Tailscale auth key detected — will connect non-interactively"
[[ -n "$GH_TOKEN" ]]   && ok "GitHub token detected — will authenticate non-interactively"
echo ""

# ─── 1. System update + packages ─────────────────────────────────────

section "1/8  System Update & Packages"

info "Updating apt and installing base packages..."
apt update && apt upgrade -y
apt install -y build-essential curl wget git unzip tmux htop lsof unattended-upgrades

# Enable unattended-upgrades non-interactively
if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    info "Enabling unattended-upgrades..."
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    ok "Unattended-upgrades enabled"
else
    ok "Unattended-upgrades already configured"
fi

ok "System packages installed"

# ─── 2. Create non-root user ─────────────────────────────────────────

section "2/8  Create User & Harden SSH"

if id "$NEW_USER" &>/dev/null; then
    ok "User '$NEW_USER' already exists"
else
    info "Creating user '$NEW_USER'..."
    echo ""
    echo "  Set a password for the '$NEW_USER' account on this server."
    echo "  This is used for sudo commands — SSH uses your key, not this password."
    echo ""
    adduser "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    ok "User '$NEW_USER' created with sudo access"
fi

# Copy SSH keys from root
if [[ -f /root/.ssh/authorized_keys ]]; then
    mkdir -p "/home/$NEW_USER/.ssh"
    cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 700 "/home/$NEW_USER/.ssh"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    ok "SSH keys copied to $NEW_USER"
else
    warn "No SSH keys found in /root/.ssh/authorized_keys — you'll need to add them manually."
fi

# SSH hardening — pause for safety
echo ""
printf "${YELLOW}${BOLD}  !! IMPORTANT — TEST BEFORE CONTINUING !!${NC}\n"
echo ""
echo "  Open a SECOND terminal on your laptop and verify you can SSH"
echo "  in as the new user:"
echo ""
printf "    ${CYAN}ssh -i ~/.ssh/agent_manager %s@%s${NC}\n" "$NEW_USER" "$(hostname -I | awk '{print $1}')"
echo ""
echo "  If that works, press Enter to continue."
echo "  If it doesn't, fix it now — after this step, root SSH is disabled."
echo ""
read -rp "  Press Enter when you've confirmed SSH works for ${NEW_USER}... "

# Write SSH hardening drop-in
info "Hardening SSH (disabling root login + password auth)..."
tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
EOF
systemctl restart ssh
ok "SSH hardened — root login disabled."
info "If you need to re-run this script, SSH as $NEW_USER and use: sudo bash setup.sh"

# ─── 3. Fail2ban ─────────────────────────────────────────────────────

section "3/8  Fail2ban"

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "Fail2ban is already running"
else
    apt install -y fail2ban

    tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled  = true
port     = ssh
logpath  = /var/log/auth.log
maxretry = 3
EOF

    systemctl enable --now fail2ban
    ok "Fail2ban installed and running"
fi

fail2ban-client status sshd 2>/dev/null || true

# ─── Switchover: drop into the non-root user for the rest of setup ────
# Everything from here — language runtimes, GitHub/AI auth, the Agent Manager
# checkout, the build, and the server process — runs as "$NEW_USER", never as
# root. We do it with `su - $NEW_USER -c "..."` so each command runs in the
# user's own login shell and writes to their home. The only things that still
# use root are system-level package installs (apt) and `tailscale up`, which
# require it; those are called out where they happen.

run_as_user() {
    su - "$NEW_USER" -c "$1"
}

# Install an optional global npm CLI as the new user (idempotent). A failed
# install warns and continues rather than aborting the whole setup.
#   install_npm_cli <binary> <npm-package> <label> [auth-hint]
install_npm_cli() {
    local bin="$1" pkg="$2" label="$3" auth="${4:-}"
    local nvm='export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" &&'
    if run_as_user "$nvm command -v $bin" &>/dev/null; then
        ok "$label already installed"
    elif run_as_user "$nvm npm install -g $pkg"; then
        ok "$label installed"
    else
        warn "$label install failed — skipping. Install later with: npm install -g $pkg"
        return 0
    fi
    [[ -n "$auth" ]] && echo "    auth: $auth"
    return 0
}

# ─── Switchover announcement ─────────────────────────────────────────

section "Switching to user '$NEW_USER'"
echo "  Root-level system setup is done. Everything below — Node, GitHub/AI"
echo "  auth, the Agent Manager checkout, the build, and the running server —"
echo "  now happens as '$NEW_USER', not root. (apt installs and 'tailscale up'"
echo "  still use root where the OS requires it.)"

# ─── 4. NVM + Node.js ────────────────────────────────────────────────

section "4/8  NVM & Node.js 22"

if run_as_user "command -v node" &>/dev/null; then
    NODE_VERSION=$(run_as_user "node --version")
    ok "Node.js already installed: $NODE_VERSION"
else
    info "Installing NVM..."
    run_as_user 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'

    info "Installing Node.js 22..."
    run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install 22'

    NODE_VERSION=$(run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && node --version')
    ok "Node.js installed: $NODE_VERSION"
fi

# ─── 5. Tailscale ────────────────────────────────────────────────────

section "5/8  Tailscale"

if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
    TAILSCALE_IP=$(tailscale ip -4)
    ok "Tailscale already connected: $TAILSCALE_IP"
    # A re-run skips `tailscale up`, which would silently drop the requested
    # tags — and the demo ACL grants guest access by tag. Re-advertise if the
    # node doesn't already carry them. If the tag isn't declared under
    # tagOwners in the tailnet ACL, tailscale up fails loudly here — that's
    # the right outcome (fix the ACL, then re-run).
    if [[ -n "$TS_TAGS" ]] && ! tailscale status --json | grep -q "\"$TS_TAGS\""; then
        info "Node is missing requested tags ($TS_TAGS) — re-advertising on the existing connection..."
        tailscale up --advertise-tags="$TS_TAGS"
        ok "Tags applied: $TS_TAGS"
    fi
else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    if [[ -n "$TS_AUTHKEY" ]]; then
        info "Connecting Tailscale with the provided auth key (non-interactive)..."
        # Hand the key to tailscale via a file (the `file:` prefix) so it never
        # shows up in the process list. tailscale up runs as root, so the file
        # stays root-only at 0600. Clean it up whether the connect succeeds or not.
        TS_KEY_FILE=$(mktemp)
        chmod 600 "$TS_KEY_FILE"
        printf '%s' "$TS_AUTHKEY" > "$TS_KEY_FILE"
        if tailscale up --auth-key="file:$TS_KEY_FILE" ${TS_UP_ARGS[@]+"${TS_UP_ARGS[@]}"}; then
            rm -f "$TS_KEY_FILE"
        else
            rm -f "$TS_KEY_FILE"
            err "Tailscale rejected the auth key. Check it's valid and not expired or already consumed."
            exit 1
        fi
    else
        info "Starting Tailscale — follow the auth URL below:"
        echo ""
        tailscale up ${TS_UP_ARGS[@]+"${TS_UP_ARGS[@]}"}
        echo ""
    fi

    TAILSCALE_IP=$(tailscale ip -4)
    ok "Tailscale connected: $TAILSCALE_IP"
fi

# ─── 6. GitHub CLI + auth ────────────────────────────────────────────

section "6/8  GitHub CLI & Authentication"

if ! command -v gh &>/dev/null; then
    info "Installing GitHub CLI..."
    apt install -y gh
fi

# Check if already authenticated
if run_as_user "gh auth status" &>/dev/null; then
    ok "GitHub CLI already authenticated"
elif [[ -n "$GH_TOKEN" ]]; then
    info "Authenticating with GitHub using the provided token (non-interactive)..."
    # Hand the token to gh via a user-owned temp file so it never appears in a
    # command line / process list (ps), only on disk briefly with 0600 perms.
    GH_TOKEN_FILE=$(mktemp)
    chmod 600 "$GH_TOKEN_FILE"
    printf '%s\n' "$GH_TOKEN" > "$GH_TOKEN_FILE"
    chown "$NEW_USER:$NEW_USER" "$GH_TOKEN_FILE"
    # Remove the token file whether the login succeeds or fails — testing the
    # result inside `if` keeps set -e from aborting before we can clean up.
    if run_as_user "gh auth login --with-token < $GH_TOKEN_FILE"; then
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
    echo "  You can use your main GitHub account, or a secondary account"
    echo "  if you prefer to limit access on this server."
    echo ""
    echo "  This is a headless server with no browser. gh will print a one-time"
    echo "  code and a URL — open the URL ON YOUR LAPTOP, enter the code, and make"
    echo "  sure you're signed into the right GitHub account before approving."
    echo "  (To skip this step entirely, re-run with GH_TOKEN=<your PAT> set.)"
    echo ""
    info "Authenticating with GitHub..."
    echo ""
    # No GUI browser here, so xdg-open just errors out. Point gh's browser at
    # `echo` instead — it prints the auth URL for you to open on your laptop.
    run_as_user "BROWSER=echo gh auth login -p ssh"
    echo ""
fi

# Ensure read:packages scope. OAuth logins can refresh to add it; a PAT carries
# its own scopes, so we only refresh when we didn't authenticate with a token.
if [[ -n "$GH_TOKEN" ]]; then
    info "Using the token's existing scopes (PAT must include repo + read:packages)."
else
    # `gh auth refresh` only works for web/OAuth logins. If this box was
    # previously authenticated with a token (and GH_TOKEN just isn't exported
    # this run), the refresh errors out — don't let that abort the whole script.
    # The PAT already carries its own scopes, so warn and continue instead.
    info "Ensuring read:packages scope..."
    if ! run_as_user "gh auth refresh -h github.com -s read:packages"; then
        warn "Couldn't refresh scopes (expected for token-based logins) — continuing."
        warn "If npm install hits a 403 later, make sure your login has repo + read:packages."
    fi
fi

# Wire gh as git credential helper (needed for HTTPS git-URL deps in package.json)
info "Setting up git credential helper..."
run_as_user "gh auth setup-git"

# Export GITHUB_TOKEN in .bashrc (needed for npm registry auth via .npmrc)
if ! run_as_user "grep -q 'GITHUB_TOKEN' ~/.bashrc" 2>/dev/null; then
    run_as_user 'echo '\''export GITHUB_TOKEN=$(gh auth token)'\'' >> ~/.bashrc'
    ok "GITHUB_TOKEN added to .bashrc"
else
    ok "GITHUB_TOKEN already in .bashrc"
fi

# Git identity — write to a temp script to avoid shell-quoting issues
# (names with apostrophes like O'Brien break when interpolated through su -c)
info "Configuring git identity..."
GIT_SCRIPT=$(mktemp)
cat > "$GIT_SCRIPT" <<GITEOF
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"
GITEOF
chmod +x "$GIT_SCRIPT"
chown "$NEW_USER:$NEW_USER" "$GIT_SCRIPT"
run_as_user "bash $GIT_SCRIPT"
rm -f "$GIT_SCRIPT"
ok "Git configured: $GIT_NAME <$GIT_EMAIL>"

# ─── 7. Claude Code (optional, recommended) ──────────────────────────

section "7/8  Claude Code"

echo "  Agent Manager can drive Claude Code, Codex, Gemini, or Pi — install any"
echo "  combination (Claude Code is the default; the others are offered next)."
echo ""

WANT_CLAUDE=y
if run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && command -v claude' &>/dev/null; then
    CLAUDE_VERSION=$(run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && claude --version' 2>/dev/null || echo "unknown")
    ok "Claude Code already installed: $CLAUDE_VERSION"
else
    read -rp "Install Claude Code? (Y/n): " WANT_CLAUDE
    WANT_CLAUDE="${WANT_CLAUDE:-y}"
    if [[ "$WANT_CLAUDE" =~ ^[Yy] ]]; then
        info "Installing Claude Code..."
        run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm install -g @anthropic-ai/claude-code'
        ok "Claude Code installed"
    else
        warn "Skipping Claude Code — pick at least one agent in the next step."
    fi
fi

if [[ "$WANT_CLAUDE" =~ ^[Yy] ]]; then
    # Skip the YOLO-mode consent prompt
    CLAUDE_SETTINGS="/home/$NEW_USER/.claude/settings.json"
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        # Check if setting already exists
        if grep -q "skipDangerousModePermissionPrompt" "$CLAUDE_SETTINGS" 2>/dev/null; then
            ok "skipDangerousModePermissionPrompt already set"
        else
            warn "~/.claude/settings.json exists but doesn't have skipDangerousModePermissionPrompt."
            warn "Add it manually if you want unattended YOLO-mode launches."
        fi
    else
        info "Creating ~/.claude/settings.json..."
        mkdir -p "/home/$NEW_USER/.claude"
        cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true
}
EOF
        chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.claude"
        chmod 700 "/home/$NEW_USER/.claude"
        ok "Claude Code settings configured"
    fi

    echo ""
    info "Claude Code needs to authenticate. In a separate terminal on your laptop:"
    echo ""
    printf "  ${CYAN}ssh -i ~/.ssh/agent_manager %s@%s${NC}\n" "$NEW_USER" "$(hostname -I | awk '{print $1}')"
    printf "  ${CYAN}claude --dangerously-skip-permissions${NC}\n"
    echo ""
    echo "  Using --dangerously-skip-permissions lets Claude Code run without"
    echo "  permission prompts, which is how Agent Manager launches sessions."
    echo "  Follow the OAuth URL, accept the YOLO-mode prompt, then /exit."
    echo ""
    read -rp "  Press Enter after authenticating Claude Code (or Enter to skip)... "
fi

# ─── Optional: other AI coding CLIs ──────────────────────────────────

section "Optional: Other AI Coding CLIs"

echo "  Agent Manager can drive other terminal coding agents too. Install any"
echo "  you have accounts or API keys for — skip the rest, you can add them later."
echo "  Each still needs its own auth (shown after install)."
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
# the user's PATH (covers pre-installed agents too), and warn — don't abort — if
# none is.
if ! run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && { command -v claude || command -v codex || command -v gemini || command -v pi; }' &>/dev/null; then
    warn "No AI coding agent is installed. Agent Manager will run, but sessions"
    warn "won't work until you install one — re-run this script and answer yes to"
    warn "an agent (it also configures settings and walks you through auth)."
fi

# ─── 8. Clone Agent Manager ──────────────────────────────────────────

section "8/8  Clone & Install Agent Manager"

INSTALL_DIR="/home/$NEW_USER/dev/claude-manager"

if [[ -d "$INSTALL_DIR" ]]; then
    ok "Agent Manager already cloned at $INSTALL_DIR"
else
    info "Cloning Agent Manager..."
    run_as_user "mkdir -p ~/dev"
    run_as_user "cd ~/dev && git clone $REPO_URL"
    ok "Cloned to $INSTALL_DIR"
fi

# A checkout from before the Expo frontend lacks apps/expo — the steps below
# would die with a bare "No such file or directory". Point at the migration script.
if [[ ! -d "$INSTALL_DIR/apps/expo" ]]; then
    err "The checkout at $INSTALL_DIR predates the Expo frontend."
    err "Update it first with:  bash migrate-to-expo.sh --dir $INSTALL_DIR"
    exit 1
fi

# Helper: run npm install with retry on auth failures (403 from GitHub Packages)
npm_install_with_retry() {
    local DIR="$1"
    local LABEL="$2"
    local MAX_RETRIES=3
    local ATTEMPT=0

    while true; do
        ATTEMPT=$((ATTEMPT + 1))
        info "Installing $LABEL dependencies (attempt $ATTEMPT)..."

        if run_as_user "export NVM_DIR=\"\$HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && export GITHUB_TOKEN=\$(gh auth token) && cd $DIR && npm install" 2>&1; then
            ok "$LABEL dependencies installed"
            return 0
        fi

        if [[ $ATTEMPT -ge $MAX_RETRIES ]]; then
            err "$LABEL install failed after $MAX_RETRIES attempts."
            err "Check your GitHub token has read:packages scope and your account has access to the okthink-ai org."
            exit 1
        fi

        echo ""
        warn "Install failed — this is usually a GitHub Packages auth issue (403)."
        echo ""
        echo "  Possible fixes:"
        echo "    1. Refresh your GitHub token:  gh auth refresh -h github.com -s read:packages"
        echo "    2. Re-authenticate:            gh auth login -p ssh"
        echo "    3. Verify org access:          Make sure your GitHub account can access okthink-ai repos"
        echo ""
        read -rp "  Fix the issue and press Enter to retry, or Ctrl+C to quit... "
        echo ""

        # Re-run the auth refresh in case the user fixed it
        run_as_user "gh auth refresh -h github.com -s read:packages" 2>/dev/null || true
    done
}

# One root install covers the frontend too (npm workspaces: apps/*).
npm_install_with_retry "~/dev/claude-manager" "root"

# Copy .env.example if it exists
if [[ -f "$INSTALL_DIR/.env.example" ]] && [[ ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    chown "$NEW_USER:$NEW_USER" "$INSTALL_DIR/.env"
    ok "Copied .env.example to .env"
fi

# This box is reached at http://<tailscale-ip>:4801, but the server binds
# loopback unless CM_TERMINAL_ALLOW_LAN=1. Persist the flag in .env (the server
# loads it via dotenv) so UI-triggered restarts keep the binding too.
touch "$INSTALL_DIR/.env"
chown "$NEW_USER:$NEW_USER" "$INSTALL_DIR/.env"
if grep -q '^CM_TERMINAL_ALLOW_LAN=1' "$INSTALL_DIR/.env" 2>/dev/null; then
    ok "CM_TERMINAL_ALLOW_LAN already set in .env"
else
    sed -i '/^CM_TERMINAL_ALLOW_LAN=/d' "$INSTALL_DIR/.env"
    echo 'CM_TERMINAL_ALLOW_LAN=1' >> "$INSTALL_DIR/.env"
    ok "Set CM_TERMINAL_ALLOW_LAN=1 in .env (server binds 0.0.0.0 for Tailscale access)"
fi

# Seed the projects directory so the dashboard isn't empty on first load. The
# UI's Settings panel writes to the DB, which takes priority over this value —
# so don't re-ask if a previous run already seeded it. A leading ~ means the
# app user's home, not root's.
if grep -q '^CODE_DIRS=' "$INSTALL_DIR/.env" 2>/dev/null; then
    ok "CODE_DIRS already set in .env — keeping it"
else
    DEFAULT_CODE_DIRS="/home/$NEW_USER/dev"
    read -rp "Projects directory to show in Agent Manager [$DEFAULT_CODE_DIRS]: " CODE_DIRS_INPUT
    CODE_DIRS_INPUT="${CODE_DIRS_INPUT:-$DEFAULT_CODE_DIRS}"
    CODE_DIRS_INPUT="${CODE_DIRS_INPUT/#\~//home/$NEW_USER}"
    # The answer may be a comma-separated list (same format as the Settings
    # field) — create each entry, not one path with commas in the middle.
    echo "$CODE_DIRS_INPUT" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
            run_as_user "mkdir -p '${dir/#\~//home/$NEW_USER}'"
        fi
    done
    echo "CODE_DIRS=$CODE_DIRS_INPUT" >> "$INSTALL_DIR/.env"
    ok "Projects directory set: $CODE_DIRS_INPUT (change anytime in Settings)"
fi

# Write Firebase config for the frontend (client-side keys, not secrets). Must
# be in place BEFORE the build — Expo inlines EXPO_PUBLIC_* env at export time.
# Fallback copy — canonical values live in firebase-defaults.env; keep all four scripts in sync.
EXPO_ENV="$INSTALL_DIR/apps/expo/.env"
if [[ -f "$EXPO_ENV" ]]; then
    ok "apps/expo/.env already exists"
else
    info "Writing Firebase config to apps/expo/.env..."
    run_as_user 'cat > ~/dev/claude-manager/apps/expo/.env <<ENVEOF
EXPO_PUBLIC_FIREBASE_API_KEY=AIzaSyCGCFvt5iN93rQkH6R5zStANc2ZGj_YL8E
EXPO_PUBLIC_FIREBASE_AUTH_DOMAIN=claude-manager-chat.firebaseapp.com
EXPO_PUBLIC_FIREBASE_PROJECT_ID=claude-manager-chat
EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET=claude-manager-chat.firebasestorage.app
EXPO_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=1041886556076
EXPO_PUBLIC_FIREBASE_APP_ID=1:1041886556076:web:22e67ff4818b56c80e9409
ENVEOF'
    ok "Firebase config written to apps/expo/.env"
fi

# Build the Expo web export for prod mode (served by the single server over
# plain HTTP — no cert warnings over Tailscale).
info "Building frontend for production (expo export — takes a few minutes)..."
run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && cd ~/dev/claude-manager && npm run build'
ok "Frontend built"

# Set server mode to prod so future restarts preserve the mode
echo "prod" > "$INSTALL_DIR/.server-mode"
chown "$NEW_USER:$NEW_USER" "$INSTALL_DIR/.server-mode"
ok "Server mode set to prod"

# ─── Optional: Start the server now ──────────────────────────────────

echo ""
read -rp "Start the server now in a tmux session? (y/n): " START_NOW
if [[ "$START_NOW" =~ ^[Yy] ]]; then
    info "Starting server in tmux session 'am-server'..."
    run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && tmux new-session -d -s am-server -c ~/dev/claude-manager && tmux send-keys -t am-server "PORT=4801 npx tsx server/index.ts" Enter'
    sleep 3
    if run_as_user 'lsof -i :4801 -sTCP:LISTEN' &>/dev/null; then
        ok "Server is running on port 4801"
    else
        warn "Server may not have started — check: tmux attach -t am-server"
    fi
fi

# ─── Done ─────────────────────────────────────────────────────────────

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "<tailscale-ip>")

section "Setup Complete!"

printf "  ${GREEN}User:${NC}        %s\n" "$NEW_USER"
printf "  ${GREEN}Tailscale:${NC}   %s\n" "$TAILSCALE_IP"
printf "  ${GREEN}App dir:${NC}     %s\n" "$INSTALL_DIR"
echo ""
STEP=1

echo "  Next steps:"
echo ""
printf "  ${STEP}. Update your laptop's SSH config to use '%s' instead of root:\n" "$NEW_USER"
echo ""
printf "     ${CYAN}Host %s\n" "$SSH_ALIAS"
printf "         User %s${NC}\n" "$NEW_USER"
STEP=$((STEP + 1))

if [[ "$START_NOW" =~ ^[Yy] ]]; then
    echo ""
    printf "  ${STEP}. Agent Manager is running. Access it at:\n"
    echo ""
    printf "     ${CYAN}http://%s:4801${NC}\n" "$TAILSCALE_IP"
    STEP=$((STEP + 1))
else
    echo ""
    printf "  ${STEP}. SSH in as %s and start the server:\n" "$NEW_USER"
    echo ""
    printf "     ${CYAN}ssh %s${NC}\n" "$SSH_ALIAS"
    printf "     ${CYAN}cd ~/dev/claude-manager${NC}\n"
    printf "     ${CYAN}PORT=4801 npx tsx server/index.ts${NC}\n"
    echo ""
    echo "     Or in a tmux session so it persists after disconnect:"
    echo ""
    printf "     ${CYAN}tmux new-session -d -s am-server -c ~/dev/claude-manager${NC}\n"
    printf "     ${CYAN}tmux send-keys -t am-server 'PORT=4801 npx tsx server/index.ts' Enter${NC}\n"
    STEP=$((STEP + 1))
    echo ""
    printf "  ${STEP}. Access Agent Manager:\n"
    echo ""
    printf "     ${CYAN}http://%s:4801${NC}\n" "$TAILSCALE_IP"
    STEP=$((STEP + 1))
fi

if [[ "$WANT_CLAUDE" =~ ^[Yy] ]]; then
    echo ""
    printf "  ${STEP}. Start a Claude Code session in tmux:\n"
    echo ""
    printf "     ${CYAN}tmux new-session -d -s my-project -c ~/dev/my-project${NC}\n"
    printf "     ${CYAN}tmux send-keys -t my-project 'claude --dangerously-skip-permissions' Enter${NC}\n"
    echo ""
fi
printf "  ${YELLOW}Remember:${NC} Set an Anthropic spend cap at console.anthropic.com\n"
echo "  before running unattended agents."
echo ""
