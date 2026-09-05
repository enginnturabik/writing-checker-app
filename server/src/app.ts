import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";

import { AuthError, bearerToken, userFromToken } from "./auth.ts";
import { migrate } from "./db.ts";
import { settleAllowances } from "./subscriptions.ts";
import { allowedOrigins, env } from "./env.ts";
import { accountRoutes, publicRoutes } from "./routes/account.ts";
import { checkRoutes } from "./routes/check.ts";
import { webhookRoutes } from "./routes/webhooks.ts";
import type { AppEnv } from "./types.ts";

export function createApp(): Hono<AppEnv> {
  migrate();

  const app = new Hono<AppEnv>();

  app.use("*", logger());

  // Only needed for the Flutter web build; native apps are not origin-bound.
  if (allowedOrigins.length > 0) {
    app.use("*", cors({ origin: allowedOrigins, allowHeaders: ["content-type", "authorization"] }));
  }

  app.get("/health", (c) =>
    c.json({ ok: true, verification: env.PURCHASE_VERIFICATION }),
  );

  app.route("/v1", publicRoutes);

  // Stores authenticate with the shared secret, not a device token, so these
  // mount before the auth middleware.
  app.route("/v1", webhookRoutes);

  // Everything below requires a device token.
  const authed = new Hono<AppEnv>();
  authed.use("*", async (c, next) => {
    try {
      const token = bearerToken(c.req.header("authorization"));
      const user = await userFromToken(token);
      c.set("user", user);
      // The heartbeat for both allowances: a monthly subscription drip and the
      // free weekly top-up. Both are an indexed read and no write until
      // something is actually due, so every authenticated request can afford
      // to ask - and nothing depends on the app remembering to.
      settleAllowances(user.id);
    } catch (error) {
      if (error instanceof AuthError) {
        return c.json({ error: error.message, code: "unauthenticated" }, 401);
      }
      throw error;
    }
    await next();
  });
  authed.route("/", accountRoutes);
  authed.route("/", checkRoutes);

  app.route("/v1", authed);

  app.notFound((c) => c.json({ error: "Not found." }, 404));

  app.onError((error, c) => {
    console.error("[server] unhandled error", error);
    return c.json({ error: "Something went wrong on our side." }, 500);
  });

  return app;
}
