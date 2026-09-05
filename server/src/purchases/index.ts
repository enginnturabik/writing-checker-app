import { env } from "../env.ts";
import { verifyAppleSubscription } from "./apple-subscription.ts";
import { verifyApplePurchase } from "./apple.ts";
import { verifyGooglePurchase, verifyGoogleSubscription } from "./google.ts";
import {
  VerificationError,
  type Platform,
  type StoreSubscriptionInfo,
  type VerifiedPurchase,
} from "./types.ts";

export { VerificationError };
export type { Platform, StoreSubscriptionInfo, VerifiedPurchase };

/**
 * Verifies a purchase with the store that sold it.
 *
 * In `mock` mode nothing is checked, so the app-side purchase flow can be
 * built before store credentials exist. The server refuses to start in mock
 * mode without it being an explicit choice, and every mock grant is logged.
 */
export async function verifyPurchase(
  platform: Platform,
  productId: string,
  token: string,
): Promise<VerifiedPurchase> {
  if (env.PURCHASE_VERIFICATION === "mock") {
    console.warn(
      `[purchases] MOCK verification accepted ${productId} for ${platform}. ` +
        "Never run this in production.",
    );
    return {
      platform,
      productId,
      purchaseToken: token,
      transactionId: token,
      purchasedAt: Date.now(),
    };
  }

  return platform === "android"
    ? verifyGooglePurchase(productId, token)
    : verifyApplePurchase(productId, token);
}

/**
 * Asks the store what state a subscription is actually in.
 *
 * Unlike a one-time purchase, a subscription changes without the app being
 * involved - it renews, lapses, enters billing retry, gets refunded. So this
 * is the only source of truth in the system, and every path that grants an
 * allowance goes through it, including the webhooks. A store notification is
 * treated as a hint that something changed, never as the change itself: that
 * is what makes a forged notification worthless to an attacker.
 *
 * Mock mode returns a live month so the paywall can be exercised end to end.
 */
export async function verifySubscription(
  platform: Platform,
  productId: string,
  token: string,
): Promise<StoreSubscriptionInfo> {
  if (env.PURCHASE_VERIFICATION === "mock") {
    console.warn(
      `[purchases] MOCK subscription accepted ${productId} for ${platform}. ` +
        "Never run this in production.",
    );
    return {
      platform,
      productId,
      storeRef: token,
      supersedes: null,
      status: "active",
      expiresAt: Date.now() + 31 * 86_400_000,
      autoRenewing: true,
    };
  }

  return platform === "android"
    ? verifyGoogleSubscription(token)
    : verifyAppleSubscription(token);
}
