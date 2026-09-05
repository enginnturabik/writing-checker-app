import { TIERS, type Tier } from "./catalog.ts";
import { db, now } from "./db.ts";
import { env } from "./env.ts";

export class LimitExceeded extends Error {
  readonly retryAfterSeconds: number | undefined;

  constructor(message: string, retryAfterSeconds?: number) {
    super(message);
    this.name = "LimitExceeded";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

const MINUTE = 60_000;
const DAY = 24 * 60 * 60 * 1000;

/**
 * Per-device throttle. Credits already cap total spend, but a burst of
 * concurrent requests can still cost real money before the balance runs out,
 * and a scripted client should not be able to hammer the upstream API.
 */
export function enforceRateLimit(userId: string): void {
  const timestamp = now();

  const minuteCount = countSince(userId, timestamp - MINUTE);
  if (minuteCount >= env.RATE_LIMIT_PER_MINUTE) {
    throw new LimitExceeded(
      "Too many checks in a row. Wait a moment and try again.",
      60,
    );
  }

  const dayCount = countSince(userId, timestamp - DAY);
  if (dayCount >= env.RATE_LIMIT_PER_DAY) {
    throw new LimitExceeded(
      "You have reached the daily limit for checks. Try again tomorrow.",
      3600,
    );
  }

  db.prepare("INSERT INTO request_log (user_id, created_at) VALUES (?, ?)").run(
    userId,
    timestamp,
  );

  // Opportunistic prune keeps the table small without a scheduler.
  if (Math.random() < 0.02) {
    db.prepare("DELETE FROM request_log WHERE created_at < ?").run(
      timestamp - DAY,
    );
  }
}

function countSince(userId: string, since: number): number {
  const row = db
    .prepare(
      "SELECT COUNT(*) AS n FROM request_log WHERE user_id = ? AND created_at >= ?",
    )
    .get(userId, since) as { n: number } | undefined;
  return Number(row?.n ?? 0);
}

export function countWords(text: string): number {
  const trimmed = text.trim();
  if (!trimmed) return 0;
  return trimmed.split(/\s+/u).length;
}

/**
 * Rejects submissions that would cost far more than the credits charged for
 * them. Without this, one pasted novel wipes out the margin on a whole pack.
 */
export function enforceSize(
  text: string,
  tier: Tier,
  attachmentBytes: number,
): void {
  const maxWords =
    tier === "report" ? env.MAX_WORDS_DEEP : env.MAX_WORDS_STANDARD;
  const words = countWords(text);

  if (words > maxWords) {
    throw new LimitExceeded(
      `That text is ${words} words. The ${TIERS[tier].label.toLowerCase()} ` +
        `covers up to ${maxWords}. Split it into shorter pieces, or run a ` +
        `full report.`,
    );
  }

  const maxBytes = env.MAX_ATTACHMENT_MB * 1024 * 1024;
  if (attachmentBytes > maxBytes) {
    throw new LimitExceeded(
      `That file is too large. The limit is ${env.MAX_ATTACHMENT_MB} MB.`,
    );
  }
}

/** Credits this submission costs, before any of it is spent. */
export function priceOf(tier: Tier, hasAttachment: boolean): number {
  const spec = TIERS[tier];
  return spec.credits + (hasAttachment ? spec.attachmentSurcharge : 0);
}
