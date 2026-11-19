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
#   seed      Give the reviewer something to open: the Hello Firehose project
#             and one finished session in it. Look at the result in the app,
#             then run snapshot to keep it
#   snapshot  Save the current review state (Firehose's data, OpenCode's data,
#             the fixture) as the known-good baseline that reset returns to
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
BASELINE_DIR='$HOME/review/baseline'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { printf "${CYAN}==> %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}==> %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}==> %s${NC}\n" "$*"; }
err()  { printf "${RED}==> %s${NC}\n" "$*" >&2; }

usage() { sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; }

need() { command -v "$1" &>/dev/null || { err "$1 is required; provision.sh installs it."; exit 1; }; }

remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" "$@"; }

# The server's status, "missing" when Hetzner has no server by that name. Any
# other hcloud failure (a bad token, no network) stops the script with its
# message instead of reading as a missing server.
server_status() {
    local out
    if out=$(hcloud server describe "$SERVER_NAME" -o json 2>&1); then
        jq -r '.status // "unknown"' <<<"$out"
    elif grep -qi "not found" <<<"$out"; then
        echo missing
    else
        err "hcloud could not describe $SERVER_NAME: $out"
        exit 1
    fi
}

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

# The review state is everything a session can change: Firehose's data
# directory (database, uploads, attachments), OpenCode's data (its sessions
# and snapshots), and the fixture project. Firehose is stopped while it is
# copied, so the copy is consistent (stopping the service also ends its agent
# daemon and OpenCode processes), and started again however the copy ends.
# OpenCode's data holds no login on a review box (review-install.sh refuses
# one), so it is copied whole.
STATE_DIRS='$HOME/.firehose/data $HOME/.local/share/opencode'

