const HELP = `Records apps/browser/src/live's answers for SolaraLive's golden tests.

  node --no-warnings --import ./apps/browser/src/test-loader.mjs native/SolaraKit/Scripts/live-golden.mts [--out <file>]

Runs the TypeScript Live engine's pure functions (GitHub mapping and stacks, document mappers, folder rows,
check summaries, meeting detection, alert timing, error text, date parsing) over the fixtures and a fixed
corpus, and writes inputs with their outputs as JSON. --out defaults to Tests/SolaraLiveTests/Fixtures/golden.json.`;

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

if (process.argv.includes("--help")) {
  console.log(HELP);
  process.exit(0);
}

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, "../../..");
const live = join(repo, "apps/browser/src/live");
const outIndex = process.argv.indexOf("--out");
const out = outIndex > 0 ? process.argv[outIndex + 1] : join(here, "../Tests/SolaraLiveTests/Fixtures/golden.json");

const github = await import(join(live, "github.ts"));
const documents = await import(join(live, "documents.ts"));
const rows = await import(join(live, "rows.ts"));
const meetings = await import(join(live, "meetings.ts"));
const engine = await import(join(live, "engine.ts"));

const load = (name: string) => JSON.parse(readFileSync(join(live, "fixtures", name), "utf8"));
const plain = (value: unknown) => JSON.parse(JSON.stringify(value ?? null));

const fixture = load("github.json");
const filterCases = [
  { authored: true, reviewRequests: true },
  { authored: true, reviewRequests: false },
  { authored: false, reviewRequests: true },
  { authored: false, reviewRequests: false },
];
const mapGithub = filterCases.map((filters) => ({ filters, items: plain(github.mapGithub(fixture, filters)), detailIds: github.detailIds(fixture, filters) }));

const pr = (id: string, number: number, headRef: string, baseRef: string, repo = "o/r", section = "authored") => ({
  id,
  source: "github",
  url: `https://github.com/${repo}/pull/${number}`,
  title: `PR ${number}`,
  subtitle: `${repo} #${number}`,
  icon: null,
  updatedAt: number * 1000,
  section,
  pr: { number, repo, author: "a", authorAvatar: null, draft: false, headRef, baseRef, review: null, mergeable: "unknown", checks: [], comments: 0, unresolvedThreads: 0, additions: 0, deletions: 0, changedFiles: 0 },
});
const stackInputs = [
  [pr("a", 1, "one", "main"), pr("b", 2, "two", "one"), pr("c", 3, "three", "main")],
  [pr("c", 3, "three", "two"), pr("a", 1, "one", "main"), pr("b", 2, "two", "one"), pr("d", 4, "four", "one")],
  [pr("x", 7, "loop-a", "loop-b"), pr("y", 8, "loop-b", "loop-a"), pr("z", 9, "solo", "main")],
  [pr("p", 5, "feat", "main", "o/one"), pr("q", 6, "next", "feat", "o/two"), pr("r", 2, "next", "feat", "o/one")],
  [pr("m", 10, "same", "main"), pr("n", 11, "same", "main"), pr("o", 12, "top", "same")],
];
const withStacks = stackInputs.map((items) => ({ items, out: plain(github.withStacks(items)) }));

