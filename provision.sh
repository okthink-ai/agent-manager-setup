#!/usr/bin/env bash
#
# provision.sh — Run on your laptop to provision a Hetzner VPS for Agent Manager.
#
# Two paths:
#   1. Automated: provide a Hetzner API token and the script creates the firewall + server via hcloud CLI
#   2. Manual: the script prints a checklist for the Hetzner Console, then you paste the server IP
#
# Either way, it generates an SSH key (if needed), writes ~/.ssh/config, and scp's setup.sh to the server.
#
# Usage: bash provision.sh [-y|--bypass-consent]
#   --bypass-consent  Run unattended — accept every consent prompt and use the
#                     default choices (suggested location, cheapest server type).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"

SSH_KEY_PATH="$HOME/.ssh/agent_manager"
SSH_CONFIG_HOST="agent-manager-vps"
SERVER_NAME="agent-manager"
FIREWALL_NAME="agent-manager-firewall"
IMAGE="ubuntu-24.04"

# Minimum spec floor a server type must meet to qualify. The script picks the
# cheapest qualifying type that is actually available in the chosen location —
# which may be an x86 type (CX/CPX) or an ARM type (CAX), whichever is best for
# that region. SERVER_TYPE is resolved at runtime, not hardcoded.
MIN_VCPU=4
MIN_RAM_GB=8

# When true (set by -y/--bypass-consent), every consent prompt is auto-accepted
# and selection prompts use their defaults — for unattended/automated runs.
BYPASS_CONSENT=false

# Explicit region (set by --location). Overrides the location prompt and the
# geo-IP suggestion. Lets unattended runs pin a region when geo-IP can't.
LOCATION_OVERRIDE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}==> %s${NC}\n" "$*"; }
ok()    { printf "${GREEN}==> %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}==> %s${NC}\n" "$*"; }
err()   { printf "${RED}==> %s${NC}\n" "$*" >&2; }

# This script is meant to run as your normal user — it calls `sudo` only for the
# few steps that need root (package and hcloud install). If the whole thing is
# launched under `sudo`, then $HOME is /root and the SSH key, ~/.ssh/config entry
# and hcloud context all get written into root's home — leaving your real user
# unable to `ssh agent-manager-vps` without sudo. Detect that case and re-exec as
# the invoking user so every artifact lands in (and is owned by) your home.
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    warn "Launched with sudo — re-running as '$SUDO_USER' so keys and SSH config land in your home, not /root."
    warn "(Individual steps that need root will still ask for sudo on their own.)"
    exec sudo -u "$SUDO_USER" -H -- bash "$0" "$@"
fi

usage() {
    cat <<EOF
Usage: bash provision.sh [options]

Provision a Hetzner VPS for Agent Manager.

Options:
  -y, --bypass-consent   Run unattended: accept every consent prompt and use
                         default choices (nearest location, cheapest server
                         type). Needs a Hetzner token already configured — via
                         the saved hcloud context or the HCLOUD_TOKEN env var.
      --location <name>  Region to provision in (e.g. fsn1, ash, hel1). Skips
                         the location prompt; pair with --bypass-consent when
                         geo-IP can't detect your nearest region.
  -h, --help             Show this help and exit.
EOF
}

# Parse CLI args before anything interactive happens.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--bypass-consent|--yes) BYPASS_CONSENT=true ;;
        --location)
            LOCATION_OVERRIDE="${2:-}"
            [[ -z "$LOCATION_OVERRIDE" ]] && { err "--location needs a value (e.g. --location fsn1)"; exit 1; }
            shift ;;
        --location=*) LOCATION_OVERRIDE="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# Yes/no prompt. Empty input (just Enter) counts as yes. Returns 0 for yes, 1
# for no. Always used as an if-condition, so it's safe under `set -e`; an EOF
# (Ctrl+D) reads as "no" and lets the caller decline gracefully.
# With --bypass-consent it auto-accepts, echoing what it implied.
confirm() {
    if [[ "$BYPASS_CONSENT" == true ]]; then
        ok "$1 → yes (auto, --bypass-consent)"
        return 0
    fi
    local reply
    read -rp "$1 [Y/n]: " reply || return 1
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# Yes/no prompt for DESTRUCTIVE actions. Unlike confirm(), the default is no:
# only an explicit y/Y answer returns 0 — a bare Enter or an EOF (Ctrl+D)
# declines. Never auto-accepted: even under --bypass-consent it declines, so a
# destructive step can't happen without a deliberate keystroke.
confirm_destructive() {
    if [[ "$BYPASS_CONSENT" == true ]]; then
        warn "$1 → no (destructive prompts are never auto-accepted, even with --bypass-consent)"
        return 1
    fi
    local reply
    read -rp "$1 [y/N]: " reply || return 1
    [[ "$reply" =~ ^[Yy] ]]
}

# Read a line into the named variable, or auto-fill <auto-value> under
# --bypass-consent (echoing the implied answer so the run stays auditable).
ask() {  # ask <varname> <prompt> <auto-value>
    local __var="$1" __prompt="$2" __auto="$3" __reply
    if [[ "$BYPASS_CONSENT" == true ]]; then
        printf -v "$__var" '%s' "$__auto"
        ok "${__prompt}${__auto}  (auto, --bypass-consent)"
        return 0
    fi
    read -rp "$__prompt" __reply
    printf -v "$__var" '%s' "$__reply"
}

# Read a secret into the named variable, masking each keystroke with a bullet so
# you can see that input registered — unlike `read -s`, which shows nothing at
# all. Handles backspace and Enter; pasting a multi-character token works too.
read_secret() {  # read_secret <varname> <prompt>
    local __var="$1" __char __secret=""
    printf '%s' "$2" >&2
    while IFS= read -rsn1 __char; do
        case "$__char" in
            '' | $'\n' | $'\r') break ;;             # Enter
            $'\x7f' | $'\x08')                        # Backspace / Delete
                if [[ -n "$__secret" ]]; then
                    __secret="${__secret%?}"
                    printf '\b \b' >&2
                fi ;;
            *)
                __secret+="$__char"
                printf '•' >&2 ;;
        esac
    done
    printf '\n' >&2
    printf -v "$__var" '%s' "$__secret"
}