cmd_snapshot() {
    info "Saving the current review state as the baseline..."
    remote "set -e
        trap 'systemctl --user start firehose.service' EXIT
        systemctl --user stop firehose.service
        rm -rf $BASELINE_DIR.new && mkdir -p $BASELINE_DIR.new
        for dir in $STATE_DIRS; do
            [ -d \"\$dir\" ] || continue
            mkdir -p \"$BASELINE_DIR.new/\$(basename \"\$dir\")\"
            cp -a \"\$dir/.\" \"$BASELINE_DIR.new/\$(basename \"\$dir\")/\"
        done
        rm -rf $BASELINE_DIR && mv $BASELINE_DIR.new $BASELINE_DIR
        git -C ~/review/fixture tag -f review-baseline >/dev/null"
    ok "Baseline saved"
}

cmd_reset() {
    info "Returning the review state to the baseline..."
    remote "set -e
        test -d $BASELINE_DIR/data || { echo 'No baseline; run review-server.sh snapshot first.' >&2; exit 1; }
        trap 'systemctl --user start firehose.service' EXIT
        systemctl --user stop firehose.service
        tmux kill-server 2>/dev/null || true
        for dir in $STATE_DIRS; do
            name=\$(basename \"\$dir\")
            [ -d \"$BASELINE_DIR/\$name\" ] || continue
            rm -rf \"\$dir\" && mkdir -p \"\$dir\"
            cp -a \"$BASELINE_DIR/\$name/.\" \"\$dir/\"
        done
        git -C ~/review/fixture reset -q --hard review-baseline
        git -C ~/review/fixture clean -qffdx
        rm -rf /tmp/opencode 2>/dev/null || true"
    ok "Review state reset"
}

# The first thing the reviewer sees should not be an empty list. This makes
# the fixture the Hello Firehose project and starts one session in it through
# the box's own Firehose, so the stored session is a real one with a real
# reply from the review model. It counts as one of the day's starts and
# prompts; snapshot keeps those counts with the session.
#
# It does not snapshot: read the reply in the app first, since a free model's
# answer is not guaranteed to be worth showing.
SEED_PROMPT='Read README.md and todo.js. In a few sentences, say what this project does, then suggest one small improvement I could ask you to make.'

# What seed runs on the box. Kept out of cmd_seed's command substitution: an
# older bash cannot read a here-document with apostrophes inside one.
seed_script() {
    cat <<'REMOTE'
set -euo pipefail
fixture="$HOME/review/fixture"
config="$HOME/.firehose/config.env"
[ -d "$fixture/.git" ] || { echo "No fixture project at $fixture; run review-install.sh first." >&2; exit 1; }
model=$(grep -s '^CM_REVIEW_MODEL=' "$config" | tail -1 | cut -d= -f2-)
[ -n "$model" ] || { echo "CM_REVIEW_MODEL is not set in $config; run review-install.sh first." >&2; exit 1; }

# An older box has the plain starter README. The same text as review-install.sh.
if ! grep -q '^# Hello Firehose' "$fixture/README.md" 2>/dev/null; then
    cat > "$fixture/README.md" <<'README'
# Hello Firehose

A small project for trying Firehose. Firehose runs a coding agent on a server
and lets you work with it from your phone. This project is that server's
sandbox: a tiny to-do list in `todo.js`.

Start a session, or open the one already here, and ask the agent something:

- Explain what this project does.
- Add a `remove` function to `todo.js`.
- Write a test for `complete`.
- What would break if `complete` got an index that does not exist?

The agent can read and edit the files here. It cannot run shell commands.
README
    git -C "$fixture" add README.md
    git -C "$fixture" -c user.name="Firehose Review" -c user.email="review@okthink.ai" \
        commit -qm "Introduce the project as Hello Firehose"
fi

# Firehose ships its own Node; a non-interactive shell has no other on PATH.
node() { "$HOME/.firehose/current/runtime/node" "$@"; }
[ -x "$HOME/.firehose/current/runtime/node" ] || { echo "Firehose's runtime is missing at ~/.firehose/current/runtime/node." >&2; exit 1; }

# The server answers on loopback over HTTPS when it holds a certificate pair.
port="${REVIEW_PORT:-4801}"
base="https://127.0.0.1:$port"
curl -sk -m 5 -o /dev/null "$base/api/status" || base="http://127.0.0.1:$port"
curl -sk -m 5 -o /dev/null "$base/api/status" || { echo "Firehose is not answering on this machine." >&2; exit 1; }

sessions=$(curl -sk -m 20 "$base/api/sessions")
existing=$(printf '%s' "$sessions" | node -e '
  let text = ""
  process.stdin.on("data", (chunk) => (text += chunk)).on("end", () => {
    const groups = JSON.parse(text)
    console.log(groups.reduce((count, group) => count + (group.sessions ?? []).length, 0))
  })')
if [ "$existing" != "0" ]; then
    echo "{\"status\":\"exists\",\"sessions\":$existing}"
    exit 0
fi

body=$(SEED_MODEL="$model" SEED_CWD="$fixture" node -e '
  console.log(JSON.stringify({
    provider: "opencode",
    model: process.env.SEED_MODEL,
    cwd: process.env.SEED_CWD,
    instructions: process.env.SEED_PROMPT,
  }))')
started=$(curl -sk -m 120 -X POST -H 'Content-Type: application/json' -d "$body" "$base/api/agent-sessions/start")
pid=$(printf '%s' "$started" | node -e '
  let text = ""
  process.stdin.on("data", (chunk) => (text += chunk)).on("end", () => {
    try { console.log(JSON.parse(text).pid ?? "") } catch { console.log("") }
  })')
[ -n "$pid" ] || { echo "The session did not start: $started" >&2; exit 1; }

# Wait for the model to finish its turn; a free model can be slow.
state=working
for _ in $(seq 1 60); do
    sleep 5
    state=$(curl -sk -m 20 "$base/api/sessions" | SEED_PID="$pid" node -e '
      let text = ""
      process.stdin.on("data", (chunk) => (text += chunk)).on("end", () => {
        const all = JSON.parse(text).flatMap((group) => group.sessions ?? [])
        const session = all.find((candidate) => String(candidate.pid) === process.env.SEED_PID)
        console.log(session ? (session.turnState ?? "unknown") : "missing")
      })')
    [ "$state" = "working" ] || break
done
echo "{\"status\":\"started\",\"pid\":\"$pid\",\"turnState\":\"$state\"}"
REMOTE
}

cmd_seed() {
    need jq
    info "Preparing the Hello Firehose project and its first session..."
    local result
    result=$(seed_script | remote "SEED_PROMPT=$(printf '%q' "$SEED_PROMPT") bash -s")
    case "$(jq -r '.status // empty' <<<"$result" 2>/dev/null)" in
        exists)
            warn "The box already has $(jq -r '.sessions' <<<"$result") session(s), so no session was added."
            warn "Run 'review-server.sh reset' first to seed from the saved baseline, or keep what is there."
            ;;
        started)
            local state
            state=$(jq -r '.turnState' <<<"$result")
            if [[ "$state" == "idle" ]]; then
                ok "Session $(jq -r '.pid' <<<"$result") started in Hello Firehose and the model has replied."
            else
                warn "Session $(jq -r '.pid' <<<"$result") started, but its turn is '$state' after five minutes."
            fi
            echo "    Open the app, read the reply, and if it is worth showing run: bash review-server.sh snapshot"
            echo "    If it is not, run: bash review-server.sh reset, then seed again."
            ;;
        *)
            err "Seeding failed: ${result:-no answer from the server}"
            exit 1
            ;;
    esac
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    check) cmd_check ;;
    seed) cmd_seed ;;
    snapshot) cmd_snapshot ;;
    reset) cmd_reset ;;
    -h|--help|help|"") usage ;;
    *) err "Unknown command: $1"; usage >&2; exit 1 ;;
esac
