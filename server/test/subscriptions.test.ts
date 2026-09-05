import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { before, describe, it } from "node:test";

process.env["ANTHROPIC_API_KEY"] = "test-key";
process.env["AUTH_SECRET"] = "test-secret-that-is-long-enough-32chars";
process.env["DATABASE_PATH"] = ":memory:";
process.env["PURCHASE_VERIFICATION"] = "mock";
process.env["FREE_TRIAL_CREDITS"] = "0";
process.env["FREE_WEEKLY_CREDITS"] = "5";

type App = Awaited<ReturnType<typeof load>>;

async function load() {
  const { createApp } = await import("../src/app.ts");
  return createApp();
}

let app: App;
let subs: typeof import("../src/subscriptions.ts");
let credits: typeof import("../src/credits.ts");

before(async () => {
  app = await load();
  subs = await import("../src/subscriptions.ts");
  credits = await import("../src/credits.ts");
});

async function register() {
  const response = await app.request("/v1/devices", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ installId: randomUUID(), platform: "android" }),
  });
  return (await response.json()) as { token: string; userId: string; balance: number };
}

function authed(token: string, body: unknown) {
  return {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  };
}

const subscribe = (token: string, productId: string) =>
  app.request(
    "/v1/subscriptions",
    authed(token, {
      platform: "android",
      productId,
      token: `play-sub-${randomUUID()}`,
    }),
  );

const me = async (token: string) =>
  (await (
    await app.request("/v1/me", { headers: { authorization: `Bearer ${token}` } })
  ).json()) as { balance: number; entitlement: { planId: string; status: string } };

describe("subscribing", () => {
  it("grants the plan's allowance", async () => {
    const { token } = await register();

    const body = (await (await subscribe(token, "sub_exam_monthly")).json()) as {
      granted: number;
      balance: number;
      entitlement: { planId: string };
    };

    assert.equal(body.granted, 250);
    assert.equal(body.entitlement.planId, "exam");
  });

  it("grants one allowance per month, however often it is restored", async () => {
    const { token } = await register();
    const purchaseToken = `play-sub-${randomUUID()}`;
    const payload = {
      platform: "android",
      productId: "sub_writer_monthly",
      token: purchaseToken,
    };

    await app.request("/v1/subscriptions", authed(token, payload));
    // Restoring purchases on a new device replays exactly this call.
    await app.request("/v1/subscriptions", authed(token, payload));
    await app.request("/v1/subscriptions", authed(token, payload));

    assert.equal(
      (await me(token)).balance,
      125,
      "120 from the plan plus the 5 free credits held before subscribing, not 360",
    );
  });

  it("refuses a plan the store does not sell", async () => {
    const { token } = await register();
    const response = await subscribe(token, "sub_free_forever");
    assert.equal(response.status, 400);
  });

  it("reports the plan an expired subscriber falls back to", async () => {
    const { token, userId } = await register();
    await subscribe(token, "sub_exam_monthly");

    subs.expireSubscription(subs.subscriptionOf(userId)!.store_ref);

    const after = await me(token);
    assert.equal(after.entitlement.planId, "free");
    assert.equal(
      after.balance,
      255,
      "credits already granted are kept - that month was paid for",
    );
  });
});

describe("the free allowance", () => {
  it("tops a new account up to the weekly allowance", async () => {
    const { token } = await register();
    assert.equal((await me(token)).balance, 5);
  });

  it("tops up rather than adds, so it cannot be hoarded", async () => {
    const { token } = await register();
    await me(token);
    await me(token);
    await me(token);

    assert.equal((await me(token)).balance, 5, "not 20");
  });

  it("does not top up a paying subscriber", async () => {
    const { token } = await register();
    await subscribe(token, "sub_exam_monthly");

    // 250 from the plan, plus the 5 free credits this account held before it
    // subscribed. What matters is that repeated calls add nothing further.
    const first = (await me(token)).balance;
    await me(token);
    await me(token);

    assert.equal(first, 255);
    assert.equal((await me(token)).balance, 255, "a subscriber is never topped up");
  });

  it("cannot accumulate into a free full report", async () => {
    const { token, userId } = await register();
    await me(token);

    // Six quiet weeks. An allowance that added rather than levelled would
    // reach 30 credits here, buying a full report nobody paid for.
    const week = 7 * 86_400_000;
    for (let i = 1; i <= 6; i++) {
      subs.refreshFreeAllowance(userId, Date.now() + i * week);
    }
    const balance = credits.balanceOf(userId);

    assert.equal(balance, 5, "an idle free account stays at one week's worth");
    assert.ok(balance < 25, "and can never reach the price of a full report");
  });
});

describe("allowance accounting", () => {
  it("keys a month by its first UTC day", () => {
    const jan = subs.monthBucket(Date.UTC(2026, 0, 17, 13, 45));
    const alsoJan = subs.monthBucket(Date.UTC(2026, 0, 2, 0, 0));
    const feb = subs.monthBucket(Date.UTC(2026, 1, 1, 0, 0));

    assert.equal(jan, alsoJan, "same month, same allowance");
    assert.notEqual(jan, feb, "a new month is a new allowance");
  });

  it("numbers ISO weeks from Monday", () => {
    // 2026-01-01 is a Thursday, so it belongs to week 1.
    assert.equal(subs.isoWeek(Date.UTC(2026, 0, 1)), "2026-W01");
    assert.equal(subs.isoWeek(Date.UTC(2026, 0, 5)), "2026-W02");
  });
});