# Try to open a URL in a real browser. Returns 0 ONLY if it actually launched
# one — not merely because an opener binary exists. On a headless/SSH session
# (no DISPLAY) or when no browser handler is configured, returns non-zero so
# callers fall back to printing the link. Runs synchronously so we can trust
# the opener's exit status (xdg-open returns non-zero when it finds no handler).
open_url() {
    local url="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        command -v open &>/dev/null || return 1
        open "$url" &>/dev/null
        return
    fi
    # Linux: a browser can only open inside a graphical session.
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1
    command -v xdg-open &>/dev/null || return 1
    xdg-open "$url" &>/dev/null
}

# Detect the system package manager, for auto-installing missing tools.
detect_pkg_mgr() {
    if   command -v apt-get &>/dev/null; then echo apt
    elif command -v dnf     &>/dev/null; then echo dnf
    elif command -v yum     &>/dev/null; then echo yum
    elif command -v brew    &>/dev/null; then echo brew
    elif command -v pacman  &>/dev/null; then echo pacman
    elif command -v zypper  &>/dev/null; then echo zypper
    fi
}

# Map a required command to its package name for the given manager. Most match
# the command name; the exceptions are the ssh tools and the coreutils set.
pkg_for_cmd() {  # pkg_for_cmd <cmd> <mgr>
    case "$1" in
        ssh|scp|ssh-keygen)
            case "$2" in apt) echo openssh-client ;; dnf|yum) echo openssh-clients ;; *) echo openssh ;; esac ;;
        awk)                 echo gawk ;;
        sort|cut|paste|head) echo coreutils ;;
        *)                   echo "$1" ;;
    esac
}

# Install packages with the detected manager (sudo where the OS needs it).
install_pkgs() {  # install_pkgs <mgr> <pkg...>
    local mgr="$1"; shift
    case "$mgr" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y "$@" ;;
        dnf)    sudo dnf install -y "$@" ;;
        yum)    sudo yum install -y "$@" ;;
        brew)   brew install "$@" ;;
        pacman) sudo pacman -S --noconfirm "$@" ;;
        zypper) sudo zypper install -y "$@" ;;
        *)      return 1 ;;
    esac
}

# Cute bodega-style splash — an ASCII rendering of the "bodega" wordmark. Pure
# decoration; never let it abort the run. The art prints via a quoted heredoc
# so its $ # % * characters are all literal (no escaping needed).
banner() {
    printf "\n${RED}"
    cat <<'BODEGA_ART'
   ⢀⣠⡴⠶⢾⣿⣿⣿⣿                    ⠈⢹⣿⣿⣿⡇              ⢠⣴⣶⡄
  ⢰⣿⣃⣀  ⣿⣿⣿⣟⣠⣤⣤⣄⡀   ⣠⣤⠴⣤⣤⣀   ⣀⣤⣴⠦⣼⣿⣿⣿⡇ ⢀⣠⡴⢶⣤⣄  ⢀⣠⣤⠶⢦⣿⣝⠛⠃⢀⣤⡤⠶⣶⣤
  ⢿⣿⣿⣿⡷ ⣿⣿⣿⣿⠉⠹⣿⣿⣿⡄⢠⣾⣿⡇ ⠸⣿⣿⣧ ⣼⣿⣿⡇ ⢸⣿⣿⣿⡇⣰⣿⣿  ⣿⣿⣷⢠⣿⣿⣿ ⠈⣿⣿⣷⡀⣿⣿⣷ ⣿⣿
  ⠈⠙⠛⠛⠁ ⣿⣿⣿⣿  ⣿⣿⣿⡇⣿⣿⣿⡇  ⣿⣿⣿⣷⣿⣿⣿⡆ ⢸⣿⣿⣿⡇⣿⣿⣿⡴⠞⠛⠋⠉⠸⣿⣿⣿  ⣿⣿⣿⠃⢈⣩⣥⡶⣿⣿
        ⣿⣿⣿⣿  ⣿⣿⣿⠇⢻⣿⣿⣧  ⣿⣿⣿⠉⣿⣿⣿⣇ ⢸⣿⣿⣿⡇⢿⣿⣿⣷⣄⣀⣀⣠⡄⣉⡿⠿⠦⠴⠿⠛⠁⢰⣿⣿⣿ ⣿⣿
        ⠛⠛⠛⠋⢀⣴⣿⠿⠋  ⠙⠿⣿⣄⣠⡿⠟⠁ ⠘⠿⣿⣿⡷⢿⣿⣿⡿⠧⠈⠻⢿⣿⣿⣿⠿⠋⢰⣿⣷⣶⣶⣾⣿⣿⣶⣜⢿⣿⣿⡿⢻⣿
                                     ⣠⣴⣶⣶⠶⠶⠶⣤⣄⣈⠛⠿⠿⠿⠿⠿⠿⣿⣿    ⠈⢿
BODEGA_ART
    printf "${NC}\n"
    printf "  ${BOLD}AGENT MANAGER SETUP${NC}   ${DIM}· your code · your agents · one bodega${NC}\n\n"
}
banner

# Remove any stray temp file on exit (e.g. an interrupted SSH-config rewrite).
cleanup() { [[ -n "${SSH_CONFIG:-}" && -f "${SSH_CONFIG}.tmp" ]] && rm -f "${SSH_CONFIG}.tmp"; }
trap cleanup EXIT

# On Ctrl+C, tell the user the script is safe to re-run. Every expensive step
# (key, token, SSH key, firewall, server) is idempotent and gets skipped on the
# next run, so re-running picks up where this left off rather than starting over.
trap 'echo; err "Interrupted. Re-run this script to resume — finished steps are skipped."; exit 130' INT

# ─── Pre-flight checks ───────────────────────────────────────────────

if [[ ! -f "$SETUP_SCRIPT" ]]; then
    err "Cannot find setup.sh at $SETUP_SCRIPT"
    err "Make sure provision.sh and setup.sh are in the same directory."
    exit 1
fi

