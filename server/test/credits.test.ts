import assert from "node:assert/strict";
import { before, describe, it } from "node:test";

process.env["ANTHROPIC_API_KEY"] = "test-key";
process.env["AUTH_SECRET"] = "test-secret-that-is-long-enough-32chars";
process.env["DATABASE_PATH"] = ":memory:";
process.env["PURCHASE_VERIFICATION"] = "mock";

type CreditsModule = typeof import("../src/credits.ts");
type DbModule = typeof import("../src/db.ts");

let credits: CreditsModule;
let dbModule: DbModule;

before(async () => {
  dbModule = await import("../src/db.ts");
  credits = await import("../src/credits.ts");
  dbModule.migrate();
});

let seq = 0;
function makeUser(): string {
  const id = `user-${++seq}`;
  dbModule.db
    .prepare(
      "INSERT INTO users (id, install_id, platform, blocked, created_at) VALUES (?, ?, 'test', 0, ?)",
    )
    .run(id, `install-${id}`, Date.now());
  return id;
}

describe("credit ledger", () => {
  it("starts every user at zero", () => {
    assert.equal(credits.balanceOf(makeUser()), 0);
  });

  it("adds granted credits to the balance", () => {
    const user = makeUser();
    assert.equal(credits.grant(user, 12, "purchase", "token-a"), true);
    assert.equal(credits.balanceOf(user), 12);
  });

  it("ignores a replayed grant with the same ref", () => {
    const user = makeUser();
    credits.grant(user, 12, "purchase", "token-b");
    const second = credits.grant(user, 12, "purchase", "token-b");

    assert.equal(second, false, "the replay should report that it did nothing");
    assert.equal(credits.balanceOf(user), 12, "and must not double-credit");
  });

  it("lets the same ref credit two different users", () => {
    const first = makeUser();
    const second = makeUser();
    // Refs are only unique per user, so a shared trial id is not blocked.
    assert.equal(credits.grant(first, 3, "grant", "trial:shared"), true);
    assert.equal(credits.grant(second, 3, "grant", "trial:shared"), true);
  });

  it("refuses a non-positive grant", () => {
    const user = makeUser();
    assert.throws(() => credits.grant(user, 0, "grant", "zero"), /positive/);
  });

  it("debits a reservation and reports the remaining balance", () => {
    const user = makeUser();
    credits.grant(user, 10, "purchase", "token-c");

    const remaining = credits.reserve(user, 3, "check-1");

    assert.equal(remaining, 7);
    assert.equal(credits.balanceOf(user), 7);
  });

  it("refuses to reserve more than the balance", () => {
    const user = makeUser();
    credits.grant(user, 2, "purchase", "token-d");

    assert.throws(
      () => credits.reserve(user, 3, "check-2"),
      (error: unknown) =>
        error instanceof credits.InsufficientCredits &&
        error.balance === 2 &&
        error.required === 3,
    );
    assert.equal(credits.balanceOf(user), 2, "a refused reservation spends nothing");
  });

  it("restores credits when a check fails", () => {
    const user = makeUser();
    credits.grant(user, 5, "purchase", "token-e");
    credits.reserve(user, 3, "check-3");

    assert.equal(credits.refund(user, 3, "check-3"), true);
    assert.equal(credits.balanceOf(user), 5);
  });

  it("refunds a check only once", () => {
    const user = makeUser();
    credits.grant(user, 5, "purchase", "token-f");
    credits.reserve(user, 3, "check-4");
    credits.refund(user, 3, "check-4");

    assert.equal(credits.refund(user, 3, "check-4"), false);
    assert.equal(credits.balanceOf(user), 5, "a double refund would mint credits");
  });

  it("drains exactly to zero and then stops", () => {
    const user = makeUser();
    credits.grant(user, 3, "grant", "trial:drain");

    credits.reserve(user, 1, "d1");
    credits.reserve(user, 1, "d2");
    credits.reserve(user, 1, "d3");

    assert.equal(credits.balanceOf(user), 0);
    assert.throws(() => credits.reserve(user, 1, "d4"), credits.InsufficientCredits);
  });
});
