# Journey timing in local benchmarks

The local bench enables J2 new-tab and J4 navigation timing marks with a `bench-perf` file in its isolated data folder. Solara records those marks in memory in `apps/browser/src/lib/perfMarks.ts`. `ACFieldTiming` supplies event and frame timestamps. The perf bench reads pending journeys, native marks, and timing samples through `bench-channel.js` and `ac.journeys()`. The panel frame marks are read through the dev harness. No timing data is uploaded or persisted by this module.

`native-bench.mjs` drives the journeys with posted keys and compares the same timing rows as before. `native-baseline.mjs` uses its prepared app copies for the journey phase. J1 launch remains measured by the bench's process and content marks. The release gate and ratchet metric names are unchanged. Historical field queries in previous reports describe upstream Solara data and do not apply to Solara.
