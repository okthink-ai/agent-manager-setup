# Agent Manager Setup

Setup scripts for provisioning and configuring a Hetzner VPS to run [Agent Manager](https://github.com/okthink-ai/claude-manager).

`provision.sh` greets you with a bodega-style splash — a braille rendering of the project wordmark (shown here without its terminal color):

```text
     ⣀⣤⣴⣶⣶⣾⣿⣿⣿                         ⠛⢿⣿⣿⣿⣿                  ⢀⣤⣤
   ⣠⣾⠋⠁ ⠈⢿⣿⣿⣿⣿            ⢀⣀         ⢀⣀ ⢸⣿⣿⣿⣿     ⣀⣀        ⣀⣀⢠⡿⢿⣿
  ⢸⣿⣿⣶⣶⣄ ⢸⣿⣿⣿⣿⣴⣿⣿⣿⣷⣤   ⣠⣶⣿⠋⠙⣿⣿⣦⡀  ⣠⣶⣿⣿⠋⠛⣿⣿⣿⣿⣿  ⣤⣾⡟⠉⢻⣿⣷⣄ ⢀⣴⣾⣿⠋⠙⣿⣿⣶⣍
  ⠸⣿⣿⣿⣿⣿ ⢸⣿⣿⣿⣿⠁ ⢹⣿⣿⣿⣧ ⣼⣿⣿⡏  ⢹⣿⣿⣿⡄⢰⣿⣿⣿⡇  ⢸⣿⣿⣿⣿⢀⣾⣿⣿⠃ ⢸⣿⣿⣿⡆⣾⣿⣿⣿  ⢹⣿⣿⣿
   ⠙⠛⠟⠛⠁ ⢸⣿⣿⣿⣿  ⠘⣿⣿⣿⣿⢸⣿⣿⣿⣇  ⢸⣿⣿⣿⣷⣾⣿⣿⣿⡇  ⢸⣿⣿⣿⣿⢸⣿⣿⣿⣧⠶⠟⠛⠋⠉ ⣿⣿⣿⣿  ⢸⣿⣿⣿
         ⢸⣿⣿⣿⣿  ⢠⣿⣿⣿⣿⠸⣿⣿⣿⣿   ⣿⣿⣿⡟⢻⣿⣿⣿⣧  ⢸⣿⣿⣿⣿⢸⣿⣿⣿⣷⣄
         ⢸⣿⣿⣿⣿  ⣸⣿⣿⣿⠃ ⠹⣿⣿⣿⡄ ⢠⣿⣿⡿⠁⠘⣿⣿⣿⣿⣦⣀⣼⣿⣿⣿⣿ ⠻⣿⣿⣿⣿⣿⣶⣶
         ⣼⠿⠿⠛⠿⠶⠶⠿⠟⠋⠁   ⠈⠛⠿⠿⠶⠾⠛⠉   ⠈⠛⠿⠿⠿⠛⠹⠿⠿⠛⠛⠛ ⠈⠛⠿⠿⠿⠟⠋

  AGENT MANAGER SETUP   · your code · your agents · one bodega
```

## Quick Start

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
- Install Claude Code
- Clone and install Agent Manager
- Build the frontend for production
- Optionally start the server in a tmux session

## Requirements

- A Hetzner Cloud account ([console.hetzner.cloud](https://console.hetzner.cloud))
- A GitHub account with access to the `okthink-ai` org
- A Tailscale account ([tailscale.com](https://tailscale.com))
- An Anthropic account for Claude Code ([console.anthropic.com](https://console.anthropic.com))

## Server Specs

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

| Tool | Purpose |
|------|---------|
| Node.js 22 (via NVM) | Runtime for Agent Manager |
| Tailscale | Private networking — access the dashboard without exposing ports |
| GitHub CLI | Authenticate with GitHub for private package access |
| Claude Code | The CLI tool that Agent Manager monitors |
| tmux | Session persistence for long-running processes |
| fail2ban | SSH brute-force protection |

## Re-running

Both scripts are idempotent — they check what's already installed and skip completed steps. If the script fails partway through, re-run it and it will pick up where it left off.

## Access

After setup, access Agent Manager at:

```
http://<tailscale-ip>:4801
```

The dashboard is only reachable over your Tailscale network — nothing is exposed to the public internet.
