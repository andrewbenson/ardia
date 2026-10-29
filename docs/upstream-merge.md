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
| `apps/demo` | The web demo of the app on ardia.dev (react-native-web, Vite); its packages leave `pnpm-lock.yaml` with it, so after a conflict there run `pnpm install --lockfile-only` |
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

- Solara's docs are in US English and upstream's aren't. On a conflict in a doc, take upstream's text, then run
  `python3 scripts/us-spelling.py $(git diff --name-only HEAD^1 HEAD -- '*.md')` once the merge is committed, and commit
  what it changes.
- `pnpm install --frozen-lockfile` (under `scripts/agent/locked pod`) and `pnpm pods` if the lockfile or a podspec moved.
- `pnpm typecheck` and `pnpm test`.
- `python3 engine/patches/series.py check` if `engine/` moved, then an incremental engine build. Check that
  `chromium-safe-storage-name.patch` and `chromium-safe-storage-no-silent-reset.patch` came through unchanged.
- An app build and a hidden launch.

## Upstream changes left out of the hand ports

Since the merge base `c508a9f3`, upstream fixes have been ported by hand, one commit each ("Port upstream <sha>: …").
These were deliberately left out. Look at them again at the next real merge:

- **Full screen** (47a04f60, 7453d055, f8a678c7, a8ce1f80, da693fe6, 595f29c8, 39bcff72, 9d9066aa, merged in
  ea46ea91). They add a new traffic-light reveal mechanism to `ArdiaCoreChromeWindow.mm` that depends on upstream's
  `hostView`, `LiveViews` and `rootViewOfWindow`, which we don't have. Porting it alongside the native shell work in
  that file is riskier than the fix is worth.
- **Tab and profile switch re-renders** (18e80d22, 2fd842a8, 5b931ed5, 65893a2a). These are perf changes built on
  upstream's state-layer refactor (`tabWatch`), which our store doesn't have.
- **881f2eab's password sealing** (`sealPassword`/`openPassword`, `savePassword` and the `pw:` → `pws:` records) is
  ported on its own, apart from that commit's recovery-phrase reauth gate.
- **Crash-report redaction** (8ea1c7bb, bbc9acf9, 1a6fb8ed, 5765641c, e6630b53, #504). Solara does not ship telemetry or its collector code.
- **Legacy password sealing** (d8e5dcbf, e6697cbc). They seal passwords that older builds stored before JS reads them.
  The review rated that exposure low, and sealing arrives with the native sync path.
- **Sync journal parts** (16223045 and its fixes 28b9714b, a3545d94, 09feed54). These cut disk writes (the state is
  saved hourly instead of each cycle) rather than fix a bug, and they collide with the sync redesign, so they went to
  the sync work instead of a hand port. 480f3627 and its revert f8772c8a cancel out.
- **Not applicable to our tree:**
  - a0a177f9 (sidebar group crash): needs 5b931ed5's shared press and slide style, which we don't have (our rows keep
    `PressFeedback`).
  - 48b52711 (address field hover buttons): ours already sit to the left of the indicators and keep their space.
  - 04e28b95 (video-upscaling-test): our `pageState` still has the `browsers` map the test reads.
  - fdce59e2 (test stub `unstable_batchedUpdates`): our app tests load without it.
  - 7233baf1 (`launchEnv.mjs` and the Debug dylib): we don't have `launchEnv.mjs`.
  - 73878d09 (pinned tab color ring): we don't have `colorRing`.
- **Features and upstream-only work, not ported:** the layer, file-split and tokens refactors; the site, meadow and demo;
  dashboards, stats, infra and release bumps; tab sleeping (ae4f421c), onboarding (78254629, 9840b49f, 15094487,
  12f65f5e, 36269777, 75ba95b1), the Dia import row (e9999df3), Liquid Glass pinned tabs (4ebffc9c), Settings'
  advanced split (9102987f), sidebar title width (fb9c3ddc, 64bd1be7), and f6d71be3's js-bench change (later).
