# Agent Manager Setup

Setup scripts for provisioning and configuring a Hetzner VPS to run [Agent Manager](https://github.com/okthink-ai/claude-manager).

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

The default server type is **CPX31** (4 vCPU, 8 GB RAM, 160 GB SSD) running Ubuntu 24.04 LTS. Estimated cost: ~$9-12/month.

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