# Required local tools. hcloud is intentionally NOT here — the automated path
# installs it on demand. Everything below must already be present.
REQUIRED_CMDS=(curl jq ssh scp ssh-keygen awk sort grep sed cut paste)
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" &>/dev/null || MISSING_CMDS+=("$cmd")
done
if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
    warn "Missing required tools: ${MISSING_CMDS[*]}"
    PKG_MGR=$(detect_pkg_mgr)
    if [[ -z "$PKG_MGR" ]]; then
        err "No supported package manager found (apt/dnf/yum/brew/pacman/zypper)."
        err "Install these manually and re-run: ${MISSING_CMDS[*]}"
        exit 1
    fi

    # Map the missing commands to packages, de-duplicated using only bash
    # builtins — one of the missing tools could be something we'd normally
    # dedupe with (e.g. sort), so we can't rely on it here.
    declare -A _seen_pkg=()
    INSTALL_PKGS=()
    for cmd in "${MISSING_CMDS[@]}"; do
        pkg=$(pkg_for_cmd "$cmd" "$PKG_MGR")
        [[ -n "${_seen_pkg[$pkg]:-}" ]] || { INSTALL_PKGS+=("$pkg"); _seen_pkg[$pkg]=1; }
    done

    echo "  They can be installed with $PKG_MGR: ${INSTALL_PKGS[*]}"
    if ! confirm "Install them now?"; then
        err "These tools are required. Install them and re-run: ${INSTALL_PKGS[*]}"
        exit 1
    fi

    info "Installing: ${INSTALL_PKGS[*]}"
    if ! install_pkgs "$PKG_MGR" "${INSTALL_PKGS[@]}"; then
        err "Auto-install failed. Install manually and re-run: ${INSTALL_PKGS[*]}"
        exit 1
    fi

    # Confirm every command is now actually on PATH before moving on.
    STILL_MISSING=()
    for cmd in "${MISSING_CMDS[@]}"; do
        command -v "$cmd" &>/dev/null || STILL_MISSING+=("$cmd")
    done
    if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
        err "Still missing after install: ${STILL_MISSING[*]}"
        err "Install these manually and re-run."
        exit 1
    fi
    ok "Installed missing tools: ${INSTALL_PKGS[*]}"
fi

# ─── SSH key ──────────────────────────────────────────────────────────

if [[ -f "$SSH_KEY_PATH" && -f "${SSH_KEY_PATH}.pub" ]]; then
    ok "SSH key already exists at $SSH_KEY_PATH"
elif [[ -f "$SSH_KEY_PATH" && ! -f "${SSH_KEY_PATH}.pub" ]]; then
    # Private key present but public key missing — almost always a previous run
    # interrupted during ssh-keygen. Refuse to guess; tell the user how to reset.
    err "Found a private key at $SSH_KEY_PATH but no public key at ${SSH_KEY_PATH}.pub"
    err "This usually means a previous run was interrupted during key generation."
    err "Remove the partial key and re-run:  rm -f \"$SSH_KEY_PATH\""
    exit 1
