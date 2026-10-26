# Merging upstream Ardia

Solara is a fork of [Ardia](https://github.com/mantrakp04/ardia), fetched as the `upstream` remote. It merges
`upstream/main` now and then with a plain merge commit (no rebase, no squash), so `git log` keeps where each upstream
change came from.

```sh
git fetch upstream
git merge upstream/main -m "Merge upstream Ardia (mantrakp04/ardia main, <short sha>) into Solara"
```

Hold off while other agents are mid-edit in the checkout: a merge touches files they own, and nobody else edits or
stages while `.git/MERGE_HEAD` exists.

## What Solara removed on purpose

These are upstream's and Solara doesn't use or ship them. When upstream changes one, the merge stops with a
modify/delete conflict. **Keep it deleted:** `git rm -r <path>`, then go on.

| Path | What it was |
| --- | --- |
| `apps/site` | ardia.dev (Astro) |
| `apps/dashboard` | Upstream's stats dashboard |
| `apps/videos` | Remotion launch videos |
| `infra/site`, `infra/dashboard`, `infra/telemetry`, `infra/hexclave-cli` | Upstream's deploys, telemetry collector and ClickHouse |
| `spikes/` | The ArdiaCore spike; its test extension moved to `packages/ardiacore/scripts/fixtures/ext` |
| `CLA.md`, `.github/workflows/{cla,linked-issue,deploy}.yml`, `.github/pull_request_template.md` | Upstream's contribution and deploy process |
| `.github/workflows/release.yml`, `.github/release/` | Upstream's CI release (gated to `mantrakp04/ardia`, upstream's secrets); Solara releases from a Mac |
| `.claude/skills/stats`, `.claude/skills/elevenlabs`, `.claude/launch.json` | Upstream's telemetry report, the videos' voiceover, the site preview |
| `scripts/{stats,telemetry-env,telemetry-sql,replay,update-checks}.mjs` | Queries against upstream's telemetry |
| `docs/growth.md` | Upstream's growth and telemetry notes |
| `docs/release-notes/<version>.md` | Ardia's release notes (the style guide, `README.md`, stays) |

**Upstream's new release notes arrive as clean additions, not conflicts**, so they reappear on every merge. Remove
them in the merge commit, keeping only Solara's own:

```sh
git diff --cached --name-only --diff-filter=A -- docs/release-notes ':!docs/release-notes/README.md' | xargs git rm -q
```

A new top-level folder or file of upstream's own (a new site, deploy, telemetry or marketing tool) gets the same
treatment: remove it and add its row above.

## What Solara replaced

Keep Solara's side when these conflict, then carry over any upstream change that still applies by hand.

| Path | Solara's version |
| --- | --- |
| `README.md` | Solara's own |
| `AGENTS.md` (`CLAUDE.md` links to it) | Solara's rules; upstream's new rules may be worth copying in |
| `CONTRIBUTING.md` | Solara's process, no CLA |
| `NOTICE` | Solara's notice above Ardia's, which stays unchanged |
| `docs/agent-brief.md` | Trimmed to the architecture and tooling |
| `.claude/skills/release/SKILL.md` | Solara's release steps only; upstream's script changes (`scripts/`) merge normally |
| `apps/browser/macos/Fork.xcconfig` | Solara's identity; upstream has no such file, so it never conflicts |
| `extras/raycast-ardia` → `extras/raycast-solara` | The Raycast extension pointed at Solara. Upstream's changes to `raycast-ardia` arrive as modify/delete conflicts: keep it deleted and port the change into `raycast-solara` by hand |

Upstream's own identity stays in `apps/browser/macos/Identity.xcconfig`, and code keeps upstream's names (`Ardia*`
classes, `@ardia/*` packages, `ARDIA_*` variables, store and settings keys): renaming them would turn every upstream
merge into conflicts.

## After the merge

- `pnpm install --frozen-lockfile` (under `scripts/agent/locked pod`) and `pnpm pods` if the lockfile or a podspec moved.
- `pnpm typecheck` and `pnpm test`.
- `python3 engine/patches/series.py check` if `engine/` moved, then an incremental engine build. Check that
  `chromium-safe-storage-name.patch` and `chromium-safe-storage-no-silent-reset.patch` came through unchanged.
- An app build and a hidden launch.
