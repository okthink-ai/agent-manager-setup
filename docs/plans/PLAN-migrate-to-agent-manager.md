# Plan: `migrate-to-agent-manager.sh` — move existing installs to the Agent Manager identity

## Executive summary

Upstream renamed the product and repository from Claude Manager to Agent Manager: the GitHub repo moved to `okthink-ai/agent-manager` (with GitHub's automatic redirect from the old path), and PR #403 ("Rename Agent Manager and polish workspace UI", merged 2026-07-21) rebranded the UI, docs, prompts, and repository links. Existing boxes still carry the old identity in two durable places — the git remote URL and the install directory name (`~/dev/claude-manager` / `~/claude-manager`) — and serve a frontend build that still says Claude Manager. Nothing is broken today, because GitHub redirects the old repo path and upstream deliberately kept every internal compatibility identifier. This is hygiene with a quiet deadline: the redirect works only until the old name is ever reused, every doc and runbook now says `agent-manager`, and each new box provisioned by our (already-updated-name) scripts widens the naming split between fleet members.

- Add a `migrate-to-agent-manager.sh` script to this repo

  - Why: a bare `git pull` fixes none of the durable identity carriers — the remote URL stays on the redirect, the directory keeps the old name, and the frontend needs a rebuild before the UI stops saying Claude Manager.

  - What: a single portable, idempotent bash script (VPS, Ubuntu, and Mac installs) that repoints the git remote at `okthink-ai/agent-manager` (preserving SSH vs HTTPS form), stops the server, renames the install directory to `agent-manager`, then delegates update + rebuild + restart + verification to `migrate-to-expo.sh --dir <new-path>` — which is already the established idempotent updater with a clean-tree guard, rollback messaging, and reachability preservation.

- No data migration, by verified construction

  - Why (facts verified against upstream on 2026-07-22): the server database has always been `<install>/data/agent-manager.db` — no `claude-manager.db` exists anywhere in upstream history or on live boxes (confirmed on the dev box: `data/agent-manager.db` + `data/reviews.db`). `getDbPath()` resolves cwd-relative, and default installs set no `CM_DB_PATH`. PR #403 explicitly "retains existing internal package identifiers, URL schemes, and the Expo app slug" — the npm package is still `claude-manager`, the workspace still `@claude-manager/expo`, env vars still `CM_*`, bins still `cm`/`claude-manager`.

  - What: renaming the directory carries `data/`, `.env`, `node_modules`, and `.server-mode` along untouched. The one hard requirement is that the server restarts with the new directory as its cwd — which the delegated updater already does.

- Guard before mutating, not after

  - Why: the ugliest failure shape is a half-renamed box — directory moved, then the updater's clean-tree guard refuses to proceed.

  - What: run every precondition up front, before the first mutation: install located (probe `~/dev/claude-manager`, `~/claude-manager`, and the already-renamed paths so re-runs are no-ops), checkout clean and on main (same package-lock tolerance as the Expo script), target directory absent, `CM_DB_PATH` unset or not pointing inside the old path (rewrite it if it does, warn and abort if it points somewhere surprising). Only then: set-url → stop server → `mv` → delegate.

## What an existing box carries (inventory)

| Carrier | Old state | Action |
|---|---|---|
| git remote `origin` | `github.com/okthink-ai/claude-manager(.git)` (works via redirect) | `git remote set-url` to `agent-manager`, preserving ssh/https form |
| Install directory | `~/dev/claude-manager` (VPS/Ubuntu) or `~/claude-manager` (Mac) | `mv` to `agent-manager` sibling; only when target absent |
| Running server | tmux session `am-server`, cwd = old path | stop before the move; delegated updater relaunches from the new path and verifies `/api/status` |
| Frontend build | pre-#403 copy still says Claude Manager | delegated `git pull` + `npm ci` + expo export |
| Dashboard project label | if the install dir sits inside a `CODE_DIRS` root (e.g. `~/dev`), it lists as `claude-manager` | renames automatically after the move; session history referencing the old cwd is cosmetic — note in the summary, don't touch |
| Untouched | `.env` (`CM_*` keys), `.npmrc`, `data/`, `.server-mode`, tmux session name `am-server` | nothing — upstream kept all of these stable |

## Script design

Flags mirror the Expo script: `--dir <path>`, `-y`/`--yes`, `--port` (default 4801), plus `--skip-update` (rename + remote only, for boxes the owner updates separately). Steps:

1. **Preflight** — locate the install; require git repo + tools (`git`, `tmux`, `curl`); all guards above. An already-renamed box short-circuits to the update delegation, so re-running is the plain "update to latest" path.
2. **Remote** — `git remote set-url origin <new URL>`; echo old → new.
3. **Stop** — reuse the Expo script's stop pattern (tmux `am-server` interrupt, then port-listener kill fallback). On boxes where the server matters (the dev box), the operator consents; `-y` follows the same rules as the Expo script.
4. **Move** — `mv` old → new within the same parent. Print the exact reverse command as the rollback line.
5. **Delegate** — invoke `migrate-to-expo.sh --dir <new-path> -y` for pull/install/build/restart/verify; it is layout-aware, so a box that somehow never got the Expo migration gets it here too. The two scripts ship side by side; fetch the companion from `main` when it isn't adjacent on disk.
6. **Summary** — new path, new remote, dashboard URL; a reminder that shell history, personal scripts, and SSH sessions pointing at the old path need updating by hand; rollback recipe (mv back, set-url back, restart).

## Companion changes in this repo (same PR as the script)

- `setup.sh` — `REPO_URL` → `agent-manager.git`; the 12 hardcoded `~/dev/claude-manager` occurrences (INSTALL_DIR plus the `run_as_user` command strings) → `~/dev/agent-manager`.
- `ubuntu-install.sh` / `mac-install.sh` — `REPO_URL`; `DEFAULT_DIR` → `~/dev/agent-manager` / `~/agent-manager`; the pre-Expo error hints that name the old path.
- `migrate-to-expo.sh` — probe order becomes `~/dev/agent-manager`, `~/agent-manager`, then the two legacy paths (it must keep serving un-renamed boxes); repo-name mentions in messages.
- `README.md` — paths throughout; "Updating an Existing Install" gains the rename script as the first step for old boxes; chooser table row.
- New-name clones keep working against old checkouts either way: GitHub's redirect covers fetches of the old URL until the old name is reused — which is exactly why the remote update is worth doing now, while it's a rename rather than a repair.

## Rollout

1. Land this PR (script + companion changes). Fresh installs are on the new identity immediately.
2. Run the script on the known fleet, oldest exposure first: the dev box (`~/dev/claude-manager`, live server — same care as the Expo migration run), the demo box (provisioned 2026-07-21, so it has the old directory name), the Mac mini install, and the Ubuntu developer's box (send them the one-liner).

## Open questions

- Leave a `claude-manager → agent-manager` symlink for muscle memory? Recommended no — it keeps the old name alive on disk indefinitely, which is the thing being retired; the summary's "update your shell habits" note covers the transition.
- Longer term, `migrate-to-expo.sh` has become the de-facto updater and this script is a one-time transition wrapper around it; when the fleet is fully renamed, folding both into a plain `update.sh` would be the cleaner end state. Out of scope here.
