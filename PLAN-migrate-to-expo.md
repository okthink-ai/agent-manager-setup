# Plan: `migrate-to-expo.sh` — upgrade existing installs from the Vite frontend to Expo

## Executive summary

Upstream claude-manager replaced its Vite frontend with an Expo (React Native for Web) app, which changes where the frontend lives, how it's configured, and how it's built — leaving every box installed by this repo's scripts stranded on the old frontend, and leaving the installers themselves broken for fresh installs.

- Add a new migrate-to-expo.sh script to this repo

  - Why: existing installs serve a stale Vite build the new server no longer looks at, and a bare git pull leaves them with untranslated Firebase config, missing workspace dependencies, and no Expo build.

  - What: a single portable, idempotent bash script for Ubuntu and Mac that translates web/.env Firebase values to apps/expo/.env, fast-forwards the checkout to main, runs one root npm install (workspaces now cover the frontend), builds the Expo web export, restarts the am-server tmux session, and verifies the server responds on /api/status.

- Preserve network reachability during the migration

  - Why: the new server binds 127.0.0.1 unless CM_TERMINAL_ALLOW_LAN=1 is set, and setup.sh-era VPS installs accessed via a Tailscale IP never wrote that flag — upgrading them without it takes the box offline.

  - What: before stopping the old server, the script inspects its listening socket; if it binds a non-loopback address and the root .env lacks CM_TERMINAL_ALLOW_LAN=1, the script appends the flag so the box stays reachable at the same URL; when no server is running it falls back to detecting Tailscale, and asks rather than silently widening a localhost-only box.

- Record a rollback point and print recovery instructions on any post-pull failure

  - Why: if the build or restart fails after the pull, the box must not be left dead with no path back.

  - What: the pre-pull commit SHA is captured before updating; any failure after the pull prints the exact commands to check out that SHA, reinstall the old dependencies, and relaunch the old server; deletion of the old Vite artifacts is opt-in and deferred until verification passes, so a rollback always finds the old build still on disk.

- Update setup.sh, ubuntu-install.sh, and mac-install.sh in the same PR

  - Why: all three hard-fail against new main — their npm install inside web/ dies (misdiagnosed as a GitHub 403 with an interactive retry loop), and their web/.env write and vite build would hard-exit under set -e; setup.sh additionally advertises a Tailscale URL that the loopback-binding new server can't serve.

  - What: drop the web/ install step, write apps/expo/.env with EXPO_PUBLIC_FIREBASE_* values instead of web/.env with VITE_* values, build with npm run build at the repo root, and have setup.sh persist CM_TERMINAL_ALLOW_LAN=1 to .env the way ubuntu-install.sh's direct mode already does.

## What changed upstream