else
    # Check if the user wants to reuse an existing key
    echo "No SSH key found at $SSH_KEY_PATH."
    echo ""
    echo "  You can either:"
    echo "    1) Generate a new key (recommended)"
    echo "    2) Use an existing SSH key"
    echo ""
    ask GEN_KEY "Generate a new key? (y/n): " "y"

    if [[ "$GEN_KEY" =~ ^[Yy] ]]; then
        info "Generating SSH key at $SSH_KEY_PATH"
        KEYGEN_ARGS=(-t ed25519 -C "agent-manager-vps" -f "$SSH_KEY_PATH")
        # Unattended runs can't answer the passphrase prompt — make it empty.
        [[ "$BYPASS_CONSENT" == true ]] && KEYGEN_ARGS+=(-N "")
        ssh-keygen "${KEYGEN_ARGS[@]}"
    else
        echo ""
        echo "  Enter the path to your existing SSH private key."
        echo "  Common locations:"
        # List existing keys to help the user pick
        for key in "$HOME"/.ssh/id_* "$HOME"/.ssh/*.pub; do
            [[ -f "$key" ]] && echo "    $key"
        done
        echo ""
        read -rp "Path to private key: " EXISTING_KEY

        # Expand ~ if present
        EXISTING_KEY="${EXISTING_KEY/#\~/$HOME}"

        if [[ ! -f "$EXISTING_KEY" ]]; then
            err "Key not found at $EXISTING_KEY"
            exit 1
        fi

        if [[ ! -f "${EXISTING_KEY}.pub" ]]; then
            err "Public key not found at ${EXISTING_KEY}.pub"
            err "The public key must be at the same path with a .pub extension."
            exit 1
        fi

        SSH_KEY_PATH="$EXISTING_KEY"
        ok "Using existing key: $SSH_KEY_PATH"
    fi
fi

if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
    err "Public key not found at ${SSH_KEY_PATH}.pub — cannot continue."
    exit 1
fi
SSH_PUBKEY=$(cat "${SSH_KEY_PATH}.pub")
echo ""

# ─── Hetzner provisioning path ────────────────────────────────────────

printf "${BOLD}Do you want to create the server automatically via the Hetzner API?${NC}\n"
echo "  If yes, this script will install the CLI (if needed), walk you through"
echo "  getting an API token, and create the firewall + server for you."
echo "  If no, it will print a checklist for the Hetzner Console."
echo ""
ask USE_API "Use Hetzner API? (y/n): " "y"
echo ""

if [[ "$USE_API" =~ ^[Yy] ]]; then
    # ── Automated path via hcloud CLI ──
    # Doctor-style checks: CLI installed? → Token available? → Token valid?

    # Step 1: hcloud CLI
    if command -v hcloud &>/dev/null; then
        ok "hcloud CLI found: $(hcloud version 2>/dev/null || echo 'unknown version')"
    else
        echo ""
        warn "The hcloud CLI is not installed (it talks to the Hetzner API for you)."
        echo "  On macOS it's installed via Homebrew; on Linux it's downloaded from"
        echo "  GitHub and moved into /usr/local/bin (this asks for sudo)."
        if ! confirm "Install the hcloud CLI now?"; then
            err "hcloud is required for the automated path. Install it yourself and re-run,"
            err "or re-run and choose the manual checklist: https://github.com/hetznercloud/cli"
            exit 1
        fi
        info "Installing hcloud CLI..."
        if [[ "$(uname)" == "Darwin" ]]; then
            if command -v brew &>/dev/null; then
                brew install hcloud
                ok "hcloud CLI installed"
            else
                err "Install Homebrew first (https://brew.sh), then re-run this script."
                exit 1
            fi
        elif [[ "$(uname)" == "Linux" ]]; then
            # Resolve the latest version from the releases "latest" redirect on
            # github.com — NOT api.github.com, which rate-limits unauthenticated
            # requests to 60/hour (hitting that limit was killing this step).
            # The `|| true` stops a failed lookup from silently aborting the
            # whole script under `set -e`; the guard below reports it instead.
            HCLOUD_VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
                https://github.com/hetznercloud/cli/releases/latest 2>/dev/null \
                | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
            if [[ -z "$HCLOUD_VERSION" ]]; then
                err "Could not determine the latest hcloud version (GitHub unreachable)."
                err "Install hcloud manually, then re-run: https://github.com/hetznercloud/cli/releases"
                exit 1
            fi
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64)  HCLOUD_ARCH="linux-amd64" ;;
                aarch64) HCLOUD_ARCH="linux-arm64" ;;
                *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
            esac
            # -f makes curl fail on a 404 instead of piping an HTML error page to tar.
            HCLOUD_TARBALL="/tmp/hcloud-${HCLOUD_ARCH}.tar.gz"
            if ! curl -fsSL "https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}/hcloud-${HCLOUD_ARCH}.tar.gz" -o "$HCLOUD_TARBALL"; then
                err "Failed to download hcloud ${HCLOUD_VERSION} for ${HCLOUD_ARCH}."
                err "Install hcloud manually, then re-run: https://github.com/hetznercloud/cli/releases"
                exit 1
            fi
            if ! tar xz -C /tmp -f "$HCLOUD_TARBALL"; then
                err "Failed to extract the hcloud archive at $HCLOUD_TARBALL."
                rm -f "$HCLOUD_TARBALL"
                exit 1
            fi
            rm -f "$HCLOUD_TARBALL"
            HCLOUD_BIN=$(find /tmp -name 'hcloud' -type f -perm -u+x 2>/dev/null | head -1) || true
            if [[ -z "$HCLOUD_BIN" ]]; then
                err "Could not find hcloud binary after extraction"
                exit 1
            fi
            sudo mv "$HCLOUD_BIN" /usr/local/bin/hcloud
            ok "hcloud CLI installed"
        else
            err "Unsupported OS. Install hcloud manually: https://github.com/hetznercloud/cli"
            exit 1
        fi

        # Make sure the install actually put hcloud on PATH before continuing —
        # never fall through to the API steps with no working CLI.
        if ! command -v hcloud &>/dev/null; then
            err "hcloud was installed but isn't on your PATH. Open a new shell (or"
            err "add its install dir to PATH), then re-run this script."
            exit 1
        fi
    fi

    # Step 2: API token via hcloud context (persisted to ~/.config/hcloud/cli.toml)
    HCLOUD_CONTEXT="agent-manager"

    if hcloud server-type list &>/dev/null 2>&1; then
        ok "Hetzner API is reachable (active context: $(hcloud context active 2>/dev/null || echo 'env'))"
    else
        if [[ "$BYPASS_CONSENT" == true ]]; then
            err "No working Hetzner API token, and --bypass-consent can't prompt for one."
            err "Configure it first: run once interactively, or export a valid HCLOUD_TOKEN."
            exit 1
        fi
        echo ""
        printf "${BOLD}Setting up Hetzner API access${NC}\n"
        echo ""
        echo "  This needs a Read & Write API token for a Hetzner Cloud project."
        echo ""
        echo "  Why this one step is manual: Hetzner has no API to create a project"
        echo "  or mint a token, so the bootstrap token can't be automated. You paste"
        echo "  it once — it's then saved and reused automatically on every later run."
        echo ""
        echo "  You almost certainly don't need to create a project: Hetzner makes a"
        echo "  'Default' project for you at signup, and any existing project works."
        echo "  Only make a new one if you want to isolate this from other resources."
        echo ""
        printf "  ${CYAN}1.${NC} Open the Console and pick a project (the Default is fine)\n"
        printf "  ${CYAN}2.${NC} Security → API Tokens → Generate API Token\n"
        echo "     Permissions: Read & Write — copy it (it's shown only once)"
        echo ""
        if confirm "Open the Hetzner Console in your browser now?"; then
            if open_url "https://console.hetzner.cloud/projects"; then
                ok "Opened the Hetzner Console in your browser."
            else
                warn "No graphical browser here — open this on a machine that has one:"
                printf "  ${CYAN}https://console.hetzner.cloud/projects${NC}\n"
            fi
        fi
        echo ""

        while true; do
            read_secret HCLOUD_TOKEN "Paste your Hetzner API token (input is masked): "
            ok "Token received."

            export HCLOUD_TOKEN
            info "Verifying token..."
            if hcloud server-type list &>/dev/null; then
                ok "Token is valid."

                # Save to hcloud context so future runs don't need the token again
                hcloud context delete "$HCLOUD_CONTEXT" &>/dev/null || true
                hcloud context create --token-from-env "$HCLOUD_CONTEXT"
                hcloud context use "$HCLOUD_CONTEXT"

                ok "Saved to hcloud context '$HCLOUD_CONTEXT'"
                echo ""
                echo "  Your token is stored in ~/.config/hcloud/cli.toml"
                echo "  Future runs will use it automatically — no need to paste again."
                break
            fi

            unset HCLOUD_TOKEN
            err "Token is invalid or expired. Try again (Ctrl+C to quit)."
            echo ""
        done
    fi

    # Upload SSH key
    SSH_KEY_NAME="agent-manager-key"
    if hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
        ok "SSH key '$SSH_KEY_NAME' already exists in Hetzner"
    else
        echo ""
        echo "  Your PUBLIC key (${SSH_KEY_PATH}.pub) is uploaded to Hetzner as"
        echo "  '$SSH_KEY_NAME' so the new server trusts it. Your private key never leaves this machine."
        if ! confirm "Upload your public SSH key to Hetzner?"; then
            err "The SSH key is required to log into the server. Aborting (nothing was created)."
            exit 1
        fi
        info "Uploading SSH key to Hetzner..."
        hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key "$SSH_PUBKEY"
        ok "SSH key uploaded"
    fi

    # Create firewall
    EXPECTED_RULE_COUNT=8
    if hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
        RULE_COUNT=$(hcloud firewall describe "$FIREWALL_NAME" -o json | jq '.rules | length')
        if [[ "$RULE_COUNT" -lt "$EXPECTED_RULE_COUNT" ]]; then
            warn "Firewall has incomplete rules ($RULE_COUNT/$EXPECTED_RULE_COUNT). Deleting and recreating..."
            hcloud firewall delete "$FIREWALL_NAME"
        else
            ok "Firewall '$FIREWALL_NAME' already exists with all rules"
        fi
    fi

    if ! hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
        echo ""
        echo "  Firewall '$FIREWALL_NAME' locks the server to SSH + ping inbound and only"
        echo "  the outbound ports setup needs (HTTPS, HTTP, DNS, NTP, Git-SSH). It's free."
        if ! confirm "Create the firewall now?"; then
            err "The firewall is required for a hardened setup. Aborting (nothing was created)."
            err "Re-run when ready; your token and SSH key are already saved."
            exit 1
        fi
        info "Creating firewall '$FIREWALL_NAME'..."
        hcloud firewall create --name "$FIREWALL_NAME"

        # Inbound rules
        hcloud firewall add-rule "$FIREWALL_NAME" --direction in  --protocol tcp  --port 22  --source-ips 0.0.0.0/0 --source-ips ::/0 --description "SSH"
        hcloud firewall add-rule "$FIREWALL_NAME" --direction in  --protocol icmp             --source-ips 0.0.0.0/0 --source-ips ::/0 --description "Ping"

        # Outbound rules
        hcloud firewall add-rule "$FIREWALL_NAME" --direction out --protocol tcp  --port 443 --destination-ips 0.0.0.0/0 --destination-ips ::/0 --description "HTTPS"
        hcloud firewall add-rule "$FIREWALL_NAME" --direction out --protocol tcp  --port 80  --destination-ips 0.0.0.0/0 --destination-ips ::/0 --description "HTTP"
        hcloud firewall add-rule "$FIREWALL_NAME" --direction out --protocol tcp  --port 53  --destination-ips 0.0.0.0/0 --destination-ips ::/0 --description "DNS-TCP"
        hcloud firewall add-rule "$FIREWALL_NAME" --direction out --protocol udp  --port 53  --destination-ips 0.0.0.0/0 --destination-ips ::/0 --description "DNS-UDP"
        hcloud firewall add-rule "$FIREWALL_NAME" --direction out --protocol udp  --port 123 --destination-ips 0.0.0.0/0 --destination-ips ::/0 --description "NTP"
        hcloud firewall add-rule "$FIREWALL_NAME" --direction out --protocol tcp  --port 22  --destination-ips 0.0.0.0/0 --destination-ips ::/0 --description "Git-SSH"

        ok "Firewall created with all rules"
    fi

    # Create server — but only skip creation after showing you WHICH server we
    # found and letting you decide. A name-only "it exists, skip" silently
    # reuses any server called "$SERVER_NAME" in the project this token points
    # to — which is exactly how "I deleted my server but setup won't make a new
    # one" happens: the one you deleted was in a different project than this
    # context, so a leftover "$SERVER_NAME" here still matches.
    SERVER_EXISTS=false
    if hcloud server describe "$SERVER_NAME" &>/dev/null; then
        EXISTING_STATUS=$(hcloud server describe "$SERVER_NAME" -o json 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unknown")
        EXISTING_IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null || true)
        ACTIVE_CTX=$(hcloud context active 2>/dev/null || echo "env token")
        SERVER_EXISTS=true
        warn "A server named '$SERVER_NAME' already exists (project: $ACTIVE_CTX, status: $EXISTING_STATUS, IP: ${EXISTING_IP:-none})."
        if [[ "$BYPASS_CONSENT" != true ]]; then
            echo "  If this isn't the server you expect — e.g. you deleted yours in a different"
            echo "  Hetzner project than this token points to — you can replace it now."
            if ! confirm "Reuse this existing server? (No = delete it and create a fresh one)"; then
                if confirm_destructive "Permanently DELETE '$SERVER_NAME' (IP ${EXISTING_IP:-none}) and recreate it?"; then
                    info "Deleting server '$SERVER_NAME'..."
                    hcloud server delete "$SERVER_NAME"
                    ok "Deleted. A fresh server will be created below."
                    SERVER_EXISTS=false
                else
                    warn "Keeping the existing server."
                fi
            fi
        fi
    fi

    if [[ "$SERVER_EXISTS" == true ]]; then
        ok "Reusing existing server '$SERVER_NAME'"
        SERVER_IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null || true)
    else
        # Cache the server-type catalogue once — we reuse it for every location.
        # This is queried against YOUR authenticated Hetzner project, so it
        # returns exactly the types, locations, pricing, and stock your account
        # is entitled to provision. An EU account and a US account each get their
        # own real option set here — we never guess entitlements from geo-IP.
        #   ST_JSON   : full specs + per-location pricing (EUR, ex. VAT)
        #   ST_AVAIL  : one "name location available" row per (type, location);
        #               location_available reflects real-time stock, not just pricing.
        info "Fetching server types available to your Hetzner project..."
        # Capture with `|| true` so a transient API/network error surfaces as our
        # own clear message below instead of a bare set -e abort mid-substitution.
        ST_JSON=$(hcloud server-type list -o json 2>/dev/null) || true
        if [[ -z "$ST_JSON" || "$ST_JSON" == "[]" ]]; then
            err "Could not fetch the Hetzner server catalogue (empty or failed response)."
            err "Check your network and that the token has read access, then re-run."
            exit 1
        fi
        ST_AVAIL=$(jq -r '.[] | .name as $n | .locations[] | [$n, .name, (if .available then "true" else "false" end)] | @tsv' <<<"$ST_JSON") || true
        if [[ -z "$ST_AVAIL" ]]; then
            err "Could not extract location availability from the Hetzner catalogue."
            err "Check your network and that the token has read access, then re-run."
            exit 1
        fi

        # candidates_for <location> → TSV rows "name cores ram disk arch eur/mo",
        # cheapest first, for every type that meets the spec floor AND is in stock
        # at that location. Works the same everywhere — EU, US, or Singapore —
        # so each user gets the best type their nearest region actually offers.
        candidates_for() {
            local loc="$1" avail avail_csv
            avail=$(awk -v l="$loc" '$2 == l && $3 == "true" { print $1 }' <<<"$ST_AVAIL")
            [[ -z "$avail" ]] && return 0
            avail_csv=$(echo "$avail" | paste -sd, -)
            jq -r --argjson vcpu "$MIN_VCPU" --argjson ram "$MIN_RAM_GB" --arg loc "$loc" '
                .[]
                | select((.cores >= $vcpu) and (.memory >= $ram))
                | . as $st
                | (.prices[]? | select(.location == $loc)) as $p
                | select($p != null)
                | [$st.name, ($st.cores|tostring), ($st.memory|tostring),
                   ($st.disk|tostring), $st.architecture, $p.price_monthly.net] | @tsv
            ' <<<"$ST_JSON" \
                | awk -v avail="$avail_csv" '
                    BEGIN { n=split(avail, a, ","); for (i=1;i<=n;i++) ok[a[i]]=1 }
                    ok[$1]' \
                | sort -t$'\t' -k6 -g
        }

        # Locations that have at least one qualifying type in stock right now.
        ALL_LOCATIONS=$(awk '{print $2}' <<<"$ST_AVAIL" | sort -u)
        AVAILABLE_LOCATIONS=""
        for loc in $ALL_LOCATIONS; do
            [[ -n "$(candidates_for "$loc")" ]] && AVAILABLE_LOCATIONS+="$loc"$'\n'
        done
        AVAILABLE_LOCATIONS=$(echo "$AVAILABLE_LOCATIONS" | sed '/^$/d')

        if [[ -z "$AVAILABLE_LOCATIONS" ]]; then
            err "No location currently has a server type meeting the spec floor"
            err "(${MIN_VCPU} vCPU / ${MIN_RAM_GB} GB RAM). Check https://console.hetzner.cloud."
            exit 1
        fi

        # Geo-IP is used ONLY to suggest the nearest of the locations your account
        # can already use (computed above) — it never changes the option set.
        # If detection fails, you simply pick a location yourself; nothing breaks.
        SUGGESTED=""
        USER_LON=""
        USER_LAT=""
        GEO_INFO=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null || true)
        if [[ -n "$GEO_INFO" ]]; then
            # `|| true`: geo-IP is best-effort. If ipinfo returns non-JSON, don't
            # let jq's failure abort the run under `set -e` — just skip the hint.
            USER_LOC=$(echo "$GEO_INFO" | jq -r '.loc // empty' 2>/dev/null || true)
            USER_CITY=$(echo "$GEO_INFO" | jq -r '.city // empty' 2>/dev/null || true)
            USER_COUNTRY=$(echo "$GEO_INFO" | jq -r '.country // empty' 2>/dev/null || true)
            if [[ -n "$USER_LOC" ]]; then
                USER_LAT=$(echo "$USER_LOC" | cut -d, -f1)
                USER_LON=$(echo "$USER_LOC" | cut -d, -f2)
                info "Detected your location: ${USER_CITY:-unknown}, ${USER_COUNTRY:-unknown}"
            fi
        fi

        # Build location list with distances
        echo ""
        info "Locations your Hetzner project can provision (with a qualifying type in stock):"
        echo ""
        printf "  %-8s  %-20s  %s\n" "NAME" "CITY" ""
        printf "  %-8s  %-20s  %s\n" "----" "----" ""
        BEST_DIST=999999
        for loc in $AVAILABLE_LOCATIONS; do
            # || true: a hiccup describing one location shouldn't abort the run —
            # we just fall back to "unknown" city and skip its distance estimate.
            LOC_JSON=$(hcloud location describe "$loc" -o json 2>/dev/null || true)
            CITY=$(echo "$LOC_JSON" | jq -r '.city // "unknown"' 2>/dev/null || echo "unknown")
            MARKER=""

            # Calculate rough distance if we have user coordinates
            if [[ -n "$USER_LAT" && -n "$USER_LON" ]]; then
                LOC_LAT=$(echo "$LOC_JSON" | jq -r '.latitude // empty' 2>/dev/null || true)
                LOC_LON=$(echo "$LOC_JSON" | jq -r '.longitude // empty' 2>/dev/null || true)
                if [[ -n "$LOC_LAT" && -n "$LOC_LON" ]]; then
                    # Simple Euclidean distance on lat/lon (good enough for ranking)
                    DIST=$(awk "BEGIN { printf \"%.0f\", sqrt(($USER_LAT - $LOC_LAT)^2 + ($USER_LON - $LOC_LON)^2) * 111 }")
                    MARKER="${DIST} km"
                    if awk "BEGIN { exit !($DIST < $BEST_DIST) }"; then
                        BEST_DIST=$DIST
                        SUGGESTED=$loc
                    fi
                fi
            fi

            if [[ -n "$MARKER" ]]; then
                printf "  %-8s  %-20s  ~%s\n" "$loc" "$CITY" "$MARKER"
            else
                printf "  %-8s  %s\n" "$loc" "$CITY"
            fi
        done

        PROMPT="Choose a location"
        if [[ -n "$SUGGESTED" ]]; then
            PROMPT="Choose a location [$SUGGESTED]"
        fi

        if [[ -n "$LOCATION_OVERRIDE" ]]; then
            # Explicit --location wins, for both interactive and unattended runs.
            if ! echo "$AVAILABLE_LOCATIONS" | grep -qw "$LOCATION_OVERRIDE"; then
                err "Location '$LOCATION_OVERRIDE' (from --location) has no qualifying server type."
                err "Available: $(echo $AVAILABLE_LOCATIONS | tr '\n' ' ')"
                exit 1
            fi
            LOCATION="$LOCATION_OVERRIDE"
            ok "Using location: $LOCATION  (from --location)"
        elif [[ "$BYPASS_CONSENT" == true ]]; then
            # Unattended: use the nearest detected region. Never guess — if
            # geo-IP found nothing, stop rather than provision in a random region.
            if [[ -z "$SUGGESTED" ]]; then
                err "Can't auto-pick a location: geo-IP detection returned no region."
                err "Re-run with an explicit region, e.g.:  --bypass-consent --location fsn1"
                err "Available: $(echo $AVAILABLE_LOCATIONS | tr '\n' ' ')"
                exit 1
            fi
            LOCATION="$SUGGESTED"
            ok "Using nearest location: $LOCATION  (auto, --bypass-consent)"
        else
            while true; do
                echo ""
                read -rp "$PROMPT: " LOCATION

                # Default to suggested if user just presses Enter
                if [[ -z "$LOCATION" && -n "$SUGGESTED" ]]; then
                    LOCATION="$SUGGESTED"
                    ok "Using suggested location: $LOCATION"
                fi

                # Reject empty input (no suggestion to fall back on). An empty
                # LOCATION otherwise matches `grep -qw ""` and breaks the loop,
                # later crashing on an empty type list ("TYPE_NAMES[0]: unbound").
                if [[ -z "$LOCATION" ]]; then
                    err "Please enter one of the locations listed above."
                    continue
                fi

                if echo "$AVAILABLE_LOCATIONS" | grep -qw "$LOCATION"; then
                    break
                fi

                err "'$LOCATION' has no qualifying server type. Pick one from the list above."
            done
        fi

        # ── Pick the server type for the chosen location ──
        # Cheapest qualifying type is the default; the rest are offered as overrides.
        CANDIDATES=$(candidates_for "$LOCATION")

        echo ""
        info "Server types available in $LOCATION (>= ${MIN_VCPU} vCPU / ${MIN_RAM_GB} GB, cheapest first):"
        echo ""
        printf "  %-3s %-8s %-5s %-7s %-8s %-5s %s\n" "#" "TYPE" "VCPU" "RAM" "DISK" "ARCH" "PRICE/mo"
        printf "  %-3s %-8s %-5s %-7s %-8s %-5s %s\n" "---" "----" "----" "-----" "-----" "----" "--------"
        TYPE_COUNT=0
        declare -a TYPE_NAMES=()
        while IFS=$'\t' read -r name cores ram disk arch price; do
            [[ -z "$name" ]] && continue
            TYPE_COUNT=$((TYPE_COUNT + 1))
            TYPE_NAMES+=("$name")
            EUR=$(awk "BEGIN { printf \"%.2f\", $price }")
            TAG=""
            [[ $TYPE_COUNT -eq 1 ]] && TAG="  <- cheapest (default)"
            printf "  %-3s %-8s %-5s %-7s %-8s %-5s ~€%s%s\n" \
                "$TYPE_COUNT" "$name" "$cores" "${ram} GB" "${disk} GB" "$arch" "$EUR" "$TAG"
        done <<<"$CANDIDATES"
        echo ""
        echo "  Prices are Hetzner's monthly rate in EUR, excluding VAT."
        echo ""

        DEFAULT_TYPE="${TYPE_NAMES[0]}"
        if [[ "$BYPASS_CONSENT" == true ]]; then
            SERVER_TYPE="$DEFAULT_TYPE"
            ok "Using cheapest server type: $SERVER_TYPE  (auto, --bypass-consent)"
        else
            while true; do
                read -rp "Choose a server type by # or name [$DEFAULT_TYPE]: " TYPE_CHOICE

                if [[ -z "$TYPE_CHOICE" ]]; then
                    SERVER_TYPE="$DEFAULT_TYPE"
                    break
                elif [[ "$TYPE_CHOICE" =~ ^[0-9]+$ ]] && (( TYPE_CHOICE >= 1 && TYPE_CHOICE <= TYPE_COUNT )); then
                    SERVER_TYPE="${TYPE_NAMES[$((TYPE_CHOICE - 1))]}"
                    break
                elif printf '%s\n' "${TYPE_NAMES[@]}" | grep -qw "$TYPE_CHOICE"; then
                    SERVER_TYPE="$TYPE_CHOICE"
                    break
                fi

                err "Pick a number (1-$TYPE_COUNT) or a type name from the list above."
            done
        fi
        ok "Selected server type: $SERVER_TYPE"

        # Look the chosen type's monthly price back up so the cost warning is exact.
        CHOSEN_PRICE=$(awk -F'\t' -v t="$SERVER_TYPE" '$1 == t { printf "%.2f", $6; exit }' <<<"$CANDIDATES")

        echo ""
        warn "About to create a PAID server: '$SERVER_NAME' — $SERVER_TYPE in $LOCATION."
        warn "Billing starts immediately at ~€${CHOSEN_PRICE}/mo (charged hourly while it exists)."
        if ! confirm "Create this server now?"; then
            err "Aborted before creating the server — no charges incurred."
            err "Re-run anytime; your token, SSH key, and firewall are already set up."
            exit 1
        fi

        info "Creating server '$SERVER_NAME' ($SERVER_TYPE in $LOCATION)..."
        hcloud server create \
            --name "$SERVER_NAME" \
            --type "$SERVER_TYPE" \
            --image "$IMAGE" \
            --location "$LOCATION" \
            --ssh-key "$SSH_KEY_NAME"

        SERVER_IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null || true)
        ok "Server created: $SERVER_IP"
    fi

    # A missing IPv4 here would send the SSH wait-loop into 30 doomed retries
    # against "root@". Fail fast with a clear cause instead.
    if [[ -z "${SERVER_IP:-}" ]]; then
        err "Server '$SERVER_NAME' exists but has no public IPv4 address."
        err "Attach an IPv4 in the Hetzner console (or recreate with IPv4 enabled), then re-run."
        exit 1
    fi

    # Attach firewall (idempotent — works whether the server was just created or already existed)
    echo ""
    if confirm "Attach firewall '$FIREWALL_NAME' to the server now? (strongly recommended)"; then
        info "Attaching firewall to server..."
        hcloud firewall apply-to-resource "$FIREWALL_NAME" --type server --server "$SERVER_NAME" 2>/dev/null || true
        ok "Firewall attached to server"
    else
        warn "Skipped firewall attach — the server's ports are exposed until you attach it:"
        warn "  hcloud firewall apply-to-resource $FIREWALL_NAME --type server --server $SERVER_NAME"
    fi

else
    # ── Manual path: print checklist ──

    printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
    printf "${BOLD}  Hetzner Console Setup Checklist${NC}\n"
    printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
    echo ""
    printf "${CYAN}1. Add your SSH key${NC}\n"
    echo "   Security -> SSH Keys -> Add SSH Key"
    echo "   Paste this public key:"
    echo ""
    echo "   $SSH_PUBKEY"
    echo ""
    printf "${CYAN}2. Create firewall '%s'${NC}\n" "$FIREWALL_NAME"
    echo "   Firewalls -> Create Firewall"
    echo ""
    echo "   Inbound rules:"
    echo "   ┌───────────┬──────────────┬─────────────────┬─────────────────┐"
    echo "   │ Direction │ Protocol     │ Source/Dest      │ Purpose         │"
    echo "   ├───────────┼──────────────┼─────────────────┼─────────────────┤"
    echo "   │ Inbound   │ TCP 22       │ 0.0.0.0/0       │ SSH             │"
    echo "   │ Inbound   │ ICMP         │ 0.0.0.0/0       │ Ping            │"
    echo "   ├───────────┼──────────────┼─────────────────┼─────────────────┤"
    echo "   │ Outbound  │ TCP 443      │ 0.0.0.0/0       │ HTTPS           │"
    echo "   │ Outbound  │ TCP 80       │ 0.0.0.0/0       │ HTTP (apt)      │"
    echo "   │ Outbound  │ TCP+UDP 53   │ 0.0.0.0/0       │ DNS             │"
    echo "   │ Outbound  │ UDP 123      │ 0.0.0.0/0       │ NTP             │"
    echo "   │ Outbound  │ TCP 22       │ 0.0.0.0/0       │ Git over SSH    │"
    echo "   └───────────┴──────────────┴─────────────────┴─────────────────┘"
    echo ""
    printf "${CYAN}3. Create server '%s'${NC}\n" "$SERVER_NAME"
    echo "   Servers -> Create Server"
    echo "   - Location: closest to you"
    echo "   - Image: Ubuntu 24.04 LTS"
    echo "   - Type: the cheapest in-stock type with >= ${MIN_VCPU} vCPU / ${MIN_RAM_GB} GB RAM"
    echo "           at your location. The console shows live pricing per region:"
    echo "             EU (Germany/Finland): CX33, CAX21 (ARM), or CPX31/CPX32 (AMD)"
    echo "             US (Ashburn/Hillsboro) & Singapore: CPX32 (AMD)"
    echo "           Pick the cheapest one that meets the spec — they all work."
    echo "   - Networking: enable IPv4"
    echo "   - SSH Key: select your key"
    printf "   - Firewall: attach '%s'\n" "$FIREWALL_NAME"
    printf "   - Name: %s\n" "$SERVER_NAME"
    echo ""
    printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
    echo ""

    read -rp "Enter the server's public IPv4 address: " SERVER_IP

    if [[ -z "$SERVER_IP" ]]; then
        err "No IP address provided."
        exit 1
    fi
fi

# ─── Write SSH config entry ──────────────────────────────────────────

SSH_CONFIG="$HOME/.ssh/config"
SSH_ENTRY="Host ${SSH_CONFIG_HOST}
    HostName ${SERVER_IP}
    User root
    IdentityFile ${SSH_KEY_PATH}
    ServerAliveInterval 60"

echo ""
if grep -q "Host ${SSH_CONFIG_HOST}" "$SSH_CONFIG" 2>/dev/null; then
    printf "${YELLOW}SSH config entry '${SSH_CONFIG_HOST}' already exists in %s.${NC}\n" "$SSH_CONFIG"
    echo "  The HostName will be updated to ${SERVER_IP}."
    echo ""
    ask UPDATE_SSH "Update the SSH config entry? (y/n): " "y"

    if [[ "$UPDATE_SSH" =~ ^[Yy] ]]; then
        awk -v host="$SSH_CONFIG_HOST" -v ip="$SERVER_IP" '
            $1 == "Host" && $2 == host { found=1 }
            found && /HostName/ { sub(/HostName .*/, "HostName " ip); found=0 }
            { print }
        ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        ok "SSH config updated"
    else
        warn "Skipped SSH config update. You'll need to configure SSH access manually."
    fi