const fixtureItems = github.mapGithub(fixture, filterCases[0]);
const many = Array.from({ length: 11 }, (_, i) => pr(`k${i}`, 100 + i, `h${i}`, i % 3 === 0 ? "main" : `h${i - 1}`, "o/r", i % 2 ? "review" : "authored"));
const docItems = documents.mapNotion(load("notion-search.json"), load("notion-users.json"), "Acme");
const rowCases = [
  { folder: { id: "f", kind: "pullRequests", groupStacks: true }, items: fixtureItems, showAll: {}, page: 8 },
  { folder: { id: "f", kind: "pullRequests", groupStacks: false }, items: fixtureItems, showAll: {}, page: 8 },
  { folder: { id: "f", kind: "pullRequests", groupStacks: true }, items: fixtureItems, showAll: {}, page: 1 },
  { folder: { id: "f", kind: "pullRequests", groupStacks: true }, items: fixtureItems, showAll: { "f:authored": true }, page: 1 },
  { folder: { id: "g", kind: "pullRequests", groupStacks: true }, items: github.withStacks(many), showAll: {}, page: 2 },
  { folder: { id: "g", kind: "pullRequests", groupStacks: false }, items: github.withStacks(many), showAll: { "g:review": true }, page: 2 },
  { folder: { id: "d", kind: "documents", groupStacks: true }, items: docItems, showAll: {}, page: 2 },
  { folder: { id: "d", kind: "documents", groupStacks: true }, items: docItems, showAll: { "d:documents": true }, page: 2 },
].map((c) => ({ ...c, items: plain(c.items), rows: plain(rows.folderRows(c.folder, c.items, c.showAll, c.page)) }));

const checkCases = [
  [],
  [{ name: "a", state: "success", url: null }],
  [{ name: "a", state: "success", url: null }, { name: "b", state: "failure", url: null }],
  [{ name: "a", state: "failure", url: null }, { name: "b", state: "failure", url: null }],
  [{ name: "a", state: "queued", url: null }],
  [{ name: "a", state: "queued", url: null }, { name: "b", state: "neutral", url: null }],
  [{ name: "a", state: "queued", url: null }, { name: "b", state: "success", url: null }],
  [{ name: "a", state: "pending", url: null }, { name: "b", state: "queued", url: null }],
  [{ name: "a", state: "neutral", url: null }],
];
const checks = [...checkCases, ...fixtureItems.map((it: { pr: { checks: unknown[] } }) => it.pr.checks)].map((c) => ({ checks: c, summary: plain(github.summarizeChecks(c)) }));
const badgePrs = [
  ...fixtureItems.map((it: { pr: unknown }) => it.pr),
  { ...fixtureItems[0].pr, mergeable: "conflicting" },
  { ...fixtureItems[0].pr, checks: [], review: "changesRequested" },
  { ...fixtureItems[0].pr, checks: [], review: "approved" },
  { ...fixtureItems[0].pr, checks: [], review: null },
  { ...fixtureItems[0].pr, checks: [{ name: "a", state: "pending", url: null }], review: "approved" },
];
const badges = badgePrs.map((p) => ({ pr: plain(p), badge: github.prBadge(p) }));

const bitbucketPR = { id: 7, title: "Bitbucket: tidy pipelines", updated_on: "2026-09-25T06:00:00Z", comment_count: 2, author: { display_name: "Octo Dev" }, source: { branch: { name: "tidy" } }, destination: { branch: { name: "main" }, repository: { full_name: "acme/pipelines" } }, links: { html: { href: "https://bitbucket.org/acme/pipelines/pull-requests/7" } }, participants: [{ role: "REVIEWER", state: "approved" }] };
const bitbucketStatuses = { values: [{ state: "SUCCESSFUL", name: "Pipeline #12", url: "u12" }, { state: "FAILED", name: "f", url: "uf" }, { state: "STOPPED", name: "s", url: "us" }, { state: "INPROGRESS", name: "i", url: "ui" }] };
const bitbucketChanges = { ...bitbucketPR, draft: true, author: { display_name: "B", links: { avatar: { href: "https://avatar" } } }, participants: [{ role: "REVIEWER", state: "approved" }, { role: "REVIEWER", state: "changes_requested" }, { role: "PARTICIPANT", state: null }] };
const bitbucketNoReviewers = { ...bitbucketPR, participants: [{ role: "PARTICIPANT", state: "approved" }] };
const bitbucketPending = { ...bitbucketPR, participants: [{ role: "REVIEWER", state: null }] };
const confluence = load("confluence-search.json");
const docs = {
  notion: plain(documents.mapNotion(load("notion-search.json"), load("notion-users.json"), "Acme")),
  notionNoUsers: plain(documents.mapNotion(load("notion-search.json"), null, null)),
  confluence: plain(documents.mapConfluence(confluence, "https://acme.atlassian.net")),
  confluenceNoBase: plain(documents.mapConfluence({ results: confluence.results }, "https://acme.atlassian.net/")),
  drive: plain(documents.mapDrive(load("drive-files.json"))),
  bitbucket: [
    { pr: bitbucketPR, statuses: bitbucketStatuses, item: plain(documents.mapBitbucket(bitbucketPR, bitbucketStatuses)) },
    { pr: bitbucketChanges, statuses: null, item: plain(documents.mapBitbucket(bitbucketChanges, null)) },
    { pr: bitbucketNoReviewers, statuses: null, item: plain(documents.mapBitbucket(bitbucketNoReviewers, null)) },
    { pr: bitbucketPending, statuses: null, item: plain(documents.mapBitbucket(bitbucketPending, null)) },
  ],
};