Commit `a7cb16f1` ("Migrate Agent Manager frontend from Vite to Expo (React Native for Web) (#369)", now on `origin/main` of claude-manager, plus follow-ups #374/#375/#378) replaced the frontend entirely:

| | Old (Vite) | New (Expo) |
|---|---|---|
| Frontend dir | `web/` | `apps/expo` (npm workspace `apps/*`) |
| Client env file | `web/.env` with `VITE_FIREBASE_*` | `apps/expo/.env` with `EXPO_PUBLIC_FIREBASE_*` |
| Build | `cd web && npx vite build` | `npm run build` at root → `expo export --platform web` → `apps/expo/dist` (with `EXPO_PUBLIC_API_URL=/`, `EXPO_PUBLIC_WS_URL=/ws` pinned inline) |
| Deps install | `npm install` in root **and** `web/` | single root `npm install` (workspaces) |
| Prod launch | `PORT=4801 npx tsx server/index.ts` | same command still works — `server/index.ts:75-79` defaults its static dir to a module-relative `apps/expo/dist` (`CM_FRONTEND_DIST` is an optional override, not required); `npm start` = rebuild + launch |
| Firebase | required at build | optional — `apps/expo/src/firebase.ts` logs a warning and disables team features when config is missing (`EXPO_PUBLIC_FIREBASE_REQUIRED` only affects the standalone validate-config script, not runtime) |

Unchanged and preserved across the migration: root `.env` (gitignored, loaded via `dotenv/config` at `server/index.ts:1`), `.server-mode` (still read by `server/daemon/restart-servers.ts:73-87`, which also rewrites it after each successful restart), port 4801, the tmux `am-server` convention.

Two behaviors that matter for the migration:

- **Bind address**: `server/index.ts:243-248` binds `127.0.0.1` when the terminal is enabled (it is by default) and `CM_TERMINAL_ALLOW_LAN` ≠ `1`; only that flag (or disabling the terminal) yields `0.0.0.0`. `ubuntu-install.sh` already persists the flag for direct-IP installs, but `setup.sh` never writes it — its Tailscale-accessed VPS boxes depend on whatever binding their old checkout had, and must gain the flag during migration to stay reachable.
- **TLS**: Express serves HTTPS iff `<repo>/.certs/key.pem` + `cert.pem` exist (`server/index.ts:60-74`), plain HTTP otherwise. Installed boxes have no certs → HTTP, but health checks should pick the scheme by cert presence and use `curl -sk`, exactly as `restart-servers.ts:128,153-155` does.

Consequence for this repo: an existing box that does `git pull` today ends up with a stale `web/dist` the server no longer serves, and the installers' own steps fail outright because `web/` no longer exists in git (exact breakage lines under "Companion change" below).

## The new script: `migrate-to-expo.sh`

One portable bash script (Ubuntu VPS + Mac), living in this repo next to the installers. Run as the app user on the box (`bash migrate-to-expo.sh`), idempotent, safe to re-run. Flags: `--dir <path>` (or `INSTALL_DIR` env), `-y`/`--yes` for unattended runs, `--port` (default 4801), `--clean` to delete leftover Vite artifacts.

### Steps

1. **Preflight**
   - Resolve install dir: `--dir` / `INSTALL_DIR`, else probe `~/dev/claude-manager` (setup.sh and ubuntu-install.sh default) then `~/claude-manager` (mac-install.sh default — note the two differ). Verify it's a git checkout whose origin remote points at claude-manager.
   - Load nvm (`~/.nvm`) if present, else use PATH node. Require Node ≥ 20 (README floor is v20+; `@expo/env` in the lockfile requires ≥ 20.12). Boxes installed by these scripts have Node 22.
   - Verify GitHub Packages auth: `GITHUB_TOKEN` env or `gh auth token` must yield a token — the repo's `.npmrc` references `${GITHUB_TOKEN}` and npm errors at install time if it's unset. The `apps/expo` git dependency `github:okthink-ai/debug-element-inspector` additionally needs the gh git credential helper, which the installers already configure.
   - If the checkout has uncommitted changes or is on a non-main branch: warn and abort with instructions (`git stash`, re-run) rather than guessing. `-y` does not override this.
   - Already-migrated boxes need no special casing: every step below is a no-op where its work is already done (step 2 falls back to defaults when `web/.env` is gone, step 4 skips when `apps/expo/.env` exists), and the fetch/pull still runs — so re-running the script doubles as a plain "update to latest" runner.

2. **Capture old config (before touching git)**
   - If `web/.env` exists, translate the six variables the Expo app actually consumes (`apps/expo/src/firebase.ts:9-14`): `VITE_FIREBASE_{API_KEY,AUTH_DOMAIN,PROJECT_ID,STORAGE_BUCKET,MESSAGING_SENDER_ID,APP_ID}` → `EXPO_PUBLIC_FIREBASE_*`, keeping any custom values the user put there. (`web/.env` is untracked so it survives the pull; capturing first is still the safe order.)
   - `VITE_FIREBASE_VAPID_KEY` has no Expo equivalent — nothing on origin/main consumes any VAPID variable — so it is dropped, with a note in the final summary output. `EXPO_PUBLIC_FIREBASE_MEASUREMENT_ID` is an unconsumed placeholder and is not written.
   - If no `web/.env`, fall back to the shared okthink Firebase defaults already baked into the installers. (Firebase is optional in the new app, but the defaults preserve team-chat behavior these boxes had.)
   - Root `.env` needs nothing — it's untracked and the pull won't touch it.

3. **Update the code**
   - Record the rollback point first: `PREV_SHA=$(git rev-parse HEAD)`.
   - `git fetch origin && git pull --ff-only` (preflight already guaranteed the checkout is on main).
   - Abort with a clear message if ff-only fails (diverged local main).

4. **Write `apps/expo/.env`**
   - Only if absent (idempotence). Contents: the translated `EXPO_PUBLIC_FIREBASE_*` block. The Expo CLI (SDK 56, via `@expo/env`) auto-loads `apps/expo/.env` during `expo export`, so writing the file is sufficient — no other wiring. The root `.gitignore`'s bare `.env` pattern matches at every depth, so the file stays untracked.
   - Do **not** set `EXPO_PUBLIC_API_URL`/`EXPO_PUBLIC_WS_URL` here — the root `build` script pins those inline to `/` and `/ws` for same-origin production serving, and shell env takes precedence over `.env` values in Expo's loader.

5. **Install dependencies**
   - Root `npm install` with `GITHUB_TOKEN` exported, using the existing retry-on-403 helper (copy from `ubuntu-install.sh:374-400`). Workspaces pull in `apps/expo`; there is no separate web install anymore.

6. **Build**
   - `npm run build` at root (exports Expo web to `apps/expo/dist`). Expect minutes, not seconds — upstream's own restart daemon allows this step 10 minutes.
   - Ensure `.server-mode` contains `prod`.

7. **Preserve reachability, then restart the server**
   - Bind check first: inspect the current server's listening socket (`ss -ltn` on Linux, `lsof -iTCP:$PORT -sTCP:LISTEN` on Mac). If it binds a non-loopback address and the root `.env` lacks `CM_TERMINAL_ALLOW_LAN=1`, append the flag (prompt; auto-yes under `-y`, since skipping it takes a remotely-accessed box offline). Localhost-only installs are left untouched.
   - If no server is running when the script starts (crashed, rebooted box), fall back: flag already in `.env` → nothing to do; `tailscale ip -4` succeeds → treat as a remotely-accessed VPS and add the flag (setup.sh boxes always have Tailscale); otherwise ask — and under `-y`, leave it unset but print a loud warning with the one-line fix, since silently widening a localhost-only box to 0.0.0.0 is the worse default. The flag is safe on provisioned VPSes: the Hetzner firewall admits only SSH and ICMP inbound, so binding 0.0.0.0 doesn't expose the port publicly, and Tailscale traffic arrives via its own interface regardless.
   - Stop: if tmux session `am-server` exists, send C-c to its pane; then ensure nothing is left listening on `$PORT` the way `restart-servers.ts:33-71` does (`lsof -ti :$PORT -sTCP:LISTEN` → SIGTERM, wait up to 5s, SIGKILL) — covers boxes where the server was started outside tmux or re-parented by a UI-triggered restart.
   - Start: relaunch in tmux `am-server` with `PORT=$PORT npx tsx server/index.ts`. `CM_FRONTEND_DIST` is unnecessary (the server defaults to `apps/expo/dist`); `CM_TERMINAL_ALLOW_LAN` comes from the persisted root `.env` via dotenv. If no session exists, create one (same pattern as the installers).
   - Build-once + explicit launch rather than `npm start`, so manual restarts don't pay a full Expo export each time. (Considered alternative: `npm run restart:servers:prod` kills port listeners, rebuilds, spawns detached, and self-verifies — but it discards server output with `stdio: 'ignore'`, whereas the tmux pane keeps logs visible and matches the installer convention. UI-triggered restarts use that daemon and work post-migration with no extra config; note the daemon manages the default ports only, so boxes installed with a custom `--port` rely on the tmux flow.)
   - Poll the port for up to 30s (the upstream restart daemon's own budget).

8. **Verify + cleanup**
   - Pick the scheme by cert presence (`.certs/key.pem` + `cert.pem` → https, else http) and use `curl -sk`, mirroring `restart-servers.ts`. There is no `/api/health`; the health endpoint is `GET /api/status` (unconditional 200 JSON `{cwd, branch}`, `server/index.ts:144-146`). Then check `GET /` returns 200 HTML — that specifically confirms the Expo dist was exported, since a missing dist makes the SPA catch-all's sendFile fail with a non-200.
   - Only with an explicit `--clean` flag (never implied by `-y`), and only after the verification above passes: delete leftover untracked Vite artifacts — `web/node_modules` (~340 MB measured), `web/dist` (~6 MB), and `web/.env` (only after its values were translated in step 2). Gating cleanup on successful verification means a rollback always finds the old build and dependencies still on disk.
   - Print a summary: old → new frontend, config migrated (including the dropped VAPID key, if one was set), access URL, and the recorded `PREV_SHA` rollback point.

### Failure handling

- Every step idempotent; Ctrl+C message mirrors provision.sh ("re-run to resume").
- Any failure after the pull prints explicit rollback instructions using the `PREV_SHA` recorded in step 3: `git checkout $PREV_SHA`, re-run `npm install` in root and `web/` (the old lockfile needs the old dependency layout), then relaunch the old command. The box is never left dead silently. Because `--clean` runs only after verification passes (step 8), every rollback scenario still has the old `web/dist` and `web/node_modules` on disk.

## Companion change (same PR, strongly recommended)

All three installers hard-fail on a fresh install against new main. In each, the `web/` npm install is the first step to die — the retry helper misdiagnoses the missing directory as a GitHub 403, shows auth-fix hints, blocks on an interactive "press Enter to retry" prompt, then exits 1. The later `web/.env` write and `vite build` steps would hard-exit under `set -e` if reached:

- `setup.sh`: web install at :522, web/.env heredoc at :532-546, vite build at :549-551. Additionally, setup.sh never writes `CM_TERMINAL_ALLOW_LAN` yet advertises `http://<tailscale-ip>:4801` (:575, :597, :615) — against the loopback-binding new server that URL is dead even on a fresh install. Persist `CM_TERMINAL_ALLOW_LAN=1` to `.env` the way `ubuntu-install.sh:416-419` does for direct mode.
- `ubuntu-install.sh`: web install at :403, web/.env at :433-447, vite build at :450-452. Access-mode/.env logic is already correct.
- `mac-install.sh`: web install at :379, web/.env at :391-405, vite build at :408-410. (Its `INSTALL_DIR` default is `~/claude-manager`, not `~/dev/claude-manager` — the migration script's probe order accounts for this.)

Shared fix for all three: drop the `web/` install; write `apps/expo/.env` with the `EXPO_PUBLIC_FIREBASE_*` block instead of `web/.env` with `VITE_*`; build with `npm run build` at the repo root; launch commands need no change (`CM_FRONTEND_DIST` is not required). Update this repo's README to mention `migrate-to-expo.sh` for existing boxes.

## Open questions

1. Distribution: is running it manually on each box (clone/curl this repo) enough, or should provision.sh-style scp delivery be added? (Assumption: manual is fine — there are only a handful of boxes.)
2. Should the migration script also handle installs living at a non-default path from `ubuntu-install.sh`'s `INSTALL_DIR` prompt, beyond the `--dir` flag and the two-default probe? (Assumption: the flag is enough.)
