# hov-stack architecture: the decisions

Date 2026-10-20. Settled over seven rounds of interview on what the public repo is, what it ships, who it is for, how it is produced from the private setup, and where House of Vibe fits. The decisions are the author's. Nothing here has been acted on yet; `STRATEGY.md` carries the direction and this file carries the shape.

## Decisions

**One public repo, `StartupBros-com/hov-stack`.** The eleven plugins fold into it as `plugins/<name>/`, each keeping its own plugin.json, VERSION, tests and README, released on `<name>--v<version>` tags. That is the shape the official Claude Code plugin docs document for several plugins in one marketplace repo: "the plugin-name prefix lets one marketplace repository host several plugins with independent version histories," and `claude plugin tag --push` checks plugin.json and the manifest entry agree. Boundaries become directories instead of repos.

- **Name.** `hov-stack`, not `wstack`. The repo name is the word every star, install line, release link and announcement repeats, and the marketplace is already `hov`. `StartupBros-com/hov-stack` does not exist yet and `hov-stack` is free on npm and PyPI; a dormant GitHub user of that name exists, which does not stop the org from holding a repo by it. `wstack` has an org registered in 2015 and a same-category "Claude Code setup" repo. Amended (author, 2026-10-24): the name was spelled `hovstack` until this date; the filenames of this record and the restructure plan keep that spelling, because issue links point at them.
- **Org.** `StartupBros-com`, which holds the release App installation, the announce endpoint's owner check and the org's public repos. A `houseofvibe` org is reserved separately by creating it and transferring the existing `house-of-vibe` repo into it, so it is in active use from day one.
- **Manifest entries** are `git-subdir` with url, path and SHA, so the manifest keeps naming the exact released commit and the repin bot keeps working. Relative entries (no SHA) were rejected: they install whatever the directory holds on main at the member's update time.
- **The repo is the renamed `StartupBros-com/hov-marketplace`.** The same repo keeps the App installation, the hardened-commit lineage check and members' registration through GitHub's redirect. The staged stack and the plugins are squash-pushed into it at the public flip. The marketplace name stays `hov`, so `pro-gate@hov` installs, cache dirs and plugin data survive; a new marketplace name would force members to remove `hov`, which uninstalls their plugins and deletes their plugin data. The private staging repo is archived after the flip.
- **History, issues, PRs.** Each plugin imports squashed. Each old repo is archived with a pointer README so release links already posted keep resolving. Open issues transfer as each plugin folds in. Open PRs land or close first, since PRs cannot transfer.
- **Release train.** Every plugin and the stack itself ride the same train: one root workflow set replaces the eleven per-plugin copies, a release on `<name>--v<version>` fires the announce workflow, and the members app posts the automated card to the tool-drops channel exactly as today. Core releases announce too, on `hov-stack--v<version>`.
- **Setup is two-stage.** `./setup` stays deterministic: symlinks into `~/.claude`, the destructive-command guard installed by default with an opt-out flag and its licence disclosed, the marketplace add, and the default plugins through the scripted `claude plugin install`. Then `claude` and a guided in-session setup skill that checks the machine and walks each optional plugin, reusing the per-plugin guided setups that exist. Claude Code's own `userConfig` prompts only in-session and has no field for OS, WSL, binaries or subscriptions, so the requirement checks live here. Default set: papercut, skill-tuner, memory-dream, design-rails, plus harness-vet and rent-check once the author runs them daily. Guided opt-in: pro-gate (ChatGPT Pro), wsl-cdp (WSL2 + a Windows browser + one elevated step), token-eater, product-video, sign-it. Papercut and design-rails as plugin installs replace the copies vendored into the stack.
- **Skills also ship as one skill-pack plugin** in the `hov` marketplace, for the member who will never run `./setup`. The clone path and the plugin path never both install skills; setup skips the pack and the README says pick one.
- **Daily work after the flip**: one checkout of `hov-stack` linked into `~/.claude`, a private overlay for hosts, secrets and business tools, plugin changes as directories in the same repo. The router stays in its own repo and out of setup, the README and the manifest until its own decisions are made.

## Gates before any plugin folds in

In order:

