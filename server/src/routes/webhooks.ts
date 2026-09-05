import { decodeJwt } from "jose";
import { Hono } from "hono";

import { planByProduct } from "../catalog.ts";
import { env } from "../env.ts";
import { verifySubscription } from "../purchases/index.ts";
import {
  applySubscription,
  expireSubscription,
  subscriptionByRef,
} from "../subscriptions.ts";

/**
 * Store notifications: renewals, cancellations, refunds, billing problems.
 *
 * Without these a subscription is only as current as the last time the app
 * opened, so a renewal on a phone left in a drawer would never be credited and
 * a refund would never be taken back.
 *
 * The security model is deliberately simple: a notification is never believed.
 * It carries an identifier, we look that identifier up with the store's API,
 * and the answer decides what happens. A forged notification therefore buys an
 * attacker nothing beyond making us call Google or Apple, which is what the
 * shared secret on the path is for.
 */
export const webhookRoutes = new Hono();

function authorised(header: string | undefined): boolean {
  const expected = env.WEBHOOK_SECRET;
  if (!expected) return false;
  return header === expected;
}

/**
 * Google Real-Time Developer Notifications, delivered by Pub/Sub push.
 *
 * Pub/Sub retries anything that is not a 2xx, so failures return 500 to be
 * redelivered, while messages we understand and choose to ignore return 200 -
 * a notification for a subscription we have never seen is not an error, it is
 * a user who has not linked their account yet.
 */
webhookRoutes.post("/webhooks/google", async (c) => {
  if (!authorised(c.req.header("x-webhook-secret"))) {
    return c.json({ error: "Not found." }, 404);
  }

  const body = (await c.req.json().catch(() => null)) as {
    message?: { data?: string };
  } | null;

  const raw = body?.message?.data;
  if (!raw) return c.json({ ok: true });

  let notification: {
    subscriptionNotification?: { purchaseToken?: string; notificationType?: number };
  };
  try {
    notification = JSON.parse(Buffer.from(raw, "base64").toString("utf8"));
  } catch {
    console.error("[webhooks] google payload was not JSON");
    return c.json({ ok: true });
  }

  const purchaseToken = notification.subscriptionNotification?.purchaseToken;
  if (!purchaseToken) return c.json({ ok: true });

  const existing = subscriptionByRef(purchaseToken);
  if (!existing) {
    // Arrives before the app has told us who owns this token. The client's
    // own call to /subscriptions will settle it.
    return c.json({ ok: true });
  }

  try {
    const verified = await verifySubscription("android", existing.product_id, purchaseToken);
    const plan = planByProduct(verified.productId);
    if (!plan) {
      console.error("[webhooks] google reported an unknown product", verified.productId);
      return c.json({ ok: true });
    }
    applySubscription(existing.user_id, plan.id, verified);
  } catch (error) {
    console.error("[webhooks] google verification failed", error);
    return c.json({ error: "retry" }, 500);
  }

  return c.json({ ok: true });
});

/**
 * App Store Server Notifications V2.
 *
 * Apple sends a signed JWS. Its claims are only used to find the subscription;
 * entitlement still comes from a fresh lookup, so the signature is not load
 * bearing here.
 */
webhookRoutes.post("/webhooks/apple", async (c) => {
  if (!authorised(c.req.header("x-webhook-secret"))) {
    return c.json({ error: "Not found." }, 404);
  }

  const body = (await c.req.json().catch(() => null)) as {
    signedPayload?: string;
  } | null;
  if (!body?.signedPayload) return c.json({ ok: true });

  let originalTransactionId: string | undefined;
  let notificationType: string | undefined;
  try {
    const payload = decodeJwt(body.signedPayload) as {
      notificationType?: string;
      data?: { signedTransactionInfo?: string };
    };
    notificationType = payload.notificationType;
    if (payload.data?.signedTransactionInfo) {
      const tx = decodeJwt(payload.data.signedTransactionInfo) as {
        originalTransactionId?: string;
      };
      originalTransactionId = tx.originalTransactionId;
    }
  } catch {
    console.error("[webhooks] apple payload could not be decoded");
    return c.json({ ok: true });
  }

  if (!originalTransactionId) return c.json({ ok: true });

  const existing = subscriptionByRef(originalTransactionId);
  if (!existing) return c.json({ ok: true });

  // A refund is the one case worth acting on without a lookup: Apple stops
  // reporting a revoked subscription, so waiting for the API to confirm it
  // would leave access switched on.
  if (notificationType === "REFUND" || notificationType === "REVOKE") {
    expireSubscription(originalTransactionId);
    return c.json({ ok: true });
  }

  try {
    const verified = await verifySubscription("ios", existing.product_id, originalTransactionId);
    const plan = planByProduct(verified.productId);
    if (!plan) {
      console.error("[webhooks] apple reported an unknown product", verified.productId);
      return c.json({ ok: true });
    }
    applySubscription(existing.user_id, plan.id, verified);
  } catch (error) {
    console.error("[webhooks] apple verification failed", error);
    return c.json({ error: "retry" }, 500);
  }

  return c.json({ ok: true });
});
