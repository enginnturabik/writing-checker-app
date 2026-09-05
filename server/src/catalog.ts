/**
 * What a check costs the user, and what a subscription gives them.
 *
 * These numbers are the whole business model, so they live in one file. The
 * app displays them but never decides them: the client sends a tier name, the
 * server prices it.
 *
 * ONE CREDIT IS ONE US CENT OF UPSTREAM COST. Everything below depends on
 * that: credits are fungible across tiers, so a monthly allowance only caps
 * spending if a tier's credit price tracks what the tier actually costs to
 * run. Measured costs at the time of writing - quick $0.0101, advanced
 * $0.0425, report $0.2467 - give the 1 / 4 / 25 ladder used here.
 *
 * When the measured cost of a tier moves (see the cost_usd column on `checks`),
 * move its credit price with it, or the allowances stop bounding anything.
 */

import { env } from "./env.ts";

export type Tier = "quick" | "advanced" | "report";

export interface TierSpec {
  /** Credits burned per check. */
  credits: number;
  /** Extra credits when the submission is a photo or PDF (vision costs more). */
  attachmentSurcharge: number;
  model: string;
  /** Omitted for models that reject output_config.effort. */
  effort?: "low" | "medium" | "high" | "xhigh" | "max";
  /**
   * Output ceiling for this tier. Requests stream, so timeouts are not the
   * constraint - this only has to clear the longest report the tier produces
   * and stay under the model's own cap (Haiku 4.5: 64K, Opus/Sonnet: 128K).
   * Headroom is free; hitting the cap costs the user a failed check.
   */
  maxTokens: number;
  label: string;
  description: string;
}

/**
 * Three levels of marking, priced by what they actually cost to run.
 *
 * The ladder is the product: a learner drafting homework wants `quick`, and
 * someone preparing for an exam wants `report`. Credits are the currency, so
 * a heavy user always pays for what they consume.
 *
 * Opus and Sonnet think before answering and thinking is billed as output,
 * which is why a report costs 25 credits against a quick check's 1 - it really
 * is twenty-five times the money. Pricing it any lower turns the heaviest
 * users into the least profitable ones.
 */
export const TIERS: Record<Tier, TierSpec> = {
  quick: {
    credits: 1,
    attachmentSurcharge: 1,
    model: "claude-haiku-4-5",
    maxTokens: 16000,
    label: "Quick check",
    description: "Spelling, grammar and word choice, each mistake explained.",
  },
  advanced: {
    credits: 4,
    attachmentSurcharge: 1,
    model: "claude-sonnet-5",
    effort: "medium",
    maxTokens: 32000,
    label: "Advanced check",
    description:
      "Adds phrasing, register and the mistakes your first language causes.",
  },
  report: {
    credits: 25,
    attachmentSurcharge: 2,
    model: "claude-opus-5",
    effort: "high",
    maxTokens: 64000,
    label: "Full report",
    description:
      "Exam-level marking: structure, idiom, a model rewrite and what to study next.",
  },
};

/** Per-million-token prices, used to record what each check actually cost. */
export const MODEL_PRICING: Record<
  string,
  {
    input: number;
    output: number;
    supportsEffort: boolean;
    /**
     * Shortest prefix this model will cache. Below it a cache_control marker
     * is silently ignored - no error, just no cache. The figure is not
     * monotonic across generations, so it has to be tracked per model.
     */
    cacheMinimumTokens: number;
  }
> = {
  "claude-opus-5": {
    input: 5,
    output: 25,
    supportsEffort: true,
    cacheMinimumTokens: 512,
  },
  "claude-opus-4-8": {
    input: 5,
    output: 25,
    supportsEffort: true,
    cacheMinimumTokens: 1024,
  },
  "claude-sonnet-5": {
    input: 2,
    output: 10,
    supportsEffort: true,
    cacheMinimumTokens: 1024,
  },
  "claude-haiku-4-5": {
    input: 1,
    output: 5,
    supportsEffort: false,
    cacheMinimumTokens: 4096,
  },
};

