import Anthropic from "@anthropic-ai/sdk";

import { MODEL_PRICING, TIERS, costUsd, type Tier } from "../catalog.ts";
import { env } from "../env.ts";
import {
  RESPONSE_SCHEMA,
  SYSTEM_PROMPT,
  buildUserInstructions,
  type MarkingBrief,
} from "./prompt.ts";

/** The key lives here and nowhere else in the system. */
const anthropic = new Anthropic({ apiKey: env.ANTHROPIC_API_KEY });

export interface Attachment {
  kind: "image" | "pdf";
  mediaType: string;
  /** Base64, no data: prefix. */
  data: string;
}

export interface MarkingRequest extends MarkingBrief {
  tier: Tier;
  attachment?: Attachment;
}

export interface MarkingResult {
  report: unknown;
  model: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
}

export class MarkingError extends Error {
  readonly status: number;
  readonly retryable: boolean;

  constructor(message: string, status = 502, retryable = false) {
    super(message);
    this.name = "MarkingError";
    this.status = status;
    this.retryable = retryable;
  }
}

/**
 * Marks one submission.
 *
 * Streaming is used even though only the final object is returned: a deep
 * check can run well past a normal HTTP timeout, and streaming keeps the
 * connection alive while also letting the caller report progress.
 */
export async function mark(
  request: MarkingRequest,
  onProgress?: (chars: number) => void,
): Promise<MarkingResult> {
  const spec = TIERS[request.tier];
  const content: Anthropic.Beta.BetaContentBlockParam[] = [];

  // Attachments first: the model reads a document better when it precedes the
  // instructions that refer to it.
  if (request.attachment) {
    if (request.attachment.kind === "image") {
      content.push({
        type: "image",
        source: {
          type: "base64",
          media_type: request.attachment
            .mediaType as "image/jpeg" | "image/png" | "image/gif" | "image/webp",
          data: request.attachment.data,
        },
      });
    } else {
      content.push({
        type: "document",
        source: {
          type: "base64",
          media_type: "application/pdf",
          data: request.attachment.data,
        },
      });
    }
  }

  content.push({ type: "text", text: buildUserInstructions(request) });

  const outputConfig: Anthropic.Beta.BetaOutputConfig = {
    format: {
      type: "json_schema",
      schema: RESPONSE_SCHEMA as unknown as Record<string, unknown>,
    },
  };
  // Older tiers reject output_config.effort outright.
  if (MODEL_PRICING[spec.model]?.supportsEffort && spec.effort) {
    outputConfig.effort = spec.effort;
  }

  let text = "";
  let inputTokens = 0;
  let outputTokens = 0;

  // Opus 5 runs safety classifiers that can decline a submission outright.
  // Without a fallback that costs the user their credits and returns nothing,
  // so let the API re-run the request on another model inside the same call.
  // `"default"` routes by refusal category, which beats pinning a model that
  // will eventually be deprecated. Only Opus 5 has fallback targets; sending
  // the parameter on the other tiers is rejected.
  const fallbackParams =
    spec.model === "claude-opus-5"
      ? {
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default" as const,
        }
      : {};

  let servedBy = spec.model;

  try {
    const stream = anthropic.beta.messages.stream({
      model: spec.model,
      max_tokens: spec.maxTokens,
      // Stable prefix, cached so repeat checks pay a fraction for it.
      //
      // Measured prefix: 771 tokens on Haiku, 1041 on Sonnet 5 and Opus 5
      // (different tokenizers). Against the per-model minimums in
      // MODEL_PRICING that means the marker is silently ignored on the quick
      // tier - Haiku 4.5 needs 4096 - and clears Sonnet 5's 1024 by only 17
      // tokens. See the prompt-length guard in test/prompt.test.ts.
      system: [
        {
          type: "text",
          text: SYSTEM_PROMPT,
          cache_control: { type: "ephemeral" },
        },
      ],
      messages: [{ role: "user", content }],
      output_config: outputConfig,
      ...fallbackParams,
    });

    for await (const event of stream) {
      if (
        event.type === "content_block_delta" &&
        event.delta.type === "text_delta"
      ) {
        text += event.delta.text;
        onProgress?.(text.length);
      }
    }

    const message = await stream.finalMessage();
    inputTokens =
      message.usage.input_tokens + (message.usage.cache_read_input_tokens ?? 0);
    outputTokens = message.usage.output_tokens;
    // A fallback answers as a different model, and it is billed as one.
    servedBy = message.model;

    if (message.stop_reason === "refusal") {
      throw new MarkingError(
        "The model declined to mark this submission. Try removing sensitive content.",
        422,
      );
    }
    if (message.stop_reason === "max_tokens") {
      throw new MarkingError(
        "That text is too long to mark in one pass. Split it into shorter sections.",
        413,
      );
    }
  } catch (error) {
    if (error instanceof MarkingError) throw error;
    throw translate(error);
  }

  let report: unknown;
  try {
    report = JSON.parse(text);
  } catch {
    throw new MarkingError(
      "The feedback came back malformed. Please try again.",
      502,
      true,
    );
  }

  return {
    report,
    model: servedBy,
    inputTokens,
    outputTokens,
    costUsd: costUsd(servedBy, inputTokens, outputTokens),
  };
}

/**
 * Turns SDK errors into something safe to send to a phone. Upstream messages
 * can mention billing or key state, which is our problem, not the user's.
 */
function translate(error: unknown): MarkingError {
  if (error instanceof Anthropic.APIError) {
    const status = error.status ?? 0;

    if (status === 401 || status === 403) {
      console.error("[marking] upstream auth failure - check ANTHROPIC_API_KEY");
      return new MarkingError("Marking is temporarily unavailable.", 503, true);
    }
    if (status === 400 && /credit/i.test(error.message)) {
      console.error("[marking] OUT OF CREDIT on the Anthropic account");
      return new MarkingError("Marking is temporarily unavailable.", 503, true);
    }
    if (status === 429) {
      return new MarkingError(
        "Marking is busy right now. Try again in a few seconds.",
        429,
        true,
      );
    }
    if (status === 529 || status >= 500) {
      return new MarkingError(
        "Marking is temporarily unavailable. Please try again.",
        503,
        true,
      );
    }
    console.error("[marking] upstream error", status, error.message);
    return new MarkingError("That submission could not be marked.", 502);
  }

  console.error("[marking] unexpected error", error);
  return new MarkingError("Marking failed unexpectedly. Please try again.", 502, true);
}