const urls = [
  "https://meet.google.com/abc-defg-hij",
  "https://meet.google.com/ABC-DEFG-HIJ?authuser=1",
  "https://meet.google.com/abc-defg-hijk",
  "https://meet.google.com/abcd-efgh-ijkl/extra",
  "https://meet.google.com/lookup/abc",
  "https://meet.google.com/",
  "https://acme.zoom.us/j/81234567890?pwd=abc",
  "https://zoom.us/s/123.45-6",
  "https://us02web.zoom.us/wc/join/987654",
  "https://zoom.us/wc/123456/join",
  "https://zoom.us/my/Octo.Dev",
  "https://zoom.com/w/55",
  "https://zoom.us/support",
  "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d",
  "https://teams.live.com/meet/9876543210",
  "https://teams.cloud.microsoft/v2/?meetingjoin=true#/l/meetup-join/19:x",
  "https://teams.microsoft.com/v2/",
  "https://teams.microsoft.com/l/channel/19%3a",
  "https://acme.webex.com/meet/octo",
  "https://acme.webex.com/acme/j.php?MTID=m1",
  "https://acme.webex.com/join/octo",
  "https://acme.webex.com/webappng/sites/acme",
  "https://calendar.google.com/calendar/u/0/r",
  "https://calendar.notion.so/",
  "https://calendar.proton.me/u/0",
  "https://app.fantastical.com/",
  "https://outlook.office.com/calendar/view/week",
  "https://outlook.live.com/mail/0/",
  "https://outlook.cloud.microsoft/calendar/",
  "https://outlook.office365.com/calendar",
  "https://www.icloud.com/calendar/",
  "https://icloud.com/mail",
  "https://Calendar.Google.com/",
  "not a url",
  "",
  "https://docs.google.com/document/d/spec123/edit",
];
const urlCases = urls.map((url) => ({ url, meetingOf: plain(meetings.meetingOf(url)), isCalendarUrl: meetings.isCalendarUrl(url), isMeetingUrl: meetings.isMeetingUrl(url) }));

const linkTexts = [
  { url: "", location: "https://meet.google.com/abc-defg-hij", notes: "" },
  { url: "https://example.com/agenda.", location: "Room 4, https://zoom.us/j/123,", notes: "See (https://docs.google.com/document/d/x) and https://support.google.com/a/users/answer/1; tel.example.com https://tel.example.com/x https://aka.ms/JoinTeamsMeeting https://www.figma.com/file/xyz" },
  { url: "https://teams.microsoft.com/l/meetup-join/abc", location: "", notes: "<https://acme.atlassian.net/wiki/x> 'https://github.com/acme/browser/pull/1' https://github.com/acme/browser/pull/1 https://apple.com/x https://zoom.us/support https://calendar.google.com/x https://meet.google.com/xyz https://go.microsoft.com/fwlink" },
  { url: null, location: null, notes: "nothing here" },
  { url: "", location: "", notes: "https://meet.google.com/lookup/abc then https://acme.zoom.us/my/room]" },
];
const links = linkTexts.map((e) => ({ event: e, joinLink: plain(meetings.joinLink(e)), relatedLinks: meetings.relatedLinks(e) }));

