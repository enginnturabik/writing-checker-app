import type { Provider, VerifiedIdentity } from "./auth/providers.ts";
import { balanceOf, grant } from "./credits.ts";
import { db, now, transaction } from "./db.ts";

export interface Identity {
  id: number;
  user_id: string;
  provider: string;
  subject: string;
  email: string | null;
  created_at: number;
}

export function identityFor(
  provider: Provider,
  subject: string,
): Identity | undefined {
  return db
    .prepare("SELECT * FROM identities WHERE provider = ? AND subject = ?")
    .get(provider, subject) as unknown as Identity | undefined;
}

export function identityOfUser(userId: string): Identity | undefined {
  return db
    .prepare("SELECT * FROM identities WHERE user_id = ? ORDER BY id LIMIT 1")
    .get(userId) as unknown as Identity | undefined;
}

/** Credits this user was given by purchases, ignoring the free trial. */
function purchasedTotal(userId: string): number {
  const row = db
    .prepare(
      `SELECT COALESCE(SUM(delta), 0) AS total FROM ledger
       WHERE user_id = ? AND kind = 'purchase'`,
    )
    .get(userId) as { total: number } | undefined;
  return Number(row?.total ?? 0);
}

export interface LinkOutcome {
  /** The account this device now belongs to. */
  userId: string;
  /** True when the device was moved onto an existing account. */
  merged: boolean;
  /** Credits carried across from the anonymous account during a merge. */
  carriedCredits: number;
  balance: number;
  email: string | null;
}

/**
 * Binds a verified sign-in to an account.
 *
 * Three cases, and the third is the one that matters. Someone reinstalls, gets
 * a fresh anonymous account with trial credits, then signs in — their old
 * account still holds the credits they paid for, so the device has to move onto
 * it rather than the other way round.
 */
export function linkIdentity(
  currentUserId: string,
  identity: VerifiedIdentity,
): LinkOutcome {
  return transaction(() => {
    const existing = identityFor(identity.provider, identity.subject);

    // Case 1: nobody has used this sign-in before. Claim it for this account,
    // which turns the anonymous account into a real one and keeps its balance.
    if (!existing) {
      db.prepare(
        `INSERT INTO identities (user_id, provider, subject, email, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      ).run(
        currentUserId,
        identity.provider,
        identity.subject,
        identity.email,
        now(),
      );
      return {
        userId: currentUserId,
        merged: false,
        carriedCredits: 0,
        balance: balanceOf(currentUserId),
        email: identity.email,
      };
    }

    // Case 2: already this account. Signing in again is a no-op.
    if (existing.user_id === currentUserId) {
      return {
        userId: currentUserId,
        merged: false,
        carriedCredits: 0,
        balance: balanceOf(currentUserId),
        email: existing.email ?? identity.email,
      };
    }

    // Case 3: the sign-in belongs to an older account. Move the device there.
    const target = existing.user_id;

    // Carry over only what was paid for, capped at what is actually left.
    // Trial credits deliberately stay behind: otherwise signing in and out
    // would mint three free checks every time.
    const carried = Math.max(
      0,
      Math.min(balanceOf(currentUserId), purchasedTotal(currentUserId)),
    );

    if (carried > 0) {
      // Debit the abandoned account first so the credits exist in one place
      // only, then grant them to the target under a ref that cannot replay.
      db.prepare(
        `INSERT INTO ledger (user_id, delta, kind, ref, created_at)
         VALUES (?, ?, 'spend', ?, ?)`,
      ).run(currentUserId, -carried, `merge-out:${target}`, now());
      grant(target, carried, "grant", `merge-in:${currentUserId}`);
    }

    // Purchases follow the credits, so receipts stay traceable to one account.
    db.prepare("UPDATE purchases SET user_id = ? WHERE user_id = ?").run(
      target,
      currentUserId,
    );

    // Retire the anonymous account by pointing it at the real one. The install
    // id stays attached to it, so a later reinstall on this device follows the
    // pointer home rather than starting over with a fresh trial.
    db.prepare("UPDATE users SET merged_into = ? WHERE id = ?").run(
      target,
      currentUserId,
    );

    if (!existing.email && identity.email) {
      db.prepare("UPDATE identities SET email = ? WHERE id = ?").run(
        identity.email,
        existing.id,
      );
    }

    return {
      userId: target,
      merged: true,
      carriedCredits: carried,
      balance: balanceOf(target),
      email: existing.email ?? identity.email,
    };
  });
}