export function costUsd(
  model: string,
  inputTokens: number,
  outputTokens: number,
): number {
  const price = MODEL_PRICING[model];
  if (!price) return 0;
  return (
    (inputTokens / 1_000_000) * price.input +
    (outputTokens / 1_000_000) * price.output
  );
}

export interface Product {
  /** Must match the product id configured in Play Console / App Store Connect. */
  id: string;
  credits: number;
  priceUsd: number;
  label: string;
}

/**
 * One-time credit packs, kept as the overflow path for someone who runs out
 * mid-month and does not want another subscription. Sized for roughly twice
 * the upstream cost after the store's cut, same as the plans.
 */
export const PRODUCTS: Product[] = [
  { id: "credits_40", credits: 40, priceUsd: 1, label: "Small top-up" },
  { id: "credits_120", credits: 120, priceUsd: 3, label: "Top-up" },
  { id: "credits_200", credits: 200, priceUsd: 5, label: "Large top-up" },
];

export type PlanId = "free" | "writer" | "exam" | "exam_yearly";

export interface Plan {
  id: PlanId;
  /** Store product id. Must match Play Console / App Store Connect exactly. */
  productId: string | null;
  /** Credits granted at the start of every billing period. */
  creditsPerPeriod: number;
  /** How often that grant repeats. Yearly plans still grant monthly. */
  period: "week" | "month";
  priceUsd: number;
  label: string;
  /**
   * What the allowance buys, written for someone who has never heard of a
   * token or a model. This is the line the paywall shows.
   */
  description: string;
}

/**
 * Subscription plans.
 *
 * Sizing rule: worst case is a subscriber who spends the entire allowance on
 * full reports, so `creditsPerPeriod` (in cents of cost) must stay near half
 * of what reaches us after the store's 15%. That leaves roughly a 2x gross
 * margin on the worst-behaved paying user, which is what makes a heavy user
 * profitable instead of expensive.
 *
 * `free` has no product: it is granted by the server on a weekly timer as a
 * top-up rather than an addition, so it cannot be hoarded into a free report.
 */
export const PLANS: Record<PlanId, Plan> = {
  free: {
    id: "free",
    productId: null,
    creditsPerPeriod: env.FREE_WEEKLY_CREDITS,
    period: "week",
    priceUsd: 0,
    label: "Free",
    description: "5 quick checks every week, or one advanced check.",
  },
  writer: {
    id: "writer",
    productId: "sub_writer_monthly",
    creditsPerPeriod: 120,
    period: "month",
    priceUsd: 3,
    label: "Writer",
    description: "30 advanced checks a month, or 4 full reports.",
  },
  exam: {
    id: "exam",
    productId: "sub_exam_monthly",
    creditsPerPeriod: 250,
    period: "month",
    priceUsd: 6,
    label: "Exam",
    description: "10 full reports a month, or 62 advanced checks.",
  },
  exam_yearly: {
    id: "exam_yearly",
    productId: "sub_exam_yearly",
    creditsPerPeriod: 250,
    period: "month",
    priceUsd: 49,
    label: "Exam, yearly",
    description: "Everything in Exam, two months cheaper.",
  },
};

/**
 * Credits an unused allowance rolls over, because the month was paid for
 * either way - revenue is collected per period whether or not it is spent, so
 * carrying it forward costs nothing and reads as generous. The free plan is
 * the exception and tops up instead (see `PLANS.free`).
 */
export const PAID_ALLOWANCE_ROLLS_OVER = true;

export function planById(id: string): Plan | undefined {
  return (PLANS as Record<string, Plan>)[id];
}

/** Finds the plan a store product id belongs to. */
export function planByProduct(productId: string): Plan | undefined {
  return Object.values(PLANS).find((p) => p.productId === productId);
}

export function productById(id: string): Product | undefined {
  return PRODUCTS.find((p) => p.id === id);
}
