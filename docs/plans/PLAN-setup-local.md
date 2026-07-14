# Plan: `ubuntu-install.sh` — Agent Manager on your own Ubuntu server

## Executive Summary

A new, self-contained script — `ubuntu-install.sh` — that installs and runs Agent
Manager on an Ubuntu server you already own and log into as a sudo user, reached
over the box's direct IP. It reuses the proven logic from `setup.sh` but removes
the fresh-VPS/root assumptions and adds the few things a box that's already in
use actually needs.

- Add a new server-side script `ubuntu-install.sh`, run as your sudo user on the box.
  - Why: `setup.sh` assumes a fresh, root-owned Hetzner VPS — it creates a
    non-root user, copies root's SSH keys, and hardens SSH, none of which fits a
    machine you already use as your own user.
  - What: a script that runs directly as the invoking user (commands run inline,
    not through `su - $NEW_USER -c "..."`), using `sudo` only for apt.

- Prompt for the install directory.
  - Why: the target box may already have a `~/dev/claude-manager`, or you may
    want Agent Manager somewhere specific; hardcoding one path is wrong here.
  - What: ask for a directory (default `~/dev/claude-manager`), expand a leading
    `~`, create it and its parent if needed, and thread the chosen path through
    every later step (clone, `npm install`, `web/.env`, build, `.server-mode`,
    the `tmux` working dir, and the final summary URL).

- Make the system-package step optional and detect correctly.
  - Why: an existing dev box usually already has these tools, and a blanket
    `apt upgrade` on a machine in active use can be disruptive.
  - What: check each of `build-essential curl wget git unzip tmux htop lsof`
    with `dpkg -s` (not `command -v`, because `build-essential` is a metapackage
    with no binary of its own), install only the missing ones after a prompt,
    and skip the step entirely — with no `apt upgrade` — when nothing is missing.

- Bind the server to `0.0.0.0` so direct-IP access works.
  - Why: with default settings the server binds to `127.0.0.1` only
    (`server/index.ts:247`: `bindHost = terminalOn && !allowLan ? '127.0.0.1'
    : '0.0.0.0'`), because the terminal is enabled by default
    (`CM_TERMINAL_ENABLED !== '0'`) and `CM_TERMINAL_ALLOW_LAN` is unset — so a
    plain launch would listen on loopback and refuse every off-box connection.
  - What: persist `CM_TERMINAL_ALLOW_LAN=1` in the repo's root `.env` (loaded
    via `import 'dotenv/config'` at `server/index.ts:1`) so every launch — even a
    UI-triggered restart through `server/daemon/restart-servers.ts`, which spawns
    without that env var — binds `0.0.0.0`; and also pass
    `CM_TERMINAL_ALLOW_LAN=1 PORT=4801` inline on the manual/`tmux` start commands
    so a launch from any directory still binds LAN on the right port. In LAN mode
    the terminal token is the access gate.

- Source NVM inside the script and fix the idempotency checks.
  - Why: after `nvm install`, the running script's shell still has no `node`
    on `PATH`; NVM only wires itself into future interactive shells via
    `~/.bashrc`. Every `node`/`npm`/`npx`/`claude` call — and the "is node
    already installed?" check — must source `$NVM_DIR/nvm.sh` first.
  - What: after installing NVM, `export NVM_DIR="$HOME/.nvm"` and source
    `$NVM_DIR/nvm.sh` once near the top, and guard the node check behind that
    source so re-runs correctly detect an existing install.

- Export `GITHUB_TOKEN` inline for `npm install`.
  - Why: the private `@okthink-ai` npm packages need `GITHUB_TOKEN` at install
    time. Appending the export to `~/.bashrc` does not affect the current
    non-interactive script shell, so relying on it would 403.
  - What: keep the `~/.bashrc` line for future logins, but also set
    `export GITHUB_TOKEN=$(gh auth token)` inline in the same command as each
    `npm install`, mirroring `setup.sh`'s retry loop.