else
    echo "  This will add the following to $SSH_CONFIG:"
    echo ""
    printf "    ${CYAN}%s${NC}\n" "$SSH_ENTRY" | head -1
    echo "$SSH_ENTRY" | tail -n +2 | while IFS= read -r line; do
        printf "    ${CYAN}%s${NC}\n" "$line"
    done
    echo ""
    ask ADD_SSH "Add this entry to your SSH config? (y/n): " "y"

    if [[ "$ADD_SSH" =~ ^[Yy] ]]; then
        echo "" >> "$SSH_CONFIG"
        echo "$SSH_ENTRY" >> "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        ok "SSH config entry added"
    else
        warn "Skipped SSH config. You can connect manually with:"
        printf "  ${CYAN}ssh -i %s root@%s${NC}\n" "$SSH_KEY_PATH" "$SERVER_IP"
    fi
fi

# ─── Clean up stale host keys ─────────────────────────────────────────

# When re-provisioning, the new server has a different host key. SSH will
# refuse to connect (REMOTE HOST IDENTIFICATION HAS CHANGED) unless the
# old entry is removed from known_hosts.
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if [[ -f "$KNOWN_HOSTS" ]] && grep -q "$SERVER_IP" "$KNOWN_HOSTS" 2>/dev/null; then
    echo ""
    warn "Found an existing known_hosts entry for ${SERVER_IP}."
    echo "  This is normal when re-provisioning — the new server has a different host key."
    echo "  The old entry must be removed or SSH will refuse to connect."
    echo ""
    ask REMOVE_KEY "Remove the old host key for ${SERVER_IP}? (y/n): " "y"

    if [[ "$REMOVE_KEY" =~ ^[Yy] ]]; then
        ssh-keygen -R "$SERVER_IP" &>/dev/null || true
        ok "Old host key removed"
    else
        warn "Skipped. You may see a 'REMOTE HOST IDENTIFICATION HAS CHANGED' error."
        warn "Fix it manually with: ssh-keygen -R $SERVER_IP"
    fi
