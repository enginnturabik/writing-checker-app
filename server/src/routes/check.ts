import { randomUUID } from "node:crypto";

import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { z } from "zod";

import { TIERS } from "../catalog.ts";
import { InsufficientCredits, balanceOf, refund, reserve } from "../credits.ts";
import { db, now } from "../db.ts";
import { LimitExceeded, countWords, enforceRateLimit, enforceSize, priceOf } from "../limits.ts";
import { MarkingError, mark } from "../marking/client.ts";
import type { AppEnv } from "../types.ts";

const bodySchema = z.object({
  text: z.string().default(""),
  tier: z.enum(["quick", "advanced", "report"]).default("quick"),
  learningLanguage: z.string().max(10).default("auto"),
  nativeLanguage: z.string().max(10).default("en"),
  attachment: z
    .object({
      kind: z.enum(["image", "pdf"]),
      mediaType: z.string().max(60),
      data: z.string().min(1),
    })
    .optional(),
});

export const checkRoutes = new Hono<AppEnv>();

checkRoutes.post("/check", async (c) => {
  const user = c.get("user");

  const parsed = bodySchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) {
    return c.json({ error: "That request was malformed." }, 400);
  }
  const body = parsed.data;

  if (!body.text.trim() && !body.attachment) {
    return c.json({ error: "There is nothing to check." }, 400);
  }

  // Everything that can be rejected is rejected before the stream opens, so
  // the app gets a real status code instead of an error inside a 200.
  try {
    enforceRateLimit(user.id);
    enforceSize(
      body.text,
      body.tier,
      body.attachment ? decodedSize(body.attachment.data) : 0,
    );
  } catch (error) {
    if (error instanceof LimitExceeded) {
      const headers: Record<string, string> = {};
      if (error.retryAfterSeconds) {
        headers["retry-after"] = String(error.retryAfterSeconds);
      }
      return c.json({ error: error.message }, 429, headers);
    }
    throw error;
  }

  const price = priceOf(body.tier, Boolean(body.attachment));
  const checkId = randomUUID();
  const spec = TIERS[body.tier];

  db.prepare(
    `INSERT INTO checks (id, user_id, tier, model, words, credits, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, 'reserved', ?)`,
  ).run(
    checkId,
    user.id,
    body.tier,
    spec.model,
    countWords(body.text),
    price,
    now(),
  );

  // Debit up front. A client that disconnects mid-stream has still consumed
  // upstream tokens, so the credits are only returned when marking fails.
  let balance: number;
  try {
    balance = reserve(user.id, price, checkId);
  } catch (error) {
    if (error instanceof InsufficientCredits) {
      db.prepare("UPDATE checks SET status = 'declined', finished_at = ? WHERE id = ?")
        .run(now(), checkId);
      return c.json(
        {
          error: "You are out of credits.",
          code: "insufficient_credits",
          balance: error.balance,
          required: error.required,
        },
        402,
      );
    }
    throw error;
  }

  return streamSSE(c, async (stream) => {
    const send = (event: string, data: unknown) =>
      stream.writeSSE({ event, data: JSON.stringify(data) });

    await send("progress", { stage: "reading", chars: 0 });

    try {
      let lastReport = 0;
      const result = await mark(
        { ...body, hasAttachment: Boolean(body.attachment) },
        (chars) => {
          // Throttled so a fast stream does not flood the phone with events.
          if (chars - lastReport < 400) return;
          lastReport = chars;
          void send("progress", { stage: "writing", chars });
        },
      );

      db.prepare(
        `UPDATE checks SET status = 'completed', input_tokens = ?, output_tokens = ?,
         cost_usd = ?, finished_at = ? WHERE id = ?`,
      ).run(
        result.inputTokens,
        result.outputTokens,
        result.costUsd,
        now(),
        checkId,
      );

      await send("result", {
        checkId,
        report: result.report,
        balance,
        creditsSpent: price,
      });
    } catch (error) {
      refund(user.id, price, checkId);
      const message =
        error instanceof MarkingError
          ? error.message
          : "Marking failed. Please try again.";

      db.prepare("UPDATE checks SET status = 'failed', finished_at = ? WHERE id = ?")
        .run(now(), checkId);

      if (!(error instanceof MarkingError)) {
        console.error("[check] unexpected failure", error);
      }

      await send("error", {
        error: message,
        // The credits are back, so tell the app the true balance.
        balance: balanceOf(user.id),
        refunded: price,
      });
    }
  });
});

/** Byte length a base64 payload decodes to, without decoding it. */
function decodedSize(base64: string): number {
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}