- Do not clobber an existing `~/.claude/settings.json`.
  - Why: this is your own box — you likely already use Claude Code and have real
    settings there; overwriting them would be destructive.
  - What: only create `~/.claude/settings.json` with
    `skipDangerousModePermissionPrompt` when it does not exist; if it does, leave
    it untouched and print how to add the flag manually.

- Drop all hardening and provisioning that no longer applies.
  - Why: you asked to leave security hardening out, and you already have the box.
  - What: no non-root user creation, no SSH-key copying, no SSH hardening / sshd
    restart, no fail2ban, no Tailscale, no firewall, and no `provision.sh`
    counterpart.

- Finish with a direct-IP URL and an exposure warning.
  - Why: you reach the app by IP, and with no firewall a public IP leaves the
    port open to the internet.
  - What: print `http://<server-ip>:4801` using the box's primary IP
    (`hostname -I | awk '{print $1}'`), and print a one-line warning that on a
    public IP the port is internet-reachable (the terminal token is the only
    gate in LAN mode).

## Context / decisions locked in

- **Target:** an Ubuntu server you already own and access as a sudo user (not root).
- **Access:** direct IP (no Tailscale).
- **Security hardening:** left out entirely — no user creation, no SSH changes,
  no fail2ban, no firewall.
- **Scope:** one server-side script. No laptop-side / provisioning helper.
- **Untouched:** existing `setup.sh` and `provision.sh` stay as-is.

## What it does (in order)