const calendarFixture = load("calendar-fixture.json");
const base = Date.UTC(2026, 9, 26, 15, 0, 0);
const events = calendarFixture.events.map(({ startInMinutes, durationMinutes, ...e }: { startInMinutes: number; durationMinutes: number; id: string }) => {
  const start = base + startInMinutes * 60_000;
  return { ...e, start, end: start + durationMinutes * 60_000, occurrence: `${e.id}@${start}` };
});
const offsets = [-120, -50, -40, -36, -35, -5, -2, -1, 0, 0.5, 1, 1.5, 2, 3, 6, 7, 30, 31, 60, 74, 75, 76, 105, 140, 179, 181, 300, 400, 2000];
const timeline = offsets.map((minutes) => {
  const now = base + minutes * 60_000;
  const dismissed = new Set(minutes > 100 ? [`allhands@${base + 180 * 60_000}`] : []);
  return {
    minutes,
    now,
    currentOrNext: meetings.currentOrNext(events, now)?.occurrence ?? null,
    badgeText: meetings.badgeText(events, now),
    badgeText30: meetings.badgeText(events, now, 30 * 60_000),
    dueAlerts: Object.fromEntries([0, 1, 2, 3, 5, 10].map((lead) => [String(lead), meetings.dueAlerts(events, now, lead, dismissed).map((e: { occurrence: string }) => e.occurrence)])),
    dismissed: [...dismissed],
    eventForCall: ["https://meet.google.com/abc-defg-hij", "https://acme.zoom.us/j/81234567890", "https://zoom.us/j/1"].map((u) => meetings.eventForCall(events, u, now)?.occurrence ?? null),
  };
});
const eventFacts = events.map((e: { occurrence: string; attendees: unknown[] }) => ({
  occurrence: e.occurrence,
  joinLink: plain(meetings.joinLink(e)),
  relatedLinks: meetings.relatedLinks(e),
  attendeesLabel: meetings.attendeesLabel(e),
  guestsLabel: meetings.guestsLabel(e),
  isMeeting: meetings.isMeeting(e),
}));
const attendeeCases = [
  [],
  [{ name: "", email: "solo@x.com", status: "accepted", me: false }],
  [{ name: "", email: "", status: "accepted", me: false }, { name: "Me", email: "me@x", status: "accepted", me: true }],
  [{ name: "A", email: "a@x", status: "accepted", me: false }, { name: "B", email: "b@x", status: "accepted", me: false }],
  [{ name: "A", email: "a@x", status: "accepted", me: false }, { name: "", email: "@x", status: "accepted", me: false }, { name: "C", email: "c@x", status: "accepted", me: false }, { name: "D", email: "d@x", status: "accepted", me: false }],
].map((attendees) => ({ attendees, attendeesLabel: meetings.attendeesLabel({ attendees }), guestsLabel: meetings.guestsLabel({ attendees }) }));

const deltas = [-1e9, -90_061_000, -86_400_000, -3_600_000, -3_599_999, -61_000, -60_000, -59_999, -30_000, -29_999, 0, 29_999, 30_000, 59_999, 60_000, 60_001, 3_540_000, 3_600_000, 3_660_000, 5_400_000, 86_400_000, 172_800_000];
const time = deltas.map((delta) => ({
  delta,
  relativeTime: meetings.relativeTime(base + delta, base),
  ago: meetings.ago(base - delta, base),
  timeRemaining: meetings.timeRemaining(base + delta, base),
}));

const kinds = ["signedOut", "sso", "rateLimited", "network", "notConfigured", "other"];
const sources = ["github", "bitbucket", "notion", "confluence", "gdrive"];
const errorText = kinds.flatMap((kind) => sources.map((source) => ({ kind, source, text: engine.errorText(kind, source) })));