1. The announce chain is rewritten and deployed: the endpoint's repository check becomes a constant, its registry accepts `git-subdir` entries and the prefixed tag rule, plugin name and GitHub repo become separate fields, the reusable workflow derives the plugin from the tag, and the "latest stable" guard filters by tag prefix (GitHub has one latest release per repo, so without the filter a later plugin's release would turn an earlier plugin's re-run into a green no-op). About 225 code lines across the members app, the reusable workflow and scripts, and one root workflow set that replaces eleven copies.
2. A local member-continuity test shows an installed `@hov` plugin updates cleanly when its manifest entry changes from a `url` source to `git-subdir`. Not done yet.
3. The public flip itself, because in-repo entries only resolve once the repo is public.

## Sequencing rules the announce endpoint imposes

1. The manifest cannot move until the repo hosting it is public: the members app fetches it from a raw GitHub URL. Moving it earlier silences every plugin's announcement.
2. The manifest must satisfy the registry's schema in full; one bad entry fails the whole manifest. Entries switch source shape only once the registry accepts both.
3. A repo on a user account can never announce. The rename keeps hov-stack on the org without a transfer.
4. The reusable announce workflow must keep living on the main branch the app's lineage check watches. Because the rename keeps the same repo and history, the hardened-commit lineage check stays valid.
5. The announcement fires on a GitHub release event, not on the VERSION bump as such. The bump produces the release on a prefixed tag.

Between the rename and the members-app deploy every announcement fails closed. Either the app accepts both workflow paths for the window, or the rename, the deploy and the fold-in run with no plugin release in between.

## Options set aside

| Shape | Why not |
|---|---|
| Hub and spokes: the stack repo pins the plugins, which stay in their own repos | Stars, issues and the front door stay split across twelve repos, and the announce rewrite it avoided turned out to be about 225 lines. |
| Clone and setup only, no marketplace | Throws away the one distribution channel that works today and reintroduces hand-synced copies of papercut, design-drift and memory-dream. |
| The stack root as a plugin | A plugin cannot ship settings, env or the statusline, and would carry tests and docs into every member's cache. |
| Relative `./plugins/<name>` entries | No SHA pin; members install whatever main holds at update time. |
| A separate marketplace name | One marketplace per name per user; members could only switch by removing `hov`, which deletes their plugin data. |
| Single skill-pack repo, mattpocock/skills style, for everything | Those repos are one plugin with one version (or none), no hooks, daemons or announcements. The shape fits the stack's skills as a plugin, not the eleven tools. |

## Placement

| Artifact | Home in `hov-stack` |
|---|---|
| Core: settings.json template, CLAUDE.md, hooks and guards, tests, scripts, bin, statusline | root, mirroring `~/.claude`; the statusline stays core because a plugin cannot ship it |
| HARNESS.md and the harness docs and solutions | `docs/` |
| Skills | `skills/`, with a LICENSE beside each vendored skill; also one skill-pack plugin entry in the manifest |
| mods | `mods/`, the incubator; graduation is `plugins/<name>/` with plugin.json, VERSION and a manifest entry |
| In-tree plugins not yet graduated | `plugins/<name>/`, loaded via `CLAUDE_CODE_PLUGIN_DIRS`, not in the manifest |
| Destructive-command guard config, installer, updater, doctor | `dcg/` and `config/dcg/config.toml`; the binary fetched from upstream with signature checks, licence stated in the README and at install |
| Marketplace manifest | `.claude-plugin/marketplace.json`, name `hov` |
| Announce, repin and validate workflows and scripts; release recipe; flip runbook | `.github/` and `docs/release/` |
| The eleven plugins | `plugins/<name>/`, each with its own plugin.json, VERSION, tests, README, CHANGELOG |
| Plugin defaults for setup | `lib/default-plugins.txt`, the plugins `./setup` installs; opt-ins and their prerequisites belong to the guided setup skill. Amended (author, 2026-10-24): the root `plugins.lock` record was dropped, since Claude Code already reports installed versions |
| Guided setup skill | `skills/`, orchestrating the per-plugin guided setups that already exist |
| Loop wrapper | `bin/`, part of the permission layer |
| NOTICE | `NOTICE.md` plus per-skill LICENSE files |
| Other harnesses (pi, codex, fx, windows) | `harnesses/<name>`, labeled untested |
| Private overlay | read from `~/.config/hov-stack/`; absent on a stranger's machine means the single-host default |
