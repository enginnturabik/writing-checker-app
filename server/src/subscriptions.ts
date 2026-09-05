import { PLANS, planById, type Plan, type PlanId } from "./catalog.ts";
import { balanceOf, grant } from "./credits.ts";
import { db, now, transaction } from "./db.ts";
import type { StoreSubscriptionInfo } from "./purchases/types.ts";

/**
 * Subscription state, and the allowance it drips into the credit ledger.
 *
 * One idea holds the design together: a subscription never gates a check. It
 * only puts credits in the ledger, and `credits.reserve` remains the single
 * place that decides whether a check may run. That is why nothing in the
 * checking path had to change to support subscriptions.
 *
 * Allowances are granted per CALENDAR MONTH rather than per billing period,
 * which is what lets one code path serve both plan shapes: a monthly plan
 * renews as the bucket turns over, and a yearly plan - one payment, twelve
 * months of access - drips a twelfth of itself each month instead of handing
 * over a year of credits that could be spent in a week and then refunded.
 *
 * No scheduler is involved. The grant is evaluated whenever the user is seen,
 * so a dormant account costs nothing and an active one is always current.
 */

export type SubscriptionStatus = "active" | "grace" | "expired";

export interface SubscriptionRow {
  user_id: string;
  platform: string;
  plan_id: string;
  product_id: string;
  store_ref: string;
  status: SubscriptionStatus;
  expires_at: number;
  auto_renewing: number;
  granted_for: number | null;
  updated_at: number;
}

export interface Entitlement {
  planId: PlanId;
  label: string;
  status: SubscriptionStatus;
  /** Null on the free plan, which never expires. */
  expiresAt: number | null;
  autoRenewing: boolean;
  creditsPerPeriod: number;
  description: string;
}

const FREE = PLANS.free;

export function subscriptionOf(userId: string): SubscriptionRow | undefined {
  return db.prepare("SELECT * FROM subscriptions WHERE user_id = ?").get(userId) as
    | unknown as SubscriptionRow
    | undefined;
}

export function subscriptionByRef(storeRef: string): SubscriptionRow | undefined {
  return db.prepare("SELECT * FROM subscriptions WHERE store_ref = ?").get(storeRef) as
    | unknown as SubscriptionRow
    | undefined;
}

/** Start of the UTC month containing `timestamp`. Identifies one allowance. */
export function monthBucket(timestamp: number): number {
  const d = new Date(timestamp);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1);
}

function isLive(row: SubscriptionRow | undefined): row is SubscriptionRow {
  return row !== undefined && row.status !== "expired" && row.expires_at > now();
}

/**
 * Records what the store said, then accrues any allowance now due.
 *
 * Callers must have verified `sub` against the store API first: this trusts
 * its argument completely, which is only safe because both entry points - a
 * client restoring a purchase and a store webhook - re-verify rather than
 * believing a payload handed to them.
 */
export function applySubscription(
  userId: string,
  planId: PlanId,
  sub: StoreSubscriptionInfo,
): { granted: number; balance: number } {
  transaction(() => {
    // Play reissues the purchase token on upgrade or resubscribe and points
    // the new one at the old. Retiring the superseded row keeps the UNIQUE
    // index on store_ref free for the token now in force.
    if (sub.supersedes) {
      db.prepare(
        "UPDATE subscriptions SET status = 'expired', auto_renewing = 0, updated_at = ? WHERE store_ref = ?",
      ).run(now(), sub.supersedes);
    }

    db.prepare(
      `INSERT INTO subscriptions
         (user_id, platform, plan_id, product_id, store_ref, status,
          expires_at, auto_renewing, granted_for, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
       ON CONFLICT(user_id) DO UPDATE SET
         platform      = excluded.platform,
         plan_id       = excluded.plan_id,
         product_id    = excluded.product_id,
         store_ref     = excluded.store_ref,
         status        = excluded.status,
         expires_at    = excluded.expires_at,
         auto_renewing = excluded.auto_renewing,
         updated_at    = excluded.updated_at`,
    ).run(
      userId,
      sub.platform,
      planId,
      sub.productId,
      sub.storeRef,
      sub.status,
      sub.expiresAt,
      sub.autoRenewing ? 1 : 0,
      now(),
    );
  });

  return { granted: accrueAllowance(userId), balance: balanceOf(userId) };
}

