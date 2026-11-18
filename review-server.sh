#!/usr/bin/env bash
#
# review-server.sh — Run on your laptop to operate the TestFlight Review Server
# that `provision.sh --review` created and review-install.sh set up.
#
# Usage: bash review-server.sh <command>
#   start     Power the server on, publish its public address, and check it
#   stop      Withdraw the public address, then power the server off
#   status    Show whether the server is on and its address answers
#   check     Check the public address from here: the health route answers and
#             everything else refuses a caller without an access token
#   snapshot  Save the current review state (database and fixture) as the
#             known-good baseline that reset returns to
#   reset     Return the review state to the saved baseline
#
# Uses the hcloud context provision.sh saved (or HCLOUD_TOKEN) and the SSH
# alias it wrote. Every command is safe to repeat.
#
# Hetzner bills a server while it exists, powered on or off; stop removes the
# public address and the compute load, not the monthly charge. Delete the
# server in the Hetzner Console to stop paying for it.
#
set -euo pipefail

SERVER_NAME="${REVIEW_SERVER_NAME:-firehose-review}"
SSH_HOST="${REVIEW_SSH_HOST:-firehose-review}"
REMOTE_FIREHOSE='~/.local/bin/firehose'
BASELINE_DIR='~/review/baseline'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { printf "${CYAN}==> %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}==> %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}==> %s${NC}\n" "$*"; }
err()  { printf "${RED}==> %s${NC}\n" "$*" >&2; }

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

need() { command -v "$1" &>/dev/null || { err "$1 is required; provision.sh installs it."; exit 1; }; }

remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" "$@"; }

server_status() { hcloud server describe "$SERVER_NAME" -o json 2>/dev/null | jq -r '.status // "missing"'; }

wait_for_ssh() {
    info "Waiting for SSH..."
    for _ in $(seq 1 60); do
        remote true 2>/dev/null && { ok "SSH is up"; return 0; }
        sleep 5
    done
    err "SSH did not come up within five minutes."
    exit 1
}

# The machine's public origin, from its own Tailscale status.
public_origin() {
    local dns
    dns=$(remote "tailscale status --json" | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
    [[ -n "$dns" ]] || { err "The server is not on the tailnet; run tailscale up there."; exit 1; }
    echo "https://$dns"
}

# Checks the address from outside: health answers, and a caller without a
# token gets no data from a route, the web app, or the WebSocket.
check_public() {
    local origin="$1" body code failed=0
    body=$(curl -fsS -m 15 "$origin/healthz" 2>/dev/null || true)
    if [[ "$(jq -r '.service // empty' <<<"$body" 2>/dev/null)" == "firehose-public-gateway" ]]; then
        ok "Health check answers at $origin"
    else
        err "Health check failed at $origin/healthz"
        failed=1
    fi
    for path in /api/sessions /api/status /api/terminal-token /; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$origin$path" || echo 000)
        if [[ "$code" == "401" ]]; then
            ok "Without a token, $path is refused (401)"
        else
            err "Without a token, $path answered $code, not 401"
            failed=1
        fi
    done
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: firehose.v1' \
        "$origin/ws" || echo 000)
    if [[ "$code" == "401" ]]; then
        ok "Without a token, the WebSocket is refused (401)"
    else
        err "Without a token, the WebSocket answered $code, not 401"
        failed=1
    fi
    return "$failed"
}

cmd_start() {
    need hcloud; need jq
    local status
    status=$(server_status)
    [[ "$status" == "missing" ]] && { err "No server named $SERVER_NAME; run provision.sh --review first."; exit 1; }
    if [[ "$status" != "running" ]]; then
        info "Powering on $SERVER_NAME..."
        hcloud server poweron "$SERVER_NAME" >/dev/null
    fi
    wait_for_ssh
    info "Publishing the public address..."
    remote "$REMOTE_FIREHOSE public on"
    local origin
    origin=$(public_origin)
    info "Waiting for $origin to answer..."
    for _ in $(seq 1 36); do
        curl -fsS -m 10 "$origin/healthz" &>/dev/null && break
        sleep 5
    done
    check_public "$origin" && ok "Review Server is on at $origin"
}

cmd_stop() {
    need hcloud; need jq
    local status
    status=$(server_status)
    if [[ "$status" == "running" ]]; then
        # First, so the address stops answering and the license service stops
        # issuing access tokens even if the shutdown hangs.
        info "Withdrawing the public address..."
        remote "$REMOTE_FIREHOSE public off" || warn "Could not reach the server to withdraw the address; Funnel ends with the shutdown."
        info "Shutting $SERVER_NAME down..."
        hcloud server shutdown "$SERVER_NAME" >/dev/null
        for _ in $(seq 1 36); do
            [[ "$(server_status)" == "off" ]] && break
            sleep 5
        done
        [[ "$(server_status)" == "off" ]] || { warn "Graceful shutdown timed out; powering off."; hcloud server poweroff "$SERVER_NAME" >/dev/null; }
    fi
    ok "Review Server is off (Hetzner still bills a stopped server; see the header of this script)."
}

cmd_status() {
    need hcloud; need jq
    local status
    status=$(server_status)
    echo "Server:  $SERVER_NAME ($status)"
    [[ "$status" == "running" ]] || return 0
    echo "Firehose: $(remote "$REMOTE_FIREHOSE version" 2>/dev/null || echo unreachable)"
    echo "Public:   $(remote "$REMOTE_FIREHOSE public status" 2>/dev/null || echo unreachable)"
    echo "License:  $(remote "$REMOTE_FIREHOSE license status" 2>/dev/null | head -1 || echo unreachable)"
}

cmd_check() {
    need jq
    check_public "$(public_origin)"
}

# Firehose is stopped while the database is copied, so the copy is consistent.
cmd_snapshot() {
    info "Saving the current review state as the baseline..."
    remote "set -e
        mkdir -p $BASELINE_DIR
        systemctl --user stop firehose.service
        cp ~/.firehose/data/agent-manager.db $BASELINE_DIR/agent-manager.db
        git -C ~/review/fixture tag -f review-baseline >/dev/null
        systemctl --user start firehose.service"
    ok "Baseline saved"
}

cmd_reset() {
    info "Returning the review state to the baseline..."
    remote "set -e
        test -f $BASELINE_DIR/agent-manager.db || { echo 'No baseline; run review-server.sh snapshot first.' >&2; exit 1; }
        systemctl --user stop firehose.service
        tmux kill-server 2>/dev/null || true
        cp $BASELINE_DIR/agent-manager.db ~/.firehose/data/agent-manager.db
        rm -f ~/.firehose/data/agent-manager.db-wal ~/.firehose/data/agent-manager.db-shm
        git -C ~/review/fixture reset -q --hard review-baseline
        git -C ~/review/fixture clean -qfdx
        systemctl --user start firehose.service"
    ok "Review state reset"
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    check) cmd_check ;;
    snapshot) cmd_snapshot ;;
    reset) cmd_reset ;;
    -h|--help|help|"") usage ;;
    *) err "Unknown command: $1"; usage >&2; exit 1 ;;
esac