fi

# ─── Wait for server to be reachable ──────────────────────────────────

echo ""
info "Waiting for SSH to be reachable at ${SERVER_IP}..."
ATTEMPTS=0
MAX_ATTEMPTS=30
while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$SSH_KEY_PATH" "root@${SERVER_IP}" "echo ok" &>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
        err "Could not connect to ${SERVER_IP} after ${MAX_ATTEMPTS} attempts."
        err "Check that the server is running and the firewall allows SSH."
        exit 1
    fi
    printf "."
    sleep 5
done
echo ""
ok "Server is reachable"

# ─── Copy setup.sh to server ─────────────────────────────────────────

info "Copying setup.sh to server..."
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$SSH_KEY_PATH" "$SETUP_SCRIPT" "root@${SERVER_IP}:~/setup.sh"
ok "setup.sh copied to server"

# ─── Done ─────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
printf "${GREEN}  Provisioning complete!${NC}\n"
printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
echo ""
echo "  Server IP:  ${SERVER_IP}"
echo "  SSH alias:  ${SSH_CONFIG_HOST}"
echo ""
echo "  Next steps:"
echo ""
echo "    1. SSH into the server:"
printf "       ${CYAN}ssh %s${NC}\n" "$SSH_CONFIG_HOST"
echo ""
echo "    2. Run the setup script:"
printf "       ${CYAN}bash setup.sh${NC}\n"
echo ""
echo "    3. After setup completes, update your SSH config"
echo "       to use your new username instead of root."
echo ""
