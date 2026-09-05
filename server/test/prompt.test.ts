import assert from "node:assert/strict";
import { before, describe, it } from "node:test";

process.env["ANTHROPIC_API_KEY"] = "test-key";
process.env["AUTH_SECRET"] = "test-secret-that-is-long-enough-32chars";
process.env["DATABASE_PATH"] = ":memory:";

type PromptModule = typeof import("../src/marking/prompt.ts");
let prompt: PromptModule;

before(async () => {
  prompt = await import("../src/marking/prompt.ts");
});

function brief(overrides: Partial<PromptModule["MarkingBrief"]> = {}) {
  return prompt.buildUserInstructions({
    text: "Je suis alle au marche.",
    learningLanguage: "fr",
    nativeLanguage: "tr",
    hasAttachment: false,
    ...overrides,
  } as never);
}

describe("marking brief", () => {
  it("names the native language and the language being learned", () => {
    const text = brief();

    assert.match(text, /native speaker of Turkish/);
    assert.match(text, /learning French/);
  });

  it("puts feedback in the native language by default", () => {
    const text = brief();

    assert.match(text, /next step in Turkish/);
  });

  it("asks for first-language interference to be called out", () => {
    // The whole reason for collecting the mother tongue.
    assert.match(brief(), /Turkish speakers typically make/);
  });

  it("still knows the native language when the target is auto", () => {
    const text = brief({ learningLanguage: "auto" } as never);

    assert.match(text, /native speaker of Turkish/);
    assert.match(text, /detect from the text itself/);
  });

  it("tells the model to flag a submission in the wrong language", () => {
    assert.match(brief(), /some other language/);
  });

  it("carries the submission itself", () => {
    assert.match(brief(), /Je suis alle au marche\./);
  });

  it("infers the level instead of asking the learner for one", () => {
    const text = brief();

    assert.match(text, /Level: unknown/);
    assert.doesNotMatch(text, /Text type/);
    assert.doesNotMatch(text, /Strict marking/);
  });

  it("switches to the attachment wording when there is no typed text", () => {
    const text = brief({ text: "", hasAttachment: true } as never);

    assert.match(text, /attached file/);
    assert.doesNotMatch(text, /<<<SUBMISSION/);
  });
});

describe("system prompt caching", () => {
  // The system prompt is the cached prefix, and a prefix below the model's
  // minimum is not cached at all - no error, just a silently higher bill.
  // Measured at 3001 chars: 1041 tokens on Sonnet 5, whose minimum is 1024.
  // That is 17 tokens of margin, so shortening the prompt can switch caching
  // off on the advanced tier without anything visibly breaking.
  //
  // If a shorter prompt is genuinely better, lower this floor deliberately and
  // re-measure with messages.countTokens rather than deleting the guard.
  const CACHE_FLOOR_CHARS = 2950;

  it("stays long enough for Sonnet 5 to cache it", () => {
    assert.ok(
      prompt.SYSTEM_PROMPT.length >= CACHE_FLOOR_CHARS,
      `SYSTEM_PROMPT is ${prompt.SYSTEM_PROMPT.length} chars, below the ` +
        `${CACHE_FLOOR_CHARS} needed to stay over Sonnet 5's 1024-token ` +
        `cache minimum. Re-measure before lowering this.`,
    );
  });
});
