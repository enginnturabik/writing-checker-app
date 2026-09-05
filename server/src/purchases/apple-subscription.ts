import { decodeJwt } from "jose";

import { env } from "../env.ts";
import { appleApiToken, appleHost } from "./apple.ts";
import { VerificationError, type StoreSubscriptionInfo } from "./types.ts";

/**
 * Reads a subscription's live state from the App Store Server API.
 *
 * Apple's stable handle is `originalTransactionId`: it survives every renewal,
 * so it is what the subscription row is keyed by and what a notification
 * arrives carrying. The app may send either that or the transaction id from
 * the purchase it just made - the lookup below accepts both, because Apple
 * resolves either to the same subscription group.
 */
export async function verifyAppleSubscription(
  transactionId: string,
): Promise<StoreSubscriptionInfo> {
  const token = await appleApiToken();
  const host = appleHost();

  const response = await fetch(
    `${host}/inApps/v1/subscriptions/${encodeURIComponent(transactionId)}`,
    { headers: { authorization: `Bearer ${token}` } },
  );

  if (response.status === 404) {
    throw new VerificationError("That subscription could not be found.", 400);
  }
  if (!response.ok) {
    console.error(
      "[apple] subscription verify failed",
      response.status,
      await response.text(),
    );
    throw new VerificationError("Could not verify the subscription. Try again.", 503);
  }

  const body = (await response.json()) as {
    bundleId?: string;
    data?: Array<{
      lastTransactions?: Array<{
        originalTransactionId?: string;
        status?: number;
        signedTransactionInfo?: string;
        signedRenewalInfo?: string;
      }>;
    }>;
  };

  if (body.bundleId && body.bundleId !== env.APPLE_BUNDLE_ID) {
    throw new VerificationError("That subscription belongs to another app.", 400);
  }

  const latest = body.data?.[0]?.lastTransactions?.[0];
  if (!latest?.signedTransactionInfo) {
    throw new VerificationError("That subscription could not be verified.", 400);
  }

  // Signed by Apple and received over TLS straight from Apple, so the claims
  // can be read without re-verifying the certificate chain.
  const tx = decodeJwt(latest.signedTransactionInfo) as {
    productId?: string;
    originalTransactionId?: string;
    expiresDate?: number;
    revocationDate?: number;
  };
  const renewal = latest.signedRenewalInfo
    ? (decodeJwt(latest.signedRenewalInfo) as { autoRenewStatus?: number })
    : {};

  if (!tx.productId) {
    throw new VerificationError("That subscription is missing its product.", 400);
  }

  // 1 = active, 2 = expired, 3 = in billing retry, 4 = in billing grace period,
  // 5 = revoked. Billing retry and grace both keep access: the payment is being
  // reattempted, and cutting someone off mid-exam over a card that will
  // probably clear is how a refund request is earned.
  const status =
    latest.status === 1
      ? "active"
      : latest.status === 3 || latest.status === 4
        ? "grace"
        : "expired";

  return {
    platform: "ios",
    productId: tx.productId,
    storeRef: tx.originalTransactionId ?? transactionId,
    // Apple keeps one id across renewals, so nothing is ever superseded.
    supersedes: null,
    status: tx.revocationDate ? "expired" : status,
    expiresAt: tx.expiresDate ?? 0,
    autoRenewing: renewal.autoRenewStatus === 1,
  };
}
