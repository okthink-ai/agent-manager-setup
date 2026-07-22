# Plan: `migrate-to-agent-manager.sh` — move existing installs to the Agent Manager identity

## Executive summary

Upstream renamed the product and repository from Claude Manager to Agent Manager: the GitHub repo moved to `okthink-ai/agent-manager` (with GitHub's automatic redirect from the old path), and PR #403 ("Rename Agent Manager and polish workspace UI", merged 2026-07-21) rebranded the UI, docs, prompts, and repository links. Existing boxes still carry the old identity in two durable places — the git remote URL and the install directory name (`~/dev/claude-manager` / `~/claude-manager`) — and serve a frontend build that still says Claude Manager. Nothing is broken today, because GitHub redirects the old repo path and upstream deliberately kept every internal compatibility identifier. This is hygiene with a quiet deadline: the redirect works only until the old name is ever reused, every doc and runbook now says `agent-manager`, and each new box provisioned by our scripts widens the naming split between fleet members.

- Add a `migrate-to-agent-manager.sh` script to this repo

  - Why: a bare `git pull` fixes none of the durable identity carriers — the remote URL stays on the redirect, the directory keeps the old name, and the frontend needs a rebuild before the UI stops saying Claude Manager.

  - What: a single portable, idempotent bash script (VPS, Ubuntu, and Mac installs) that repoints the git remote at `okthink-ai/agent-manager` (preserving SSH vs HTTPS form), stops the server, renames the install directory to `agent-manager`, then delegates update + rebuild + restart + verification to `migrate-to-expo.sh --dir <new-path>` — the established idempotent updater with a clean-tree guard, rollback messaging, and reachability preservation. With `--skip-update`, the script relaunches the server itself from the new path instead of delegating, so no flag combination leaves the box stopped.

- No data migration, by construction

  - Why: the server database is `<install>/data/agent-manager.db` — the filename predates the rename, `getDbPath()` resolves it cwd-relative, and default installs set no `CM_DB_PATH`. PR #403 explicitly "retains existing internal package identifiers, URL schemes, and the Expo app slug" — the npm package is still `claude-manager`, the workspace still `@claude-manager/expo`, env vars still `CM_*`, bins still `cm`/`claude-manager`.

  - What: renaming the directory carries `data/`, `.env`, `node_modules`, and `.server-mode` along untouched. The one hard requirement is that the server restarts with the new directory as its cwd — which the delegated updater already does (`tmux new-session -d -s am-server -c "$INSTALL_DIR"`, migrate-to-expo.sh:602).

- Rename only names, never identifiers — no blind sed

  - Why: `claude-manager` appears in our scripts in three distinct roles, and only one of them is a name. The Firebase client-config values (`claude-manager-chat`, `claude-manager-chat.firebaseapp.com`, `claude-manager-chat.firebasestorage.app`) are the real Firebase project's identifiers — renaming them breaks auth and messaging on every box. Upstream's package/workspace/env identifiers are likewise functional. A repo-wide `sed claude-manager → agent-manager` would corrupt both.

  - What: an explicit do-not-touch list in this plan and in the implementation PR description: the three `claude-manager-chat` Firebase values (in `firebase-defaults.env` and the fallback blocks of `setup.sh`, `ubuntu-install.sh`, `mac-install.sh`, plus `migrate-to-expo.sh`'s env translation), and every upstream-owned identifier (`CM_*` env keys, package names, bin names).

- Guard before mutating, not after

  - Why: the ugliest failure shape is a half-renamed box — directory moved, then the updater's clean-tree guard refuses to proceed.

  - What: run every precondition up front, before the first mutation: install located (probe `~/dev/claude-manager`, `~/claude-manager`, and the already-renamed paths so re-runs are no-ops), checkout clean and on main (same package-lock tolerance as migrate-to-expo.sh:373-389), rename target absent — if both old and new directories exist, abort loudly rather than guess which is real — and `CM_DB_PATH` unset or not pointing inside the old path (rewrite it when it does; warn and abort when it points somewhere surprising). Only then: set-url → stop → `mv` → delegate.

## What an existing box carries (inventory)

| Carrier | Old state | Action |
|---|---|---|
| git remote `origin` | `github.com/okthink-ai/claude-manager(.git)` (works via redirect) | `git remote set-url` to `agent-manager`, preserving ssh/https form |
| Install directory | `~/dev/claude-manager` (VPS/Ubuntu) or `~/claude-manager` (Mac) | `mv` to `agent-manager` sibling; abort if the target already exists |
| Running server | tmux session `am-server`, cwd = old path | stop before the move; delegated updater relaunches from the new path and verifies `/api/status` |
| Frontend build | pre-#403 copy still says Claude Manager | delegated `git pull --ff-only origin main` + `npm ci` + expo export |
| Dashboard project label | if the install dir sits inside a `CODE_DIRS` root (e.g. `~/dev`), it lists as `claude-manager` | renames automatically after the move; session history referencing the old cwd is cosmetic — note in the summary, don't touch |
| Running agent sessions | tmux sessions whose cwd sits inside the old path | keep working — on a same-filesystem rename the kernel moves their cwd with the directory — but display stale paths until restarted; the summary says so |
| Firebase config | `claude-manager-chat.*` values in `apps/expo/.env` | unchanged — these identify the Firebase project, not the product |
| Untouched | `.env` (`CM_*` keys), `.npmrc`, `data/`, `.server-mode`, tmux session name `am-server` | nothing — upstream kept all of these stable |

## Script design

Flags mirror the Expo script: `--dir <path>`, `-y`/`--yes`, `--port` (default 4801), plus `--skip-update` (rename + remote only, for boxes the owner updates separately). Steps:

1. **Preflight** — locate the install; require git repo + tools (`git`, `tmux`, `curl`); all guards from the summary. An already-renamed box short-circuits to the update delegation, so re-running is the plain "update to latest" path.
2. **Remote** — `git remote set-url origin <new URL>`; echo old → new. Every box our installers produced has an HTTPS origin (`git clone $REPO_URL` at setup.sh:521, ubuntu-install.sh:382, mac-install.sh:394, with gh's credential helper keeping HTTPS auth working), so the common path is https→https; preserving an SSH form only matters on hand-modified remotes. This step must precede the delegation: the updater pulls with `git pull --ff-only origin main` (migrate-to-expo.sh:459), and the point is for that pull to ride the new URL, not the redirect.
3. **Stop** — reuse the Expo script's stop pattern: interrupt the `am-server` tmux session, then the port-listener kill fallback (migrate-to-expo.sh:587-592). Only `am-server` is stopped; user agent sessions keep running through the move (see inventory).
4. **Move** — `mv` old → new within the same parent. Print the exact reverse command as the rollback line.
5. **Delegate** — invoke `migrate-to-expo.sh --dir <new-path> -y` for pull/install/build/restart/verify; it is layout-aware, so a box that somehow never got the Expo migration gets it here too. The two scripts ship side by side; fetch the companion from `main` when it isn't adjacent on disk. Its `-y` never implies `--clean`, so old-frontend artifacts are never deleted by this flow. With `--skip-update` this step is replaced by a relaunch the script does itself, reusing the updater's exact pattern — `tmux kill-session -t am-server || true`, `tmux new-session -d -s am-server -c <new-path>` (migrate-to-expo.sh:600-602), start the server, verify `/api/status` — because steps 3-4 stopped the server and moved its cwd, and skipping the update must not mean skipping the recovery.
6. **Summary** — new path, new remote, dashboard URL; reminders that shell history, personal scripts, SSH sessions, and running agent sessions reference the old path. Rollback has two independent layers, printed as such: identity rollback (`mv` back + `set-url` back + restart) undoes this script; content rollback (checkout of the pre-pull SHA, printed by the delegated updater) undoes the update — a failed update needs only the second, a regretted rename only the first.

## Companion changes in this repo (same PR as the script)

- `setup.sh` — `REPO_URL` (:95) → `agent-manager.git`; the 8 old-path references → `agent-manager`: the CODE_DIRS guard path (:87), the `INSTALL_DIR` definition (:514), and the `run_as_user`/printed-instruction paths (:572, :619, :633, :647, :687, :692). The three `claude-manager-chat` Firebase values (:621-623) are identifiers — leave them.
- `ubuntu-install.sh` — `REPO_URL` (:51); `DEFAULT_DIR` (:125) → `~/dev/agent-manager`; Firebase values (:480-482) stay.
- `mac-install.sh` — `REPO_URL` (:52); `DEFAULT_DIR` (:151) → `~/agent-manager`; Firebase values (:492-494) stay.
- `migrate-to-expo.sh` — probe order (:303-308) becomes `~/dev/agent-manager`, `~/agent-manager`, then the two legacy paths (it must keep serving un-renamed boxes); old-path mentions in usage/comments/error messages (:20, :63-64, :301, :314-332); the GitHub URL; Firebase values (:405-407) stay.
- `README.md` — the upstream link (:3) and the probe-path prose in Updating an Existing Install (:251); that section gains the rename script as the first step for old boxes; the "Which path is yours?" chooser row for updating points at it.
- New-name clones keep working against old checkouts either way: GitHub's redirect covers fetches of the old URL until the old name is reused — which is exactly why the remote update is worth doing now, while it's a rename rather than a repair.

## Rollout

1. Land this PR (script + companion changes). Fresh installs are on the new identity immediately.
2. Run the script on the known fleet, oldest exposure first: the dev box (`~/dev/claude-manager`, live server — same care as the Expo migration run), the demo box (provisioned 2026-07-21, so it has the old directory name), the Mac mini install, and the Ubuntu developer's box (send them the one-liner).

## Open questions

- Leave a `claude-manager → agent-manager` symlink for muscle memory? Recommended no — it keeps the old name alive on disk indefinitely, which is the thing being retired; the summary's "update your shell habits" note covers the transition.
- Longer term, `migrate-to-expo.sh` has become the de-facto updater and this script is a one-time transition wrapper around it; when the fleet is fully renamed, folding both into a plain `update.sh` would be the cleaner end state. Out of scope here.