const dateStrings = [
  "2026-09-25T09:00:00Z",
  "2026-09-25T08:30:00.000Z",
  "2026-09-25T06:00:00.123456+00:00",
  "2026-09-25T06:00:00+02:00",
  "2026-09-25T06:00:00.5-07:30",
  "2026-09-25",
  "2026-09",
  "2026",
  "",
  "garbage",
  "2026-13-01T00:00:00Z",
  "1970-01-01T00:00:00.000Z",
  "1969-12-31T23:59:59.999Z",
];
const dates = dateStrings.map((text) => ({ text, ms: Date.parse(text) || 0 }));

const uriStrings = ["a b&c=d", "Ω≈ç√", "-_.!~*'()", "/?#[]@", "😀", "type=page AND (contributor=currentUser())"];
const uri = uriStrings.map((text) => ({ text, encoded: encodeURIComponent(text) }));

const T = 1_790_000_000_000;
const realNow = Date.now;
Date.now = () => T;
const store = await import(join(live, "store.ts"));
const replay: { op: string; args: unknown[] }[] = [];
const record = (op: string, ...args: unknown[]) => {
  replay.push({ op, args: plain(args) });
  return (store as Record<string, (...a: unknown[]) => unknown>)[op](...args);
};
const prs = github.mapGithub(fixture, filterCases[0]);
const f1 = record("createFolder", "p", "pullRequests", ["github"]) as string;
const f2 = record("createFolder", "p", "documents") as string;
record("applyFetch", f1, prs, {}, T);
record("applyFetch", f1, prs.slice(2), { [prs[0].id]: "merged", [prs[1].id]: "reviewed" }, T + 1000);
record("hideItems", f1, [prs[2]]);
record("markRead", f1, [prs[3].id]);
const notionItems = documents.mapNotion(load("notion-search.json"), load("notion-users.json"), "Acme");
const driveItems = documents.mapDrive(load("drive-files.json"));
record("applyFetch", f2, notionItems, {}, T + 2000);
const quiet = driveItems.slice(0, 1).map((it: { id: string }) => it.id);
replay.push({ op: "applyFetch", args: plain([f2, [...notionItems, ...driveItems], {}, T + 3000, quiet]) });
store.applyFetch(f2, [...notionItems, ...driveItems], {}, T + 3000, new Set(quiet));
record("finishCompleting", f1, [prs[0].id]);
record("updateFolder", f1, { name: "Mine", groupStacks: false, after: null });
record("arrangeFolders", [{ id: f2, after: "tab1" }, { id: f1, after: null }]);
record("setAccount", "github", { login: "octo-dev", name: null, avatar: "https://a", connectedAt: T });
record("setAccount", "notion", { login: "Acme", name: "Acme", avatar: null, connectedAt: T });
record("setAccount", "notion", null);
record("updateConfig", { bitbucketUser: "octo", confluenceSite: "https://acme.atlassian.net" });
record("updateCalendarSettings", { alertLead: "5", hiddenCalendarIds: ["home"], prompted: true });
record("dismissAlert", "standup@1");
record("dismissAlert", "standup@1");
record("setMeetingGroup", { groupId: "g1", callTabId: "t1", occurrence: null, title: "Meeting", start: null, end: null, endedAt: null });
record("setMeetingGroup", { groupId: "g2", callTabId: "t2", occurrence: "o@1", title: "Design", start: T, end: T + 60_000, endedAt: T + 1 });
record("setMeetingGroup", null, "g1");
const s = store.live();
const persisted = ["folders", "folderOrder", "items", "known", "unread", "hidden", "completed", "expandedStacks", "accounts", "config", "calendar", "meetingGroups", "dismissedAlerts"];
const stateReplay = { now: T, replay, persisted: JSON.stringify(Object.fromEntries(persisted.map((k) => [k, s[k]]))), status: plain(s.status), completing: plain(s.completing) };
Date.now = realNow;

const golden = { mapGithub, withStacks, rows: rowCases, checks, badges, docs, urlCases, links, calendar: { base, events, timeline, eventFacts }, attendeeCases, time, errorText, dates, uri, stateReplay };
writeFileSync(out, JSON.stringify(golden, null, 1) + "\n");
console.log(`wrote ${out}`);
process.exit(0);
