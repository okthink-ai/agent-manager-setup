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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup.sh"

SSH_KEY_PATH="$HOME/.ssh/agent_manager"
SSH_CONFIG_HOST="agent-manager-vps"
SERVER_NAME="agent-manager"
FIREWALL_NAME="agent-manager-firewall"
SERVER_TYPE="cpx31"
IMAGE="ubuntu-24.04"

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

# ─── Pre-flight checks ───────────────────────────────────────────────

if [[ ! -f "$SETUP_SCRIPT" ]]; then
    err "Cannot find setup.sh at $SETUP_SCRIPT"
    err "Make sure provision.sh and setup.sh are in the same directory."
    exit 1
fi

# ─── SSH key ──────────────────────────────────────────────────────────

if [[ -f "$SSH_KEY_PATH" ]]; then
    ok "SSH key already exists at $SSH_KEY_PATH"
else
    # Check if the user wants to reuse an existing key
    echo "No SSH key found at $SSH_KEY_PATH."
    echo ""
    echo "  You can either:"
    echo "    1) Generate a new key (recommended)"
    echo "    2) Use an existing SSH key"
    echo ""
    read -rp "Generate a new key? (y/n): " GEN_KEY

    if [[ "$GEN_KEY" =~ ^[Yy] ]]; then
        info "Generating SSH key at $SSH_KEY_PATH"
        ssh-keygen -t ed25519 -C "agent-manager-vps" -f "$SSH_KEY_PATH"
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

SSH_PUBKEY=$(cat "${SSH_KEY_PATH}.pub")
echo ""

# ─── Hetzner provisioning path ────────────────────────────────────────

printf "${BOLD}Do you want to create the server automatically via the Hetzner API?${NC}\n"
echo "  If yes, this script will install the CLI (if needed), walk you through"
echo "  getting an API token, and create the firewall + server for you."
echo "  If no, it will print a checklist for the Hetzner Console."
echo ""
read -rp "Use Hetzner API? (y/n): " USE_API
echo ""

