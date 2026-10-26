import { PRODUCT, SERVICES } from "../lib/productName";

export const SHARING_COPY = {
  toggle: "Share anonymous crash reports and usage stats",
  summary: "Crashes, errors, rough feature counts and speed. Never the sites you visit, anything you type or search, or what's in your tabs.",
  whatsSent: "What's Sent",
  footnote: SERVICES.telemetryHost
    ? `Sent to ${SERVICES.telemetryHost} with a random ID made on this Mac, and kept on our own servers. No third parties. Turning this off stops it at once and deletes anything waiting to be sent. This setting doesn't sync.`
    : `Nothing is sent: this copy of ${PRODUCT} has no diagnostics server.`,
  ask: {
    title: `Help fix ${PRODUCT}?`,
    body: "Share anonymous crash reports and usage stats. No sites, searches or typing. Ever.",
    share: "Share",
    notNow: "Not now",
  },
  dailyCount: SERVICES.telemetryHost
    ? "One anonymous “opened today” count a day: app version, update channel, macOS version, chip, and whether it's this copy's first day, week or month. No persistent ID."
    : "No “opened today” count: nothing is sent.",
  dailyCountShort: SERVICES.telemetryHost
    ? `Either way, ${PRODUCT} sends one anonymous “opened today” count a day, with its version and macOS version and no persistent ID.`
    : `${PRODUCT} sends nothing: no crash reports, no usage stats, no daily count.`,
  updateChecks: SERVICES.updateHost
    ? `${SERVICES.updateHost} counts update checks by version and day, and whether it's this copy's first. Nothing else.`
    : "No update checks: nothing is sent.",
  switchFile: SERVICES.switchFile
    ? `While update checks are on, each launch also reads ${SERVICES.switchFile}: one small file, the same for everyone, that lets us turn off a speed-up that misbehaves. It sends no ID, no cookies and nothing about you.`
    : "No switch file is read at launch: nothing is sent.",
  onboarding: {
    title: "Help us fix what breaks",
    row: "Crashes, errors, feature counts and speed. Never your sites, typing or tabs.",
    subtitle: SERVICES.telemetryHost
      ? `Off unless you turn it on; change it any time in Settings › Privacy & Security. Either way, ${PRODUCT} sends one anonymous “opened today” count a day, with its version and macOS version and no persistent ID.`
      : `${PRODUCT} sends nothing: no crash reports, no usage stats, no daily count.`,
  },
} as const;

export const WHATS_SENT: { title: string; items: string[] }[] = [
  {
    title: "With everything",
    items: [
      "A random install ID, made on this Mac (a new one each time sharing is turned back on)",
      "App version and build, macOS version, chip (arm64 or x86_64), engine version",
      "Whether it's a test build",
    ],
  },
  {
    title: "Crashes and errors",
    items: [
      "The error's type and message, with web addresses, paths, file names, quoted text and long numbers taken out",
      "Function names, script file names and line numbers from the stack trace",
      "After a crash: the exception type and name (never its message), and the function names where it was thrown and on the crashing thread, from this app's crash report",
      "Warning and error log lines, cleaned the same way",
    ],
  },
  {
    title: "Usage",
    items: [
      "Launches, updates, and whether the last session ended cleanly",
      "How many tabs and windows you open (a count, not which)",
      "Opening split view, switching profiles and opening the command bar",
      "The kind of command bar row you pick: history, bookmark, tab, address, search, calculator or action",
      "Installing an extension, turning sync on or off, translating a page, and which Settings sections you open",
    ],
  },
  {
    title: "Speed",
    items: [
      "Time to the first window, profile switch time, and command bar speed (a sample of keystrokes)",
      "How long launches, new tabs, tab switches and page loads take, step by step: times and counts only, summed up once an hour",
      "At launch, in rough ranges: how many tabs and windows came back, how much history there is, and whether it's the first launch since the Mac started",
      "Memory use and the number of tabs, once an hour",
    ],
  },
  {
    title: "Even with sharing off",
    items: [SHARING_COPY.dailyCount, SHARING_COPY.updateChecks, SHARING_COPY.switchFile],
  },
  {
    title: "Never",
    items: [
      "Web addresses, site names or page titles",
      "Anything you type or search for",
      "History, bookmarks, passwords or what's in your tabs",
      "Profile, extension or file names",
      "Screen recordings",
    ],
  },
];
