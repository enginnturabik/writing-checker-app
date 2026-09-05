import { db, now, transaction } from "./db.ts";

export type LedgerKind = "grant" | "purchase" | "spend" | "refund";

export class InsufficientCredits extends Error {
  readonly balance: number;
  readonly required: number;

  constructor(balance: number, required: number) {
    super(`Not enough credits: have ${balance}, need ${required}`);
    this.name = "InsufficientCredits";
    this.balance = balance;
    this.required = required;
  }
}

export function balanceOf(userId: string): number {
  const row = db
    .prepare("SELECT COALESCE(SUM(delta), 0) AS balance FROM ledger WHERE user_id = ?")
    .get(userId) as { balance: number } | undefined;
  return Number(row?.balance ?? 0);
}

/**
 * Adds credits. `ref` makes the grant idempotent: the unique index means a
 * replayed purchase token or a second trial grant is rejected by the database
 * rather than by a check we might forget to write.
 *
 * Returns false when this exact grant already happened.
 */
export function grant(
  userId: string,
  amount: number,
  kind: Extract<LedgerKind, "grant" | "purchase" | "refund">,
  ref: string,
): boolean {
  if (amount <= 0) throw new Error("grant amount must be positive");
  try {
    db.prepare(
      "INSERT INTO ledger (user_id, delta, kind, ref, created_at) VALUES (?, ?, ?, ?, ?)",
    ).run(userId, amount, kind, ref, now());
    return true;
  } catch (error) {
    if (isUniqueViolation(error)) return false;
    throw error;
  }
}

/**
 * Reserves credits for a check before any tokens are bought.
 *
 * Debiting up front is what stops a client from cancelling mid-stream to get
 * free marking. If the check then fails, {@link refund} puts the credits back.
 * Balance read and debit happen in one IMMEDIATE transaction so two concurrent
 * checks cannot both see the same balance and both proceed.
 */
export function reserve(userId: string, amount: number, checkId: string): number {
  return transaction(() => {
    const row = db
      .prepare(
        "SELECT COALESCE(SUM(delta), 0) AS balance FROM ledger WHERE user_id = ?",
      )
      .get(userId) as { balance: number } | undefined;
    const balance = Number(row?.balance ?? 0);

    if (balance < amount) throw new InsufficientCredits(balance, amount);

    db.prepare(
      "INSERT INTO ledger (user_id, delta, kind, ref, created_at) VALUES (?, ?, 'spend', ?, ?)",
    ).run(userId, -amount, checkId, now());

    return balance - amount;
  });
}

/** Returns reserved credits after a failed check. Idempotent per check id. */
export function refund(userId: string, amount: number, checkId: string): boolean {
  return grant(userId, amount, "refund", `refund:${checkId}`);
}

function isUniqueViolation(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return message.includes("UNIQUE constraint failed");
}
