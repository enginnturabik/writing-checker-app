import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { before, describe, it } from "node:test";

process.env["ANTHROPIC_API_KEY"] = "test-key";
process.env["AUTH_SECRET"] = "test-secret-that-is-long-enough-32chars";
process.env["DATABASE_PATH"] = ":memory:";
process.env["PURCHASE_VERIFICATION"] = "mock";
process.env["FREE_TRIAL_CREDITS"] = "3";
// Off here so these suites assert on the trial and purchases alone; the free
// weekly top-up has its own test in subscriptions.test.ts.
process.env["FREE_WEEKLY_CREDITS"] = "0";
process.env["RATE_LIMIT_PER_MINUTE"] = "4";
process.env["MAX_WORDS_STANDARD"] = "600";

let app: import("hono").Hono<import("../src/types.ts").AppEnv>;

before(async () => {
  const { createApp } = await import("../src/app.ts");
  app = createApp();
});

async function register(): Promise<{ token: string; balance: number; body: any }> {
  const response = await app.request("/v1/devices", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ installId: randomUUID(), platform: "android" }),
  });
  const body = await response.json();
  return { token: body.token, balance: body.balance, body };
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

describe("device registration", () => {
  it("issues a token and the free trial credits", async () => {
    const { token, balance, body } = await register();

    assert.ok(token.length > 20);
    assert.equal(balance, 3);
    assert.equal(body.isNew, true);
    assert.ok(Array.isArray(body.products) && body.products.length > 0);
  });

  it("grants the trial only once per install id", async () => {
    const installId = randomUUID();
    const payload = {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ installId, platform: "ios" }),
    };

    await app.request("/v1/devices", payload);
    const second = await app.request("/v1/devices", payload);
    const body = await second.json();

    assert.equal(body.balance, 3, "reopening the app must not mint credits");
    assert.equal(body.isNew, false);
  });

  it("rejects a malformed install id", async () => {
    const response = await app.request("/v1/devices", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ installId: "not-a-uuid", platform: "android" }),
    });

    assert.equal(response.status, 400);
  });
});

describe("authentication", () => {
  it("refuses an unauthenticated request", async () => {
    const response = await app.request("/v1/me");
    assert.equal(response.status, 401);
  });

  it("refuses a forged token", async () => {
    const response = await app.request("/v1/me", {
      headers: { authorization: "Bearer not.a.real.token" },
    });
    assert.equal(response.status, 401);
  });

  it("returns the balance for a valid token", async () => {
    const { token } = await register();
    const response = await app.request("/v1/me", {
      headers: { authorization: `Bearer ${token}` },
    });
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.balance, 3);
  });
});

describe("purchases", () => {
  it("credits a verified purchase", async () => {
    const { token } = await register();
    const response = await app.request(
      "/v1/purchases",
      authed(token, {
        platform: "android",
        productId: "credits_40",
        token: `play-token-${randomUUID()}`,
      }),
    );
    const body = await response.json();

    assert.equal(response.status, 200);
    assert.equal(body.credited, 40);
    assert.equal(body.balance, 43, "trial credits plus the pack");
  });

  it("credits a replayed purchase token only once", async () => {
    const { token } = await register();
    const purchaseToken = `play-token-${randomUUID()}`;
    const payload = {
      platform: "android",
      productId: "credits_120",
      token: purchaseToken,
    };

    await app.request("/v1/purchases", authed(token, payload));
    const second = await app.request("/v1/purchases", authed(token, payload));
    const body = await second.json();

    assert.equal(body.credited, 0);
    assert.equal(body.alreadyProcessed, true);
    assert.equal(body.balance, 123, "3 trial + 120, not 243");
  });

  it("will not credit a token already used by another device", async () => {
    const first = await register();
    const second = await register();
    const purchaseToken = `play-token-${randomUUID()}`;
    const payload = {
      platform: "android",
      productId: "credits_40",
      token: purchaseToken,
    };

    await app.request("/v1/purchases", authed(first.token, payload));
    const response = await app.request("/v1/purchases", authed(second.token, payload));
    const body = await response.json();

    // Sharing a receipt between devices must not create credits.
    assert.equal(body.credited, 0);
    assert.equal(body.balance, 3);
  });

  it("rejects an unknown product", async () => {
    const { token } = await register();
    const response = await app.request(
      "/v1/purchases",
      authed(token, {
        platform: "android",
        productId: "credits_1000000",
        token: "whatever",
      }),
    );

    assert.equal(response.status, 400);
  });

  it("never lets the client choose the credit amount", async () => {
    const { token } = await register();
    const response = await app.request(
      "/v1/purchases",
      authed(token, {
        platform: "android",
        productId: "credits_40",
        token: `play-token-${randomUUID()}`,
        credits: 99999,
      }),
    );
    const body = await response.json();

    assert.equal(body.credited, 40);
  });
});

describe("check endpoint", () => {
  it("rejects an empty submission", async () => {
    const { token } = await register();
    const response = await app.request("/v1/check", authed(token, { text: "   " }));

    assert.equal(response.status, 400);
  });

  it("rejects a submission over the word cap before spending anything", async () => {
    const { token } = await register();
    const response = await app.request(
      "/v1/check",
      authed(token, { text: "mot ".repeat(700), tier: "quick" }),
    );
    const body = await response.json();

    assert.equal(response.status, 429);
    assert.match(body.error, /600/);

    // The balance is untouched.
    const me = await app.request("/v1/me", {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal((await me.json()).balance, 3);
  });

  it("returns 402 when the balance cannot cover the tier", async () => {
    const { token } = await register();

    // The trial is 3 credits here and a full report costs 25, so this must
    // be refused outright - before a single token is bought.
    const response = await app.request(
      "/v1/check",
      authed(token, { text: "Bonjour le monde.", tier: "report" }),
    );
    const body = await response.json();

    assert.equal(response.status, 402);
    assert.equal(body.code, "insufficient_credits");
    assert.equal(body.required, 25);

    const me = await app.request("/v1/me", {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal((await me.json()).balance, 3, "nothing was spent");
  });

  it("refunds the reservation when a check fails upstream", async () => {
    const { token } = await register();

    // An advanced check costs exactly the trial. It reserves, then fails
    // upstream because the tests carry no real API key.
    const response = await app.request(
      "/v1/check",
      authed(token, { text: "Bonjour le monde.", tier: "advanced" }),
    );
    await response.text();

    const me = await app.request("/v1/me", {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(
      (await me.json()).balance,
      3,
      "a failed check must refund its reservation",
    );
  });

  it("throttles a burst of requests", async () => {
    const { token } = await register();
    const body = { text: "Bonjour.", tier: "quick" };

    const statuses: number[] = [];
    for (let i = 0; i < 6; i++) {
      const response = await app.request("/v1/check", authed(token, body));
      statuses.push(response.status);
      await response.text();
    }

    assert.ok(
      statuses.includes(429),
      `expected a 429 in ${JSON.stringify(statuses)}`,
    );
  });
});
