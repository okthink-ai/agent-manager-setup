#!/usr/bin/env bash
#
# setup.sh — Run on a fresh Ubuntu 24.04 VPS (as root) to set up Agent Manager.
#
# This script:
#   1. Creates a non-root user and hardens SSH
#   2. Installs fail2ban
#   3. Installs system packages, NVM, Node.js 22
#   4. Installs Tailscale
#   5. Installs GitHub CLI and authenticates
#   6. Installs Claude Code
#   7. Clones Agent Manager and installs dependencies
#   8. Prints a summary with access URLs
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

echo ""
info "Will create user '$NEW_USER' and install everything under /home/$NEW_USER"
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

# ─── From here on, everything runs as the new user ────────────────────
# We use `su - $NEW_USER -c "..."` to run commands in the user's login shell.

run_as_user() {
    su - "$NEW_USER" -c "$1"
}

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
else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    info "Starting Tailscale — follow the auth URL below:"
    echo ""
    tailscale up
    echo ""

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
else
    echo "  Agent Manager needs read access to the okthink-ai GitHub repos."
    echo "  You can use your main GitHub account, or a secondary account"
    echo "  if you prefer to limit access on this server."
    echo ""
    echo "  When the browser opens, make sure you're logged into the"
    echo "  GitHub account you want to use before approving."
    echo ""
    info "Authenticating with GitHub via SSH..."
    echo ""
    run_as_user "gh auth login -p ssh"
    echo ""
fi

# Add read:packages scope
info "Ensuring read:packages scope..."
run_as_user "gh auth refresh -h github.com -s read:packages"

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

# ─── 7. Claude Code ──────────────────────────────────────────────────

section "7/8  Claude Code"

if run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && command -v claude' &>/dev/null; then
    CLAUDE_VERSION=$(run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && claude --version' 2>/dev/null || echo "unknown")
    ok "Claude Code already installed: $CLAUDE_VERSION"
else
    info "Installing Claude Code..."
    run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && npm install -g @anthropic-ai/claude-code'
    ok "Claude Code installed"
fi

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

npm_install_with_retry "~/dev/claude-manager" "root"
npm_install_with_retry "~/dev/claude-manager/web" "web"

# Copy .env.example if it exists
if [[ -f "$INSTALL_DIR/.env.example" ]] && [[ ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    chown "$NEW_USER:$NEW_USER" "$INSTALL_DIR/.env"
    ok "Copied .env.example to .env"
fi

# Write Firebase config for the frontend (client-side keys, not secrets)
WEB_ENV="$INSTALL_DIR/web/.env"
if [[ -f "$WEB_ENV" ]]; then
    ok "web/.env already exists"
else
    info "Writing Firebase config to web/.env..."
    run_as_user 'cat > ~/dev/claude-manager/web/.env <<ENVEOF
VITE_FIREBASE_API_KEY=AIzaSyCGCFvt5iN93rQkH6R5zStANc2ZGj_YL8E
VITE_FIREBASE_AUTH_DOMAIN=claude-manager-chat.firebaseapp.com
VITE_FIREBASE_PROJECT_ID=claude-manager-chat
VITE_FIREBASE_STORAGE_BUCKET=claude-manager-chat.firebasestorage.app
VITE_FIREBASE_MESSAGING_SENDER_ID=1041886556076
VITE_FIREBASE_APP_ID=1:1041886556076:web:22e67ff4818b56c80e9409
ENVEOF'
    ok "Firebase config written to web/.env"
fi

# Build frontend for prod mode (plain HTTP, no cert warnings over Tailscale)
info "Building frontend for production..."
run_as_user 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && cd ~/dev/claude-manager/web && npx vite build'
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
printf "     ${CYAN}Host agent-manager-vps\n"
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
    printf "     ${CYAN}ssh agent-manager-vps${NC}\n"
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

echo ""
printf "  ${STEP}. Start a Claude Code session in tmux:\n"
echo ""
printf "     ${CYAN}tmux new-session -d -s my-project -c ~/dev/my-project${NC}\n"
printf "     ${CYAN}tmux send-keys -t my-project 'claude --dangerously-skip-permissions' Enter${NC}\n"
echo ""
printf "  ${YELLOW}Remember:${NC} Set an Anthropic spend cap at console.anthropic.com\n"
echo "  before running unattended agents."
echo ""
