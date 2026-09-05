import { Hono } from "hono";
import { z } from "zod";

import { IdentityError, verifyIdentity } from "../auth/providers.ts";
import { issueToken, registerDevice } from "../auth.ts";
import { PLANS, PRODUCTS, TIERS, planByProduct, productById } from "../catalog.ts";
import { balanceOf, grant } from "../credits.ts";
import { db, now } from "../db.ts";
import { env } from "../env.ts";
import { identityOfUser, linkIdentity } from "../identities.ts";
import {
  VerificationError,
  verifyPurchase,
  verifySubscription,
} from "../purchases/index.ts";
import { applySubscription, entitlementOf } from "../subscriptions.ts";
import type { AppEnv } from "../types.ts";

/** Everything the app needs to render its paywall and options. */
function catalogPayload() {
  return {
    plans: Object.values(PLANS),
    products: PRODUCTS,
    tiers: Object.entries(TIERS).map(([id, spec]) => ({
      id,
      credits: spec.credits,
      attachmentSurcharge: spec.attachmentSurcharge,
      label: spec.label,
      description: spec.description,
    })),
    limits: {
      maxWordsStandard: env.MAX_WORDS_STANDARD,
      maxWordsDeep: env.MAX_WORDS_DEEP,
      maxAttachmentMb: env.MAX_ATTACHMENT_MB,
    },
  };
}

export const publicRoutes = new Hono();

const registerSchema = z.object({
  installId: z.string().uuid(),
  platform: z.enum(["android", "ios", "web", "windows", "macos", "linux"]),
});

/**
 * First call the app makes. Trades a locally generated install id for a
 * long-lived token, and hands out the free trial credits exactly once.
 */
publicRoutes.post("/devices", async (c) => {
  const parsed = registerSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) {
    return c.json({ error: "That request was malformed." }, 400);
  }

  const { user, token, balance, isNew } = await registerDevice(
    parsed.data.installId,
    parsed.data.platform,
  );

  return c.json({
    token,
    userId: user.id,
    balance,
    isNew,
    ...catalogPayload(),
  });
});

export const accountRoutes = new Hono<AppEnv>();

accountRoutes.get("/me", (c) => {
  const user = c.get("user");
  const identity = identityOfUser(user.id);

  return c.json({
    userId: user.id,
    balance: balanceOf(user.id),
    entitlement: entitlementOf(user.id),
    identity: identity
      ? { provider: identity.provider, email: identity.email }
      : null,
    ...catalogPayload(),
  });
});

const signInSchema = z.object({
  provider: z.enum(["google", "apple"]),
  /** The provider's ID token, straight from the sign-in SDK. */
  idToken: z.string().min(1),
});

/**
 * Attaches a Google or Apple sign-in to this device's account, so the balance
 * survives a reinstall and follows the user to a new phone.
 *
 * When the sign-in already belongs to an older account, the device is moved
 * onto it and any purchased credits come along; the response carries a fresh
 * token for that account, which the app must store in place of its old one.
 */
accountRoutes.post("/auth/link", async (c) => {
  const user = c.get("user");

  const parsed = signInSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) {
    return c.json({ error: "That request was malformed." }, 400);
  }

  let identity;
  try {
    identity = await verifyIdentity(parsed.data.provider, parsed.data.idToken);
  } catch (error) {
    if (error instanceof IdentityError) {
      return c.json({ error: error.message }, error.status as 401);
    }
    console.error("[auth] verification blew up", error);
    return c.json({ error: "Could not sign you in. Try again." }, 503);
  }

  const outcome = linkIdentity(user.id, identity);

  return c.json({
    // Only different from the current token after a merge, but the app can
    // store it unconditionally.
    token: await issueToken(outcome.userId),
    userId: outcome.userId,
    balance: outcome.balance,
    merged: outcome.merged,
    carriedCredits: outcome.carriedCredits,
    identity: { provider: identity.provider, email: outcome.email },
  });
});

const purchaseSchema = z.object({
  platform: z.enum(["android", "ios"]),
  productId: z.string().min(1),
  /** Play Billing purchase token, or the StoreKit 2 transaction id. */
  token: z.string().min(1),
});

/**
 * Credits a verified purchase.
 *
 * Two independent guards make a replay harmless: the unique purchase token in
 * `purchases`, and the unique ledger ref. The client is never trusted for the
 * credit amount, only for which product was bought.
 */
accountRoutes.post("/purchases", async (c) => {
  const user = c.get("user");

  const parsed = purchaseSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) {
    return c.json({ error: "That request was malformed." }, 400);
  }
  const { platform, productId, token } = parsed.data;

  const product = productById(productId);
  if (!product) {
    return c.json({ error: "Unknown product." }, 400);
  }

  let verified;
  try {
    verified = await verifyPurchase(platform, productId, token);
  } catch (error) {
    if (error instanceof VerificationError) {
      return c.json({ error: error.message }, error.status as 400);
    }
    console.error("[purchases] verification blew up", error);
    return c.json({ error: "Could not verify the purchase. Try again." }, 503);
  }

  const existing = db
    .prepare("SELECT id FROM purchases WHERE purchase_token = ?")
    .get(verified.purchaseToken);

  if (existing) {
    // Already credited. Restoring purchases on a reinstall lands here.
    return c.json({
      balance: balanceOf(user.id),
      credited: 0,
      alreadyProcessed: true,
    });
  }

  db.prepare(
    `INSERT INTO purchases (user_id, platform, product_id, purchase_token, credits, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(
    user.id,
    platform,
    productId,
    verified.purchaseToken,
    product.credits,
    now(),
  );

  grant(user.id, product.credits, "purchase", verified.purchaseToken);

  return c.json({
    balance: balanceOf(user.id),
    credited: product.credits,
    alreadyProcessed: false,
  });
});

const subscriptionSchema = z.object({
  platform: z.enum(["android", "ios"]),
  productId: z.string().min(1),
  /** Play purchase token, or the StoreKit 2 transaction id. */
  token: z.string().min(1),
});

/**
 * Activates or restores a subscription.
 *
 * The app calls this after a purchase completes and again whenever it restores
 * purchases on a new device. Both cases are the same operation, because the
 * store - not the client, and not our database - decides what is owned. The
 * client is trusted for nothing except which token to ask about.
 */
accountRoutes.post("/subscriptions", async (c) => {
  const user = c.get("user");

  const parsed = subscriptionSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) {
    return c.json({ error: "That request was malformed." }, 400);
  }
  const { platform, productId, token } = parsed.data;

  const plan = planByProduct(productId);
  if (!plan) {
    return c.json({ error: "Unknown plan." }, 400);
  }

  let verified;
  try {
    verified = await verifySubscription(platform, productId, token);
  } catch (error) {
    if (error instanceof VerificationError) {
      return c.json({ error: error.message }, error.status as 400);
    }
    console.error("[subscriptions] verification blew up", error);
    return c.json({ error: "Could not verify the subscription. Try again." }, 503);
  }

  // The store names the product it actually sold. Trusting the client's
  // productId here would let a cheap plan claim an expensive one's allowance.
  const soldPlan = planByProduct(verified.productId);
  if (!soldPlan) {
    console.error("[subscriptions] store returned an unknown product", verified.productId);
    return c.json({ error: "That plan is no longer available." }, 400);
  }

  const { granted, balance } = applySubscription(user.id, soldPlan.id, verified);

  return c.json({
    balance,
    granted,
    entitlement: entitlementOf(user.id),
  });
});
