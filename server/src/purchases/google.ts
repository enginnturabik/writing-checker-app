import { SignJWT, importPKCS8 } from "jose";

import { env } from "../env.ts";
import { VerificationError, type StoreSubscriptionInfo, type VerifiedPurchase } from "./types.ts";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/androidpublisher";

let cachedToken: { value: string; expiresAt: number } | null = null;

/**
 * Exchanges the service-account key for an access token.
 *
 * Done by hand rather than pulling in `googleapis`, which is a very large
 * dependency for two REST calls. Tokens last an hour and are cached.
 */
async function accessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) {
    return cachedToken.value;
  }

  const email = env.GOOGLE_SERVICE_ACCOUNT_EMAIL;
  const rawKey = env.GOOGLE_SERVICE_ACCOUNT_KEY;
  if (!email || !rawKey) {
    throw new VerificationError("Google Play verification is not configured.", 503);
  }

  // Environment variables cannot hold real newlines, so the PEM arrives escaped.
  const pem = rawKey.replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "RS256");

  const assertion = await new SignJWT({ scope: SCOPE })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(email)
    .setSubject(email)
    .setAudience(TOKEN_URL)
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);

  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    console.error("[google] token exchange failed", response.status, await response.text());
    throw new VerificationError("Could not reach Google Play. Try again.", 503);
  }

  const body = (await response.json()) as { access_token: string; expires_in: number };
  cachedToken = {
    value: body.access_token,
    expiresAt: Date.now() + body.expires_in * 1000,
  };
  return cachedToken.value;
}

/**
 * Verifies a Play Billing purchase and acknowledges it.
 *
 * Acknowledgement is not optional: Google automatically refunds any purchase
 * left unacknowledged for three days, so skipping it silently gives the credits
 * away for free.
 */
export async function verifyGooglePurchase(
  productId: string,
  purchaseToken: string,
): Promise<VerifiedPurchase> {
  const packageName = env.GOOGLE_PACKAGE_NAME;
  if (!packageName) {
    throw new VerificationError("Google Play verification is not configured.", 503);
  }

  const token = await accessToken();
  const base =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(packageName)}/purchases/products/` +
    `${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;

  const response = await fetch(base, {
    headers: { authorization: `Bearer ${token}` },
  });

  if (response.status === 404 || response.status === 400) {
    throw new VerificationError("That purchase could not be found.", 400);
  }
  if (!response.ok) {
    console.error("[google] verify failed", response.status, await response.text());
    throw new VerificationError("Could not verify the purchase. Try again.", 503);
  }

  const body = (await response.json()) as {
    purchaseState?: number;
    consumptionState?: number;
    acknowledgementState?: number;
    orderId?: string;
    purchaseTimeMillis?: string;
  };

  // 0 = purchased, 1 = cancelled, 2 = pending.
  if (body.purchaseState !== 0) {
    throw new VerificationError("That purchase is not complete.", 400);
  }

  if (body.acknowledgementState === 0) {
    const ack = await fetch(`${base}:acknowledge`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({}),
    });
    if (!ack.ok) {
      // Worth shouting about: unacknowledged purchases get auto-refunded.
      console.error("[google] acknowledge failed", ack.status, await ack.text());
    }
  }

  return {
    platform: "android",
    productId,
    purchaseToken,
    transactionId: body.orderId ?? purchaseToken,
    purchasedAt: Number(body.purchaseTimeMillis ?? Date.now()),
  };
}

/**
 * Reads a Play subscription's live state, and acknowledges it.
 *
 * Uses subscriptionsv2, not the products endpoint one-time purchases use: a
 * subscription's truth is its expiry and renewal state, which change without
 * the app being involved, so the server has to ask rather than be told.
 *
 * Acknowledgement matters here for the same reason as a product purchase -
 * Google auto-refunds anything left unacknowledged for three days.
 */
export async function verifyGoogleSubscription(
  purchaseToken: string,
): Promise<StoreSubscriptionInfo> {
  const packageName = env.GOOGLE_PACKAGE_NAME;
  if (!packageName) {
    throw new VerificationError("Google Play verification is not configured.", 503);
  }

  const token = await accessToken();
  const base =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(packageName)}/purchases/subscriptionsv2/tokens/` +
    `${encodeURIComponent(purchaseToken)}`;

  const response = await fetch(base, {
    headers: { authorization: `Bearer ${token}` },
  });

  if (response.status === 404 || response.status === 400) {
    throw new VerificationError("That subscription could not be found.", 400);
  }
  if (!response.ok) {
    console.error("[google] subscription verify failed", response.status, await response.text());
    throw new VerificationError("Could not verify the subscription. Try again.", 503);
  }

  const body = (await response.json()) as {
    subscriptionState?: string;
    acknowledgementState?: string;
    linkedPurchaseToken?: string;
    lineItems?: Array<{ productId?: string; expiryTime?: string }>;
  };

  const item = body.lineItems?.[0];
  if (!item?.productId) {
    throw new VerificationError("That subscription is missing its product.", 400);
  }

  const expiresAt = item.expiryTime ? Date.parse(item.expiryTime) : 0;

  // SUBSCRIPTION_STATE_IN_GRACE_PERIOD still entitles the user; the payment is
  // being retried. ON_HOLD, PAUSED, CANCELED and EXPIRED do not - note that
  // CANCELED means auto-renew was switched off, and the paid period usually
  // still has time left on it, which `expiresAt` carries.
  const state = body.subscriptionState ?? "";
  const status =
    state === "SUBSCRIPTION_STATE_ACTIVE"
      ? "active"
      : state === "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
        ? "grace"
        : state === "SUBSCRIPTION_STATE_CANCELED" && expiresAt > Date.now()
          ? "active"
          : "expired";

  if (body.acknowledgementState === "ACKNOWLEDGEMENT_STATE_PENDING") {
    const ack = await fetch(`${base}:acknowledge`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({}),
    });
    if (!ack.ok) {
      console.error("[google] subscription acknowledge failed", ack.status, await ack.text());
    }
  }

  return {
    platform: "android",
    productId: item.productId,
    // Play reissues the token when a user upgrades or resubscribes, and points
    // the new one at the old via linkedPurchaseToken. The current token is the
    // handle to keep; the link is what lets a caller find the superseded row.
    storeRef: purchaseToken,
    supersedes: body.linkedPurchaseToken ?? null,
    status,
    expiresAt,
    autoRenewing: state === "SUBSCRIPTION_STATE_ACTIVE",
  };
}
