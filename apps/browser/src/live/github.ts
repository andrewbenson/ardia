import type { PullRequestCheck, PullRequestInfo } from "./types";

export type CheckSummary = {
  text: string;
  tone: "success" | "failure" | "pending" | "neutral";
  counts: { success: number; failure: number; pending: number };
};

export function summarizeChecks(checks: PullRequestCheck[]): CheckSummary | null {
  if (!checks.length) return null;
  const failure = checks.filter((c) => c.state === "failure").length;
  const pending = checks.filter((c) => c.state === "pending" || c.state === "queued").length;
  const queued = checks.filter((c) => c.state === "queued").length;
  const success = checks.length - failure - pending;
  const counts = { success, failure, pending };
  if (failure) return { text: failure === 1 ? "1 check is failing" : `${failure} checks are failing`, tone: "failure", counts };
  if (queued && queued === pending && !checks.some((c) => c.state === "success")) return { text: "Checks are queued", tone: "pending", counts };
  if (pending) return { text: "Some checks haven't completed yet", tone: "pending", counts };
  return { text: "All checks have passed", tone: "success", counts };
}

export function prBadge(pr: PullRequestInfo): "conflict" | "failing" | "changesRequested" | "pending" | "approved" | "passed" | null {
  if (pr.mergeable === "conflicting") return "conflict";
  const summary = summarizeChecks(pr.checks);
  if (summary?.tone === "failure") return "failing";
  if (pr.review === "changesRequested") return "changesRequested";
  if (summary?.tone === "pending") return "pending";
  if (pr.review === "approved") return "approved";
  if (summary?.tone === "success") return "passed";
  return null;
}