if [[ "$USE_API" =~ ^[Yy] ]]; then
    # ── Automated path via hcloud CLI ──
    # Doctor-style checks: CLI installed? → Token available? → Token valid?

    # Step 1: hcloud CLI
    if command -v hcloud &>/dev/null; then
        ok "hcloud CLI found: $(hcloud version 2>/dev/null || echo 'unknown version')"
    else
        info "hcloud CLI not found — installing..."
        if [[ "$(uname)" == "Darwin" ]]; then
            if command -v brew &>/dev/null; then
                brew install hcloud
            else
                err "Install Homebrew first (https://brew.sh), then re-run this script."
                exit 1
            fi
        elif [[ "$(uname)" == "Linux" ]]; then
            HCLOUD_VERSION=$(curl -s https://api.github.com/repos/hetznercloud/cli/releases/latest | grep tag_name | cut -d '"' -f 4)
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64)  HCLOUD_ARCH="linux-amd64" ;;
                aarch64) HCLOUD_ARCH="linux-arm64" ;;
                *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
            esac
            curl -sL "https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}/hcloud-${HCLOUD_ARCH}.tar.gz" | tar xz -C /tmp
            HCLOUD_BIN=$(find /tmp -name 'hcloud' -type f -perm -u+x 2>/dev/null | head -1)
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
    fi

    # Step 2: API token via hcloud context (persisted to ~/.config/hcloud/cli.toml)
    HCLOUD_CONTEXT="agent-manager"

    if hcloud server-type list &>/dev/null 2>&1; then
        ok "Hetzner API is reachable (active context: $(hcloud context active 2>/dev/null || echo 'env'))"
    else
        echo ""
        printf "${BOLD}Setting up Hetzner API access${NC}\n"
        echo ""
        echo "  You need an API token scoped to a Hetzner Cloud project."
        echo "  Each token belongs to one project — if you don't have a"
        echo "  project yet, create one first."
        echo ""
        printf "  ${CYAN}Step 1:${NC} Go to https://console.hetzner.cloud\n"
        printf "  ${CYAN}Step 2:${NC} Create a project (if you don't have one)\n"
        echo "         Click '+ New Project', name it (e.g. 'agent-manager')"
        printf "  ${CYAN}Step 3:${NC} Inside your project: Security → API Tokens → Generate API Token\n"
        echo "         Set permissions to Read & Write"
        echo "         Copy the token — you only see it once"
        echo ""

        while true; do
            read -rsp "Paste your Hetzner API token (input is hidden): " HCLOUD_TOKEN
            echo ""
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

    # Create server — skip location prompt if server already exists
    if hcloud server describe "$SERVER_NAME" &>/dev/null; then
        ok "Server '$SERVER_NAME' already exists"
        SERVER_IP=$(hcloud server ip "$SERVER_NAME")
    else
        # Pick location — only show regions where the server type is actually available
        # (not just priced). The location_available column reflects real-time availability.
        echo ""
        info "Finding available locations for $SERVER_TYPE..."
        hcloud server-type list -o noheader -o columns=name,location,location_available \
            | awk -v type="$SERVER_TYPE" '$1 == type && $3 == "true" { print $2 }' \
            > /tmp/hcloud-available-locations.txt

        AVAILABLE_LOCATIONS=$(cat /tmp/hcloud-available-locations.txt)
        if [[ -z "$AVAILABLE_LOCATIONS" ]]; then
            err "No locations found where $SERVER_TYPE is available."
            err "Check https://console.hetzner.cloud for current availability."
            exit 1
        fi

        # Detect the user's approximate location to suggest the closest datacenter
        SUGGESTED=""
        USER_LON=""
        USER_LAT=""
        GEO_INFO=$(curl -s --max-time 5 https://ipinfo.io/json 2>/dev/null || true)
        if [[ -n "$GEO_INFO" ]]; then
            USER_LOC=$(echo "$GEO_INFO" | jq -r '.loc // empty' 2>/dev/null)
            USER_CITY=$(echo "$GEO_INFO" | jq -r '.city // empty' 2>/dev/null)
            USER_COUNTRY=$(echo "$GEO_INFO" | jq -r '.country // empty' 2>/dev/null)
            if [[ -n "$USER_LOC" ]]; then
                USER_LAT=$(echo "$USER_LOC" | cut -d, -f1)
                USER_LON=$(echo "$USER_LOC" | cut -d, -f2)
                info "Detected your location: ${USER_CITY:-unknown}, ${USER_COUNTRY:-unknown}"
            fi
        fi

        # Build location list with distances
        echo ""
        printf "  %-8s  %-20s  %s\n" "NAME" "CITY" ""
        printf "  %-8s  %-20s  %s\n" "----" "----" ""
        BEST_DIST=999999
        for loc in $AVAILABLE_LOCATIONS; do
            LOC_JSON=$(hcloud location describe "$loc" -o json 2>/dev/null)
            CITY=$(echo "$LOC_JSON" | jq -r '.city // "unknown"')
            MARKER=""

            # Calculate rough distance if we have user coordinates
            if [[ -n "$USER_LAT" && -n "$USER_LON" ]]; then
                LOC_LAT=$(echo "$LOC_JSON" | jq -r '.latitude // empty')
                LOC_LON=$(echo "$LOC_JSON" | jq -r '.longitude // empty')
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

        while true; do
            echo ""
            read -rp "$PROMPT: " LOCATION

            # Default to suggested if user just presses Enter
            if [[ -z "$LOCATION" && -n "$SUGGESTED" ]]; then
                LOCATION="$SUGGESTED"
                ok "Using suggested location: $LOCATION"
            fi

            if echo "$AVAILABLE_LOCATIONS" | grep -qw "$LOCATION"; then
                break
            fi

            err "'$LOCATION' is not available for $SERVER_TYPE. Pick one from the list above."
        done
        rm -f /tmp/hcloud-available-locations.txt

        info "Creating server '$SERVER_NAME' ($SERVER_TYPE in $LOCATION)..."
        hcloud server create \
            --name "$SERVER_NAME" \
            --type "$SERVER_TYPE" \
            --image "$IMAGE" \
            --location "$LOCATION" \
            --ssh-key "$SSH_KEY_NAME"

        SERVER_IP=$(hcloud server ip "$SERVER_NAME")
        ok "Server created: $SERVER_IP"
    fi

    # Attach firewall (idempotent — works whether the server was just created or already existed)
    info "Attaching firewall to server..."
    hcloud firewall apply-to-resource "$FIREWALL_NAME" --type server --server "$SERVER_NAME" 2>/dev/null || true
    ok "Firewall attached to server"

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
    echo "   - Type: CPX31 (4 vCPU, 8 GB RAM, 160 GB SSD)"
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
    read -rp "Update the SSH config entry? (y/n): " UPDATE_SSH

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
    read -rp "Add this entry to your SSH config? (y/n): " ADD_SSH

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
    read -rp "Remove the old host key for ${SERVER_IP}? (y/n): " REMOVE_KEY

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
