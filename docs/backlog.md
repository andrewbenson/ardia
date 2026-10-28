# Backlog

Ideas the owner wants kept, not scheduled. Newest first. Move an item into a plan when it's picked up.

| Added | Item | Priority | Notes |
|---|---|---|---|
| 2026-10-27 | Bug watch: a deleted profile's Chromium folder stayed on disk (delete-profile-data failed 2 of 2 on the 2026-10-27 20:11 build). Not reproducible on today's tree: 7 of 7 passes | Medium, recheck after N2 | Mechanism when it fails: the profile stays loaded, so Chrome's `MaybeScheduleProfileForDeletion` never reaches the unload that deletes the folder, and our 2 s and 10 s fallbacks skip it because `GetProfileByPath` still returns the profile. Recheck: delete-profile-data 5 times plus once in the combined run after port-omnibox's N2 lands; if it fails, add engine logging for what keeps the profile loaded |
| 2026-10-26 | Air Traffic Control: rules that route links from other apps by URL pattern and source app to Little Solara, a main window, or a specific profile or space (Arc's feature; Dia has per-site `ExternalLinkRule`s too) | Low, revisit in several weeks | Link intake, profile choice and both destinations already exist (store/small.ts, the GURL handler). Build it in the Swift port: rules and matching in the core next to settings, the editor as a pane in native Settings |
| 2026-10-26 | Telemetry on Solara's own PostHog project | Deferred by the owner | Designed in docs/native/architecture.md (SolaraTelemetry); needs a PostHog project and key |
