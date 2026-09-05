import { SignJWT, decodeJwt, importPKCS8 } from "jose";

import { env } from "../env.ts";
import { VerificationError, type VerifiedPurchase } from "./types.ts";

const HOSTS = {
  production: "https://api.storekit.itunes.apple.com",
  sandbox: "https://api.storekit-sandbox.itunes.apple.com",
};

let cachedToken: { value: string; expiresAt: number } | null = null;

/** Which App Store Server API to talk to. Sandbox during review. */
export function appleHost(): string {
  return HOSTS[env.APPLE_ENVIRONMENT];
}

/** ES256 JWT for the App Store Server API, signed with the .p8 key. */
export async function appleApiToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) {
    return cachedToken.value;
  }

  const { APPLE_ISSUER_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY, APPLE_BUNDLE_ID } = env;
  if (!APPLE_ISSUER_ID || !APPLE_KEY_ID || !APPLE_PRIVATE_KEY || !APPLE_BUNDLE_ID) {
    throw new VerificationError("App Store verification is not configured.", 503);
  }

  const key = await importPKCS8(APPLE_PRIVATE_KEY.replace(/\\n/g, "\n"), "ES256");

  const value = await new SignJWT({ bid: APPLE_BUNDLE_ID })
    .setProtectedHeader({ alg: "ES256", kid: APPLE_KEY_ID, typ: "JWT" })
    .setIssuer(APPLE_ISSUER_ID)
    .setAudience("appstoreconnect-v1")
    .setIssuedAt()
    .setExpirationTime("50m")
    .sign(key);

  cachedToken = { value, expiresAt: Date.now() + 50 * 60_000 };
  return value;
}

/**
 * Verifies a StoreKit 2 transaction by asking Apple about it directly.
 *
 * The app sends the transaction id from its purchase. Looking it up server-side
 * is simpler and harder to get wrong than validating the signed JWS locally
 * against Apple's certificate chain, and it also catches refunds.
 */
export async function verifyApplePurchase(
  productId: string,
  transactionId: string,
): Promise<VerifiedPurchase> {
  const token = await appleApiToken();
  const host = appleHost();

  const response = await fetch(
    `${host}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`,
    { headers: { authorization: `Bearer ${token}` } },
  );

  if (response.status === 404) {
    throw new VerificationError("That purchase could not be found.", 400);
  }
  if (!response.ok) {
    console.error("[apple] verify failed", response.status, await response.text());
    throw new VerificationError("Could not verify the purchase. Try again.", 503);
  }

  const body = (await response.json()) as { signedTransactionInfo?: string };
  if (!body.signedTransactionInfo) {
    throw new VerificationError("That purchase could not be verified.", 400);
  }

  // The payload is signed by Apple and we received it over TLS straight from
  // Apple, so the claims can be read without re-verifying the chain.
  const claims = decodeJwt(body.signedTransactionInfo) as {
    productId?: string;
    transactionId?: string;
    bundleId?: string;
    purchaseDate?: number;
    revocationDate?: number;
  };

  if (claims.bundleId !== env.APPLE_BUNDLE_ID) {
    throw new VerificationError("That purchase belongs to another app.", 400);
  }
  if (claims.productId !== productId) {
    throw new VerificationError("That purchase does not match the product.", 400);
  }
  if (claims.revocationDate) {
    throw new VerificationError("That purchase was refunded.", 400);
  }

  return {
    platform: "ios",
    productId,
    purchaseToken: claims.transactionId ?? transactionId,
    transactionId: claims.transactionId ?? transactionId,
    purchasedAt: claims.purchaseDate ?? Date.now(),
  };
}