/**
 * Grants this month's allowance if the subscription is live and has not had it
 * yet. Safe to call on every request: the common case is one indexed read and
 * no write.
 *
 * Idempotent twice over - the row remembers which month it paid out, and the
 * ledger's unique ref rejects a duplicate anyway - so a renewal webhook and a
 * client restore arriving together still grant once.
 */
export function accrueAllowance(userId: string): number {
  const row = subscriptionOf(userId);
  if (!isLive(row)) return 0;

  const plan = planById(row.plan_id);
  if (!plan) {
    console.error("[subscriptions] unknown plan on subscription", row.plan_id);
    return 0;
  }

  const bucket = monthBucket(now());
  if (row.granted_for === bucket) return 0;

  return transaction(() => {
    const credited = grant(
      userId,
      plan.creditsPerPeriod,
      "purchase",
      `sub:${row.store_ref}:${bucket}`,
    );
    db.prepare("UPDATE subscriptions SET granted_for = ? WHERE user_id = ?").run(
      bucket,
      userId,
    );
    return credited ? plan.creditsPerPeriod : 0;
  });
}

/** Marks a subscription expired. Credits already granted are left alone. */
export function expireSubscription(storeRef: string): void {
  db.prepare(
    "UPDATE subscriptions SET status = 'expired', auto_renewing = 0, updated_at = ? WHERE store_ref = ?",
  ).run(now(), storeRef);
}

/**
 * Tops a free user back up to the weekly allowance.
 *
 * A top-up, not an addition: the grant is the difference between the balance
 * and the allowance, so six quiet weeks cannot accumulate into a free full
 * report. Paid allowances do roll over, because that month was paid for
 * either way.
 *
 * `at` exists so the no-hoarding property can be tested across weeks without
 * waiting for them. Production always passes the current time.
 */
export function refreshFreeAllowance(userId: string, at: number = now()): number {
  if (isLive(subscriptionOf(userId))) return 0;

  const ref = `free:${isoWeek(at)}`;
  const already = db
    .prepare("SELECT 1 FROM ledger WHERE user_id = ? AND kind = 'grant' AND ref = ?")
    .get(userId, ref);
  if (already) return 0;

  const allowance = FREE.creditsPerPeriod;
  if (allowance <= 0) return 0;

  const shortfall = allowance - balanceOf(userId);
  if (shortfall <= 0) return 0;

  return grant(userId, shortfall, "grant", ref) ? shortfall : 0;
}

/** Brings a user's credits up to date, whichever plan they are on. */
export function settleAllowances(userId: string): void {
  accrueAllowance(userId);
  refreshFreeAllowance(userId);
}

/**
 * What the app should show. Reads through to the free plan once a paid period
 * has run out, so an expired subscriber quietly becomes a free user instead of
 * meeting an error.
 */
export function entitlementOf(userId: string): Entitlement {
  const row = subscriptionOf(userId);
  const plan: Plan | undefined = row ? planById(row.plan_id) : undefined;

  if (!isLive(row) || !plan) {
    return {
      planId: "free",
      label: FREE.label,
      status: "expired",
      expiresAt: null,
      autoRenewing: false,
      creditsPerPeriod: FREE.creditsPerPeriod,
      description: FREE.description,
    };
  }

  return {
    planId: plan.id,
    label: plan.label,
    status: row.status,
    expiresAt: row.expires_at,
    autoRenewing: row.auto_renewing === 1,
    creditsPerPeriod: plan.creditsPerPeriod,
    description: plan.description,
  };
}

/** `2026-W23`. Weeks start Monday, which is what ISO-8601 says. */
export function isoWeek(timestamp: number): string {
  const date = new Date(timestamp);
  const day = (date.getUTCDay() + 6) % 7;
  date.setUTCDate(date.getUTCDate() - day + 3);
  const firstThursday = new Date(Date.UTC(date.getUTCFullYear(), 0, 4));
  const firstDay = (firstThursday.getUTCDay() + 6) % 7;
  firstThursday.setUTCDate(firstThursday.getUTCDate() - firstDay + 3);
  const week =
    1 + Math.round((date.getTime() - firstThursday.getTime()) / (7 * 86_400_000));
  return `${date.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}
