#!/usr/bin/env bash
#
# review-install.sh — Run on the TestFlight Review Server, as the non-root user
# setup.sh created, after `bash setup.sh --review`.
#
# This script:
#   0. Refuses to continue if the box holds a GitHub login, a git credential,
#      or any coding agent but OpenCode: the reviewer's sessions run here
#   1. Installs OpenCode, the one agent the reviewer may use
#   2. Installs the Firehose release (no source checkout), without starting it
#   3. Creates the review fixture project the reviewer's sessions run in
#   4. Writes the review settings into ~/.firehose/config.env
#   5. Registers Firehose to start at boot and starts it
#   6. Prints the two manual steps: activating under the review account and
#      turning public access on
#
# Optional env vars:
#   FIREHOSE_ARCHIVE   — a local release archive to install instead of the latest
#                        release, e.g. one built from a branch not released yet;
#                        installed over an existing install, so a re-run updates
#   REVIEW_MODEL       — the OpenCode model id the reviewer gets; must be a
#                        zero-cost model (default: read from `opencode models`,
#                        refusing to guess)
#   REVIEW_FIXTURE_REPO — a git URL for the fixture project (default: an empty
#                        starter project created here)
#
# Designed to be idempotent — safe to re-run after a failure.
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
info() { printf "${CYAN}==> %s${NC}\n" "$*"; }
ok()   { printf "${GREEN}==> %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}==> %s${NC}\n" "$*"; }
err()  { printf "${RED}==> %s${NC}\n" "$*" >&2; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    err "Run this as the non-root user setup.sh created, not as root."
    exit 1
fi

FIREHOSE_HOME="${FIREHOSE_INSTALL_DIR:-$HOME/.firehose}"
FIREHOSE_BIN="$HOME/.local/bin/firehose"
REVIEW_ROOT="$HOME/review"
FIXTURE_DIR="$REVIEW_ROOT/fixture"
CONFIG_ENV="$FIREHOSE_HOME/config.env"
BLOCK_BEGIN='# >>> firehose review server >>>'
BLOCK_END='# <<< firehose review server <<<'

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"

# ─── 0. Nothing the reviewer must not reach ───────────────────────────

# Review mode locks OpenCode's tools, but the box itself is the last line: it
# must hold nothing that would let a session reach the operator's code or a
# billable agent. setup.sh --review installs none of these; a box set up
# another way has to be cleaned first.
refusals=()
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    refusals+=("GitHub is signed in for $USER (gh auth logout)")
fi
[[ -s "$HOME/.config/gh/hosts.yml" ]] && refusals+=("~/.config/gh/hosts.yml holds a GitHub login (gh auth logout)")
[[ -s "$HOME/.git-credentials" ]] && refusals+=("~/.git-credentials holds a stored git credential (remove it)")
if git config --global --get-all credential.helper &>/dev/null; then
    refusals+=("git has a credential helper configured (git config --global --unset-all credential.helper)")
fi
for bin in claude codex gemini grok kimi kiro-cli pi; do
    command -v "$bin" &>/dev/null && refusals+=("$bin is installed ($(command -v "$bin")); a review box runs OpenCode only")
done
for path in .claude .codex .gemini .grok .kimi .kiro .pi; do
    [[ -e "$HOME/$path" ]] && refusals+=("~/$path exists (an agent's settings or login); remove it")
done
if (( ${#refusals[@]} > 0 )); then
    err "This box holds credentials or agents the reviewer's sessions must not reach:"
    for refusal in "${refusals[@]}"; do err "  - $refusal"; done
    err "Remove them (setup.sh --review installs none of them) and re-run."
    exit 1
fi
ok "No GitHub login, git credential, or other coding agent on this box"

# ─── 1. OpenCode ──────────────────────────────────────────────────────

if command -v opencode &>/dev/null; then
    ok "OpenCode already installed ($(opencode --version 2>/dev/null || echo unknown))"
else
    command -v npm &>/dev/null || { err "npm not found; run setup.sh --no-app first."; exit 1; }
    info "Installing OpenCode..."
    npm install -g opencode-ai
    ok "OpenCode installed"
fi

# The reviewer may only use a model that costs nothing. Never guess one: free
# models and their quotas change, so the choice is revalidated on every install.
CURRENT_MODEL=$(grep -s '^CM_REVIEW_MODEL=' "$CONFIG_ENV" | tail -1 | cut -d= -f2- || true)
if [[ -z "${REVIEW_MODEL:-}" ]]; then
    echo ""
    info "Models OpenCode offers here (pick one that is free):"
    opencode models 2>/dev/null | grep -i -- "free" || warn "No model id contains \"free\"; check OpenCode's model list."
    echo ""
    if [[ -n "$CURRENT_MODEL" ]]; then
        read -rp "Review model id [$CURRENT_MODEL]: " REVIEW_MODEL
        REVIEW_MODEL="${REVIEW_MODEL:-$CURRENT_MODEL}"
    else
        read -rp "Review model id (e.g. opencode/<model>-free): " REVIEW_MODEL
    fi
fi
[[ -n "$REVIEW_MODEL" ]] || { err "A review model is required."; exit 1; }
if ! opencode models 2>/dev/null | grep -qxF -- "$REVIEW_MODEL"; then
    err "OpenCode does not list $REVIEW_MODEL on this machine."
    exit 1
fi
ok "Review model: $REVIEW_MODEL"

# No paid provider may be reachable from this box: a free model that runs out
# of quota must fail, not fall back to something billable. Free OpenCode
# models need no login, so any stored OpenCode credential is refused, and so
# is any key-like variable wherever the Firehose service could get one: this
# shell, the shell profiles, systemd's user environment, and config.env,
# which the server loads and its agents inherit.
OPENCODE_AUTH="$HOME/.local/share/opencode/auth.json"
if [[ -s "$OPENCODE_AUTH" ]] && [[ "$(tr -d ' \n\t' < "$OPENCODE_AUTH")" != "{}" ]]; then
    err "OpenCode has stored provider credentials in ~/.local/share/opencode/auth.json."
    err "A review box uses free models, which need none: run \`opencode auth logout\` for each, then re-run."
    exit 1
fi
KEY_PATTERN='^(export[[:space:]]+)?[A-Z0-9_]*(API_KEY|_TOKEN|ACCESS_KEY_ID|SECRET_ACCESS_KEY|_AUTH_KEY)='
found_keys=$(
    {
        env
        cat "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$CONFIG_ENV" 2>/dev/null || true
        cat "$HOME"/.config/environment.d/*.conf 2>/dev/null || true
        systemctl --user show-environment 2>/dev/null || true
    } | { grep -E "$KEY_PATTERN" || true; } | sed -E 's/^export[[:space:]]+//; s/=.*//' | sort -u | tr '\n' ' '
)
if [[ -n "$found_keys" ]]; then
    err "Key-like variables are set where Firehose or its agents could read them: $found_keys"
    err "A review box must hold no provider key or token. Remove them (shell profiles,"
    err "~/.config/environment.d, config.env, \`systemctl --user unset-environment\`) and re-run."
    exit 1
fi

# ─── 2. Firehose release ──────────────────────────────────────────────

# A given archive is installed even over an existing install, so a re-run with
# a new FIREHOSE_ARCHIVE updates the box; without one, an install is kept.
if [[ -x "$FIREHOSE_BIN" && -z "${FIREHOSE_ARCHIVE:-}" ]]; then
    ok "Firehose already installed ($("$FIREHOSE_BIN" version 2>/dev/null || echo unknown))"
else
    info "Installing the Firehose release..."
    INSTALL_ARGS=(--no-start --no-browser --accept-eula)
    [[ -n "${FIREHOSE_ARCHIVE:-}" ]] && INSTALL_ARGS+=(--archive "$FIREHOSE_ARCHIVE")
    curl -fsSL https://okthink.ai/install.sh | bash -s -- "${INSTALL_ARGS[@]}"
    ok "Firehose installed"
fi
if ! "$FIREHOSE_BIN" help 2>/dev/null | grep -q "public on|off|status"; then
    err "This Firehose release has no public access (firehose public). Install a release"
    err "that includes it, or pass FIREHOSE_ARCHIVE=<archive built from that branch>."
    exit 1
fi

# ─── 3. Fixture project ───────────────────────────────────────────────

mkdir -p "$REVIEW_ROOT"
if [[ -d "$FIXTURE_DIR/.git" ]]; then
    ok "Fixture project already at $FIXTURE_DIR"
elif [[ -n "${REVIEW_FIXTURE_REPO:-}" ]]; then
    info "Cloning the fixture project..."
    git clone "$REVIEW_FIXTURE_REPO" "$FIXTURE_DIR"
else
    info "Creating a starter fixture project..."
    mkdir -p "$FIXTURE_DIR"
    cat > "$FIXTURE_DIR/README.md" <<'README'
# Review project

A small project for trying Firehose. Ask the agent to add a feature, explain
the code, or write a test.
README
    cat > "$FIXTURE_DIR/todo.js" <<'JS'
// A tiny to-do list kept in memory.
const items = []

export function add(text) {
  items.push({ text, done: false })
  return items.length
}

export function complete(index) {
  items[index].done = true
}

export function list() {
  return items.map((item, i) => `${i + 1}. [${item.done ? 'x' : ' '}] ${item.text}`)
}
JS
    git -C "$FIXTURE_DIR" init -q
    git -C "$FIXTURE_DIR" add README.md todo.js
    git -C "$FIXTURE_DIR" -c user.name="Firehose Review" -c user.email="review@okthink.ai" commit -qm "Start the review project"
fi
# The known-good state a reset returns to: set once. A re-run keeps it, so
# whatever a session left in the fixture never becomes the baseline; move it
# on purpose with `review-server.sh snapshot`.
if git -C "$FIXTURE_DIR" rev-parse -q --verify refs/tags/review-baseline >/dev/null; then
    ok "Fixture project ready (keeping baseline $(git -C "$FIXTURE_DIR" rev-parse --short review-baseline))"
else
    git -C "$FIXTURE_DIR" tag review-baseline
    ok "Fixture project ready (baseline $(git -C "$FIXTURE_DIR" rev-parse --short review-baseline))"
fi

# ─── 4. Review settings ───────────────────────────────────────────────

touch "$CONFIG_ENV"
chmod 600 "$CONFIG_ENV"
# Replace the block, keeping every other setting (the public access block among them).
awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip
' "$CONFIG_ENV" > "$CONFIG_ENV.tmp"
{
    cat "$CONFIG_ENV.tmp"
    echo "$BLOCK_BEGIN"
    echo "CM_REVIEW_MODE=1"
    echo "CM_REVIEW_PROVIDER=opencode"
    echo "CM_REVIEW_MODEL=$REVIEW_MODEL"
    echo "CM_REVIEW_PROJECT=$FIXTURE_DIR"
    echo "CODE_DIRS=$REVIEW_ROOT"
    echo "$BLOCK_END"
} > "$CONFIG_ENV"
rm -f "$CONFIG_ENV.tmp"
ok "Review settings written to $CONFIG_ENV"

# ─── 5. Start at boot ─────────────────────────────────────────────────

# Registers the systemd user service and turns on lingering, so it runs at
# boot without anyone logged in.
"$FIREHOSE_BIN" service install
ok "Firehose starts at boot"
# A running server read its settings at start; a re-run that changed them
# (the model, for one) takes effect only after a restart.
if systemctl --user is-active --quiet firehose.service; then
    systemctl --user restart firehose.service
    ok "Firehose restarted with the new settings"
fi

# Git ignores a repository it finds by walking up unless it is a .git folder,
# so a folder a session writes in the fixture (HEAD, config, objects, refs)
# cannot make git run that config's hooks or fsmonitor. Firehose sets this
# for the git it runs in review mode; this covers git run any other way.
git config --global safe.bareRepository explicit
ok "Git refuses repositories it was not pointed at"

# `firehose public on` runs Funnel as this user, which Tailscale allows only
# its operator.
sudo tailscale set --operator="$USER"
ok "Tailscale lets $USER publish with Funnel"

# ─── 6. Manual steps ──────────────────────────────────────────────────

echo ""
printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
printf "${GREEN}  Review Server installed. Two steps remain:${NC}\n"
printf "${BOLD}────────────────────────────────────────────────────${NC}\n"
echo ""
echo "  1. Activate Firehose under the review account. From your laptop:"
printf "       ${CYAN}ssh -L 4801:127.0.0.1:4801 firehose-review${NC}\n"
echo "     then open http://localhost:4801 and sign in with the review account."
echo ""
echo "  2. Turn public access on, here:"
printf "       ${CYAN}%s public on${NC}\n" "$FIREHOSE_BIN"
echo ""
echo "  Afterwards, from your laptop: bash review-server.sh check"
echo ""
