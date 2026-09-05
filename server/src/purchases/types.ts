export type Platform = "android" | "ios";

export interface VerifiedPurchase {
  platform: Platform;
  productId: string;
  /** The value stored to make a replay a no-op. */
  purchaseToken: string;
  transactionId: string;
  purchasedAt: number;
}

/** A subscription's live state, normalised across the two stores. */
export interface StoreSubscriptionInfo {
  platform: Platform;
  productId: string;
  /** Stable handle for this subscription across renewals. */
  storeRef: string;
  /** Play reissues tokens on upgrade; this points at the one replaced. */
  supersedes: string | null;
  status: "active" | "grace" | "expired";
  /** End of the period currently paid for. */
  expiresAt: number;
  autoRenewing: boolean;
}

export class VerificationError extends Error {
  readonly status: number;

  constructor(message: string, status = 400) {
    super(message);
    this.name = "VerificationError";
    this.status = status;
  }
}
