import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { env } from "./env.ts";

/**
 * SQLite via Node's built-in driver, so there is no native module to compile
 * on any host. One file on disk holds users, the credit ledger and the audit
 * trail; point DATABASE_PATH at a mounted volume in production.
 */
function open(): DatabaseSync {
  if (env.DATABASE_PATH !== ":memory:") {
    mkdirSync(dirname(env.DATABASE_PATH), { recursive: true });
  }
  const database = new DatabaseSync(env.DATABASE_PATH);
  database.exec("PRAGMA journal_mode = WAL");
  database.exec("PRAGMA foreign_keys = ON");
  database.exec("PRAGMA busy_timeout = 5000");
  return database;
}

export const db = open();

export function migrate(database: DatabaseSync = db): void {
  database.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id          TEXT PRIMARY KEY,
      install_id  TEXT NOT NULL UNIQUE,
      platform    TEXT NOT NULL,
      blocked     INTEGER NOT NULL DEFAULT 0,
      -- Set when this anonymous account was folded into a signed-in one.
      -- Lookups follow the pointer instead of failing, so reinstalling on the
      -- same device lands back on the real account.
      merged_into TEXT,
      created_at  INTEGER NOT NULL
    );

    -- One row per sign-in method. A user may have both Google and Apple.
    CREATE TABLE IF NOT EXISTS identities (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    TEXT NOT NULL REFERENCES users(id),
      provider   TEXT NOT NULL,
      subject    TEXT NOT NULL,
      email      TEXT,
      created_at INTEGER NOT NULL
    );
    -- One account per provider identity: this is what makes signing in on a
    -- new device find the existing balance instead of creating a second one.
    CREATE UNIQUE INDEX IF NOT EXISTS identities_provider_subject
      ON identities(provider, subject);
    CREATE INDEX IF NOT EXISTS identities_user ON identities(user_id);

    -- Append-only credit ledger. The balance is always SUM(delta); nothing
    -- ever updates a row, so a wrong balance can be traced to its entry.
    CREATE TABLE IF NOT EXISTS ledger (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    TEXT NOT NULL REFERENCES users(id),
      delta      INTEGER NOT NULL,
      kind       TEXT NOT NULL,
      ref        TEXT,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ledger_user ON ledger(user_id);

    -- Makes every credit grant idempotent: replaying a purchase or a trial
    -- grant collides here instead of handing out free credits.
    CREATE UNIQUE INDEX IF NOT EXISTS ledger_unique_ref
      ON ledger(user_id, kind, ref) WHERE ref IS NOT NULL;

    CREATE TABLE IF NOT EXISTS purchases (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id        TEXT NOT NULL REFERENCES users(id),
      platform       TEXT NOT NULL,
      product_id     TEXT NOT NULL,
      purchase_token TEXT NOT NULL UNIQUE,
      credits        INTEGER NOT NULL,
      created_at     INTEGER NOT NULL
    );

    -- One row per check attempted, for support questions and margin tracking.
    CREATE TABLE IF NOT EXISTS checks (
      id            TEXT PRIMARY KEY,
      user_id       TEXT NOT NULL REFERENCES users(id),
      tier          TEXT NOT NULL,
      model         TEXT NOT NULL,
      words         INTEGER NOT NULL,
      credits       INTEGER NOT NULL,
      status        TEXT NOT NULL,
      input_tokens  INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      cost_usd      REAL NOT NULL DEFAULT 0,
      created_at    INTEGER NOT NULL,
      finished_at   INTEGER
    );
    CREATE INDEX IF NOT EXISTS checks_user ON checks(user_id, created_at);

    -- Current subscription per user. One row, overwritten as the store tells
    -- us what changed; the ledger keeps the history, so nothing is lost by
    -- updating in place here.
    CREATE TABLE IF NOT EXISTS subscriptions (
      user_id       TEXT PRIMARY KEY REFERENCES users(id),
      platform      TEXT NOT NULL,
      plan_id       TEXT NOT NULL,
      product_id    TEXT NOT NULL,
      -- The store's stable handle for this subscription: a Play purchase
      -- token, or Apple's originalTransactionId. Renewals keep it, which is
      -- what lets a renewal notification find the right user.
      store_ref     TEXT NOT NULL UNIQUE,
      -- active | grace | expired. Grace is Apple/Google retrying a failed
      -- payment: access continues, because dropping someone mid-exam over a
      -- card that will probably clear is how you earn a refund request.
      status        TEXT NOT NULL,
      -- End of the period currently paid for.
      expires_at    INTEGER NOT NULL,
      auto_renewing INTEGER NOT NULL DEFAULT 1,
      -- Start of the period whose allowance was last granted. Guards against
      -- granting twice when a webhook and a client restore race each other.
      granted_for   INTEGER,
      updated_at    INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS subscriptions_ref ON subscriptions(store_ref);

    -- Rate-limit window. Pruned opportunistically rather than on a timer.
    CREATE TABLE IF NOT EXISTS request_log (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS request_log_user ON request_log(user_id, created_at);
  `);

  // Databases created before sign-in existed predate this column.
  const columns = database.prepare("PRAGMA table_info(users)").all() as Array<{
    name: string;
  }>;
  if (!columns.some((c) => c.name === "merged_into")) {
    database.exec("ALTER TABLE users ADD COLUMN merged_into TEXT");
  }
}

/**
 * Runs `fn` inside an IMMEDIATE transaction so concurrent checks cannot both
 * read the same balance and both decide there is enough credit.
 */
export function transaction<T>(fn: () => T, database: DatabaseSync = db): T {
  database.exec("BEGIN IMMEDIATE");
  try {
    const result = fn();
    database.exec("COMMIT");
    return result;
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}

export function now(): number {
  return Date.now();
}
