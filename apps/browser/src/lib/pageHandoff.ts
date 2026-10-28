export const handoffLoaded = (handoff: { seq?: number } | null, seq: number | undefined) =>
  !!handoff && handoff.seq !== undefined && handoff.seq === seq;