1. **Preflight**
   - Confirm the OS is Ubuntu (warn, don't hard-fail, on other distros).
   - Confirm it is **not** run as root and that `sudo` is available; if `EUID -eq
     0`, error out (this script must run as your normal sudo user).
   - Prompt for git name + email.
   - Prompt for the **install directory** (default `~/dev/claude-manager`);
     expand a leading `~` to `$HOME`, and remember it as `INSTALL_DIR` for every
     later step.
   - Optional `GH_TOKEN` env var for non-interactive GitHub auth (same as today).

2. **System packages — OPTIONAL**
   - Candidate packages: `build-essential curl wget git unzip tmux htop lsof`.
   - Determine which are missing with `dpkg -s <pkg>` (handles `build-essential`,
     which has no matching binary). Only the missing ones are installed.
   - If nothing is missing, skip the step silently.
   - Otherwise prompt, then `sudo apt-get update && sudo apt-get install -y
     <missing...>`. No `apt upgrade`. `sudo` is used only here.

3. **NVM + Node.js 22** (the repo pins no `engines` or `.nvmrc`, so 22 satisfies it)
   - Source `$NVM_DIR/nvm.sh` (if present) before checking for `node`.
   - If `node` is missing, install NVM (`v0.40.1` installer), source it, then
     `nvm install 22`.
   - Leave NVM sourced in the script shell for all later `node`/`npm`/`npx` calls.

4. **GitHub CLI + auth**
   - Install `gh` only if missing: `sudo apt-get install -y gh` (present in
     Ubuntu 24.04 `universe`).
   - If `gh auth status` already succeeds, skip login; else authenticate via
     `GH_TOKEN` (temp-file `--with-token`) or the interactive `BROWSER=echo gh
     auth login -p ssh` device flow.
   - Ensure `read:packages` scope (refresh for OAuth logins; skip for token
     logins), run `gh auth setup-git`, and append
     `export GITHUB_TOKEN=$(gh auth token)` to `~/.bashrc` if not already there.
   - Configure `git config --global user.name/email` from the preflight answers
     (write to a temp script to survive apostrophes in names).

5. **Claude Code**
   - Install `@anthropic-ai/claude-code` (sourcing NVM) only if `claude` is missing.
   - Create `~/.claude/settings.json` with `skipDangerousModePermissionPrompt`
     **only if the file does not already exist**; otherwise leave it and print
     how to add the flag manually.
   - Print auth instructions (`claude --dangerously-skip-permissions`) — but no
     second-terminal/SSH copy-paste block; this runs on the box you're already on.

6. **Optional other CLIs** — Codex / Gemini / Pi prompts, reusing the
   `install_npm_cli` helper from `setup.sh` (each sources NVM before `npm -g`).

7. **Clone + build Agent Manager**
   - Clone the repo into `INSTALL_DIR` if it isn't already a checkout;
     `mkdir -p` the parent first.
   - `npm install` in `INSTALL_DIR` and `INSTALL_DIR/web`, each with
     `export GITHUB_TOKEN=$(gh auth token)` inline and the existing 403-retry loop
     (the repo's `.npmrc` points the `@okthink-ai` scope at GitHub Packages, which
     needs `GITHUB_TOKEN`).
   - Copy `.env.example` → `.env` if present and `.env` is absent.
   - Ensure the root `.env` contains `CM_TERMINAL_ALLOW_LAN=1`, appending it if
     missing (idempotent). `.env.example` doesn't include it, so a fresh copy
     won't have it; since the server reads `.env` via `dotenv/config`, this makes
     every launch — including UI-triggered restarts — bind `0.0.0.0`.
   - Write `web/.env` with the Firebase client config (verbatim from `setup.sh`)
     **before** the build, since Vite inlines `VITE_*` env at build time.
   - Build the frontend for prod (`npx vite build` in `web`); write `prod` to
     `INSTALL_DIR/.server-mode`.

8. **Optionally start the server**
   - Prompt to start now in a `tmux` session (`am-server`) with working dir
     `INSTALL_DIR` and command
     `CM_TERMINAL_ALLOW_LAN=1 PORT=4801 npx tsx server/index.ts`.
   - After a short sleep, confirm something is listening on `4801` via `lsof`.

9. **Summary**
   - Print `http://<server-ip>:4801` using `hostname -I | awk '{print $1}'`,
     plus the manual start command (with `CM_TERMINAL_ALLOW_LAN=1 PORT=4801`) and
     a Claude Code session example.

## What's removed vs. `setup.sh`

- No non-root user creation, no SSH-key copying, no SSH hardening, no
  `systemctl restart ssh`.
- No fail2ban, no Tailscale, no firewall.
- No `su - $NEW_USER -c "..."` indirection — since the script *is* the user,
  commands run directly (simpler, less fragile).
- No `provision.sh` counterpart.

## Risks / caveats

- **Public-IP exposure:** with direct-IP access and no firewall, if the box has a
  public IP then port `4801` is internet-reachable. In LAN mode the terminal
  token gates the terminal feature, but the app UI itself is still exposed; the
  script prints a one-line warning. (Not adding a firewall, per your call.)
- **Primary-IP detection:** `hostname -I | awk '{print $1}'` returns the first
  address, which on a multi-homed box (extra NICs, Docker, VPNs) may not be the
  interface you reach the box on. The summary notes this so you can substitute
  the right IP.
- **Port default:** the server's own default is `4800` (`server/index.ts:55`),
  but the canonical runtime port used elsewhere is `4801`
  (`server/lib/orchestration-worker.ts:121`). The script pins `PORT=4801`
  explicitly to match, at launch and in the printed commands. `PORT` is passed
  inline rather than written to `.env` on purpose — persisting it there would
  force `4801` onto the app's dev mode too, where Express expects `4800`.
- **HTTP, not HTTPS:** prod serves plain HTTP, so the URL is
  `http://<ip>:4801`. `server/index.ts:62-72` uses HTTPS only when
  `.certs/key.pem` and `.certs/cert.pem` exist, and `.certs/` is gitignored
  (`.gitignore:16`) so a fresh clone has none. If you later drop certs into
  `.certs/`, the server switches to `https://` and the summary URL would change.

## Deliverable

- New file: `ubuntu-install.sh` in the repo root.
- No changes to existing `setup.sh` / `provision.sh`.

## Decisions settled

- **Script name:** `ubuntu-install.sh`.
- **Port:** fixed at `4801`, overridable via the `PORT` env var — no prompt.
