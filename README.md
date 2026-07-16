# Agent Manager Setup

Setup scripts for installing [Agent Manager](https://github.com/okthink-ai/claude-manager) — on a fresh Hetzner VPS, an Ubuntu server you already own, or your Mac.

`provision.sh` greets you with a bodega-style splash — a braille rendering of the project wordmark (shown here without its terminal color):

```text
   ⢀⣠⡴⠶⢾⣿⣿⣿⣿                    ⠈⢹⣿⣿⣿⡇              ⢠⣴⣶⡄
  ⢰⣿⣃⣀  ⣿⣿⣿⣟⣠⣤⣤⣄⡀   ⣠⣤⠴⣤⣤⣀   ⣀⣤⣴⠦⣼⣿⣿⣿⡇ ⢀⣠⡴⢶⣤⣄  ⢀⣠⣤⠶⢦⣿⣝⠛⠃⢀⣤⡤⠶⣶⣤
  ⢿⣿⣿⣿⡷ ⣿⣿⣿⣿⠉⠹⣿⣿⣿⡄⢠⣾⣿⡇ ⠸⣿⣿⣧ ⣼⣿⣿⡇ ⢸⣿⣿⣿⡇⣰⣿⣿  ⣿⣿⣷⢠⣿⣿⣿ ⠈⣿⣿⣷⡀⣿⣿⣷ ⣿⣿
  ⠈⠙⠛⠛⠁ ⣿⣿⣿⣿  ⣿⣿⣿⡇⣿⣿⣿⡇  ⣿⣿⣿⣷⣿⣿⣿⡆ ⢸⣿⣿⣿⡇⣿⣿⣿⡴⠞⠛⠋⠉⠸⣿⣿⣿  ⣿⣿⣿⠃⢈⣩⣥⡶⣿⣿
        ⣿⣿⣿⣿  ⣿⣿⣿⠇⢻⣿⣿⣧  ⣿⣿⣿⠉⣿⣿⣿⣇ ⢸⣿⣿⣿⡇⢿⣿⣿⣷⣄⣀⣀⣠⡄⣉⡿⠿⠦⠴⠿⠛⠁⢰⣿⣿⣿ ⣿⣿
        ⠛⠛⠛⠋⢀⣴⣿⠿⠋  ⠙⠿⣿⣄⣠⡿⠟⠁ ⠘⠿⣿⣿⡷⢿⣿⣿⡿⠧⠈⠻⢿⣿⣿⣿⠿⠋⢰⣿⣷⣶⣶⣾⣿⣿⣶⣜⢿⣿⣿⡿⢻⣿
                                     ⣠⣴⣶⣶⠶⠶⠶⣤⣄⣈⠛⠿⠿⠿⠿⠿⠿⣿⣿    ⠈⢿

  AGENT MANAGER SETUP   · your code · your agents · one bodega
```

## Which path is yours?

| Where will Agent Manager run? | Use | Run it |
|-------------------------------|-----|--------|
| A **new Hetzner VPS** (we create it for you) | `provision.sh` → `setup.sh` | On your laptop, then on the new server |
| An **Ubuntu server you already own** | `ubuntu-install.sh` | On the server |
| **Your Mac** | `mac-install.sh` | On the Mac |
| A box that **already has Agent Manager** and needs updating | `migrate-to-expo.sh` | On the box — see [Updating an Existing Install](#updating-an-existing-install) |

All scripts are idempotent — if one fails partway, re-run it and it picks up where it left off.

## Quick Start — New Hetzner VPS

The full-service path: creates the server, hardens it, and puts the dashboard on your private Tailscale network. You need a [Hetzner Cloud](https://console.hetzner.cloud) account and a [Tailscale](https://tailscale.com) account.

### 1. Run the provisioning script on your laptop

```bash
git clone https://github.com/okthink-ai/agent-manager-setup.git
cd agent-manager-setup
bash provision.sh
```

This will:
- Generate an SSH key (or let you reuse an existing one)
- Optionally create the Hetzner firewall and server via the `hcloud` CLI
- Or print a manual checklist for the Hetzner Console
- Write an SSH config entry (with your consent)
- Copy `setup.sh` to the server

The script asks for your consent before every step that changes something — installing the CLI, uploading your SSH key, creating the firewall, and creating the (paid) server, which is gated behind an explicit cost confirmation. Press Enter to accept the default (yes) or `n` to decline.

For unattended/automated runs, pass `--bypass-consent` (alias `-y`): every consent prompt is auto-accepted and selection prompts use their defaults (nearest region, cheapest qualifying server type). This **will create a paid server without a cost prompt**, so use it deliberately. It needs a Hetzner token already configured — either a saved `hcloud` context from a prior run or a valid `HCLOUD_TOKEN` exported in the environment (the token is the one step that can't be automated):

```bash
bash provision.sh --bypass-consent
```

Unattended runs pick the region nearest you via geo-IP. If geo-IP can't detect your location (for example, behind a CI egress firewall), the run stops rather than guess — pass an explicit region instead:

```bash
bash provision.sh --bypass-consent --location fsn1
```

**The one manual step: a Hetzner API token.** Hetzner has no API to create a project or mint a token, so this can't be automated — you paste a token once and it's saved and reused on every later run. You don't need to create a new project: Hetzner gives you a **Default** project at signup, and any existing project works. In the Console, open a project → Security → API Tokens → Generate (Read & Write). The script can open the Console for you.

### 2. SSH into the server and run the setup script

```bash
ssh agent-manager-vps
bash setup.sh
```

This will:
- Create a non-root user and harden SSH
- Install fail2ban, NVM, Node.js 22, Tailscale
- Authenticate with GitHub (supports secondary accounts)
- Install the AI coding agents you choose — Claude Code (recommended), Codex, Gemini, and/or Pi
- **Switch to the non-root user** for all application work
- Clone and install Agent Manager
- Build the frontend for production
- Optionally start the server in a tmux session

After SSH hardening, setup switches to the non-root user for everything that follows — GitHub/AI authentication, the Agent Manager checkout, the build, and the running server all happen as that user, never as root (only `apt` and `tailscale up` still use root, where the OS requires it).

**Non-interactive auth.** The GitHub and Tailscale logins can skip the browser. Export a [Tailscale auth key](https://login.tailscale.com/admin/settings/keys) and/or a [GitHub PAT](https://github.com/settings/tokens) (with `repo` + `read:packages`) before running, and setup uses them instead of the interactive login:

```bash
TS_AUTHKEY=tskey-... GH_TOKEN=ghp_... bash setup.sh
```

This removes the two browser logins only — `setup.sh` is not a fully hands-off run. It still prompts for the username, git identity, the SSH-access safety check, Claude Code auth, the optional-CLI choices, and whether to start the server, so keep a terminal attached.

### 3. Access the dashboard

```
http://<tailscale-ip>:4801
```

The dashboard is only reachable over your Tailscale network — nothing is exposed to the public internet.

## Quick Start — Existing Ubuntu Server

For a box you already own: your user, SSH access, and (if you want one) firewall are already set up, so the script touches none of that — no user creation, no SSH hardening, no fail2ban, no Tailscale. Run it **on the server**, as your normal sudo user (not root):

```bash
curl -fsSLO https://raw.githubusercontent.com/okthink-ai/agent-manager-setup/main/ubuntu-install.sh
bash ubuntu-install.sh
```

This will:
- Install any missing base packages (skipping ones you already have)
- Install NVM + Node.js 22
- Install GitHub CLI and authenticate (interactive, or via `GH_TOKEN`)
- Install the AI coding agents you choose — Claude Code, Codex, Gemini, and/or Pi
- Clone Agent Manager into a directory you choose and build it
- Optionally start the server in a tmux session

**Choose your access mode.** The script asks how you'll reach the app:

1. **localhost** (default, most secure) — the server binds loopback only. Reach it from your laptop through an SSH tunnel, then open `http://localhost:4801`:

   ```bash
   ssh -L 4801:localhost:4801 you@your-server
   ```

2. **direct IP** — the server binds all interfaces and you open `http://<server-ip>:4801` directly. Only pick this if the port is protected by your own firewall or private network.

Optional env vars: `GH_TOKEN` (a GitHub PAT with `repo` + `read:packages`, skips the browser login) and `PORT` (default 4801).

## Quick Start — Mac

The local-machine path: no VPS, no SSH, no Tailscale. Run it on your Mac as your normal user:

```bash
curl -fsSLO https://raw.githubusercontent.com/okthink-ai/agent-manager-setup/main/mac-install.sh
bash mac-install.sh
```

This will:
- Check Homebrew and install any missing base tools (git, tmux, gh)
- Install NVM + Node.js 22
- Authenticate GitHub CLI (interactive, or via `GH_TOKEN`)
- Install the AI coding agents you choose — Claude Code, Codex, Gemini, and/or Pi
- Clone Agent Manager into a directory you choose and build it (prod mode)
- Optionally start the server in a tmux session

Then open `http://localhost:4801` in your browser.

It won't clobber an existing checkout, `.env` files, or your Claude Code settings, and the same `GH_TOKEN` / `PORT` env vars apply.

## Choosing Your Agents

All three installers offer the same agent menu. Claude Code is offered first (recommended, default yes) but not mandatory — decline it and drive Agent Manager with another agent instead. Next come [OpenAI Codex](https://developers.openai.com/codex/cli) (`@openai/codex`), [Google Gemini CLI](https://www.npmjs.com/package/@google/gemini-cli) (`@google/gemini-cli`), and [Pi](https://pi.dev) (`@earendil-works/pi-coding-agent`). Install whichever you have accounts/keys for — each prints its own auth hint, a failed install is skipped rather than fatal, and the script warns if you end up with no agent at all.

## Requirements

For every path:
- A GitHub account with access to the `okthink-ai` org
- An account for at least one agent — e.g. Anthropic for Claude Code ([console.anthropic.com](https://console.anthropic.com))

Only for the Hetzner VPS path:
- A Hetzner Cloud account ([console.hetzner.cloud](https://console.hetzner.cloud))
- A Tailscale account ([tailscale.com](https://tailscale.com))

## Server Specs (Hetzner path)

The provisioning script doesn't lock you to a single server type. It picks the **best instance for your location**: after detecting your nearest Hetzner region, it lists every server type that meets the spec floor (**≥ 4 vCPU / ≥ 8 GB RAM**) and is actually in stock there, sorted cheapest-first, and defaults to the cheapest. You can accept the default or override it.

Which types qualify depends on the region (Hetzner offers different families in different datacenters):

| Region | Typical qualifying types (4 vCPU / 8 GB tier) | Approx. price/mo (ex. VAT) |
|--------|-----------------------------------------------|----------------------------|
| EU — Germany (Falkenstein, Nuremberg), Finland (Helsinki) | CX33 (x86), CAX21 (ARM), CPX31 / CPX32 (AMD) | ~€6.49–€9 |
| US — Ashburn, Hillsboro | CPX32 (AMD) | ~€9–13 |
| Singapore | CPX32 (AMD) | ~€9–13 |

ARM (CAX) instances are eligible where available — everything we install (Node.js 22, Claude Code, Tailscale, fail2ban) runs on ARM64, and Hetzner auto-selects the matching Ubuntu 24.04 LTS image. EU users get the cheapest options; US and Singapore users get CPX32, the best type Hetzner stocks at that tier in those regions.

Prices and exact type availability change over time — the script always reads Hetzner's live catalogue, so what it offers is current.

## What Gets Installed

| Tool | Purpose | Paths |
|------|---------|-------|
| Node.js 22 (via NVM) | Runtime for Agent Manager | All |
| GitHub CLI | Authenticate with GitHub for private package access | All |
| Claude Code | The CLI tool that Agent Manager monitors | All (on request) |
| Codex / Gemini / Pi CLIs | Optional — other terminal coding agents | All (on request) |
| tmux | Session persistence for long-running processes | All |
| Tailscale | Private networking — access the dashboard without exposing ports | Hetzner VPS only |
| fail2ban | SSH brute-force protection | Hetzner VPS only |

## Updating an Existing Install

Agent Manager's frontend moved from Vite (`web/`) to Expo (`apps/expo`). Boxes installed before the switch can't just `git pull` — the frontend config, dependency layout, and build command all changed. Run the migration script on the box instead (works on the VPS, an existing Ubuntu server, and Mac installs; it probes `~/dev/claude-manager` and `~/claude-manager`, or takes `--dir`):

```bash
curl -fsSLO https://raw.githubusercontent.com/okthink-ai/agent-manager-setup/main/migrate-to-expo.sh
bash migrate-to-expo.sh            # migrate (or update an already-migrated box)
bash migrate-to-expo.sh --clean    # also delete the old Vite artifacts (~350 MB)
```

It translates your Firebase config to `apps/expo/.env`, fast-forwards the checkout to `main`, reinstalls dependencies, rebuilds the frontend, keeps the box reachable over Tailscale/LAN (`CM_TERMINAL_ALLOW_LAN=1`), restarts the `am-server` tmux session, and verifies the server responds. It records the pre-update commit and prints rollback instructions if anything fails. Idempotent — re-running it later acts as a plain "update to latest".
