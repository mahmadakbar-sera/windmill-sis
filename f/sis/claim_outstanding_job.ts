// Windmill script: f/sis/claim_outstanding_job (language: bun)
//
// API-CL-34 Job Outstanding (IA Claim · 11 §5). Plays the role IA gives to
// AWS Step Functions: call the endpoint, loop while `hasMore`, retry on 5xx,
// skip on 409, fail (→ schedule error handler) on anything else.
//
// Scheduled every hour at minute 5, Asia/Jakarta (f/sis/claim_outstanding_hourly).
//
// `limit`: one call with `?limit=`, no `hasMore` loop, so a run moves at most
// that many claims. The schedule passes 50, capping the CLAIM_OUTSTANDING
// emails per tick (24 Nov: a full run sent thousands at once). Empty = full
// run with the `hasMore` loop.

import * as wmill from "windmill-client";

/** IA §5: call again while `hasMore`, at most 10 calls per schedule tick. */
const MAX_CALLS = 10;
/** IA §5: 500 → retry 2 times, 30 s apart, then fail. */
const MAX_RETRIES = 2;
const RETRY_DELAY_MS = 30_000;
/** Above the endpoint's 25 s budget plus one claim's transaction. */
const REQUEST_TIMEOUT_MS = 45_000;

type JobResult = {
  processed: number;
  updated: number;
  skipped: number;
  failed: number;
  hasMore: boolean;
  runAt: string;
};

type Outcome =
  | { kind: "OK"; transactionId: string; data: JobResult }
  | { kind: "JOB_RUNNING" };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function callOnce(url: string, apiKey: string): Promise<Outcome> {
  for (let attempt = 0; ; attempt++) {
    let status = 0;
    let body = "";
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "x-api-key": apiKey },
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      status = res.status;
      body = await res.text();
    } catch (err) {
      // Network error / timeout: treat like a 5xx.
      body = String(err);
    }

    if (status === 200) {
      const json = JSON.parse(body);
      return { kind: "OK", transactionId: json.transactionId, data: json.data };
    }
    if (status === 409) {
      return { kind: "JOB_RUNNING" };
    }
    // 4xx other than 409 (401: wrong key): retrying will not help.
    if (status >= 400 && status < 500) {
      throw new Error(`HTTP ${status}: ${body}`);
    }
    if (attempt >= MAX_RETRIES) {
      throw new Error(
        `HTTP ${status || "network error"} after ${attempt + 1} attempts: ${body}`,
      );
    }
    console.log(`attempt ${attempt + 1} failed (${status || body}); retrying in 30 s`);
    await sleep(RETRY_DELAY_MS);
  }
}

export async function main(
  base_url_variable = "f/sis/claim_service_base_url",
  api_key_variable = "f/sis/claim_internal_api_key",
  /** Max claims (1..1000) for a single call; the schedule passes 50. Empty = full run. */
  limit?: number,
) {
  const baseUrl = (await wmill.getVariable(base_url_variable)).replace(/\/$/, "");
  const apiKey = await wmill.getVariable(api_key_variable);
  const capped = limit !== undefined && limit !== null;
  const url =
    `${baseUrl}/internal/v1/claims/jobs/outstanding` +
    (capped ? `?limit=${limit}` : "");
  const maxCalls = capped ? 1 : MAX_CALLS;

  const calls: Array<{ transactionId: string } & JobResult> = [];
  for (let i = 0; i < maxCalls; i++) {
    const outcome = await callOnce(url, apiKey);
    if (outcome.kind === "JOB_RUNNING") {
      console.log("409 JOB_RUNNING: another run holds the lock, skipping");
      return { skipped: "JOB_RUNNING", calls };
    }
    calls.push({ transactionId: outcome.transactionId, ...outcome.data });
    console.log(JSON.stringify(calls[calls.length - 1]));
    if (!outcome.data.hasMore) break;
  }

  const total = calls.reduce(
    (sum, c) => ({
      processed: sum.processed + c.processed,
      updated: sum.updated + c.updated,
      skipped: sum.skipped + c.skipped,
      failed: sum.failed + c.failed,
    }),
    { processed: 0, updated: 0, skipped: 0, failed: 0 },
  );
  const hasMore = calls.length > 0 && calls[calls.length - 1].hasMore;
  if (hasMore) {
    console.log(
      capped
        ? `limit ${limit} reached; eligible claims may remain`
        : `still hasMore after ${MAX_CALLS} calls; the next tick continues`,
    );
  }
  return { ...total, hasMore, calls };
}
