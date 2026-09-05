/**
 * The marking instructions and the shape of the report.
 *
 * These live on the server, not in the app, so the marking can be improved for
 * everyone without shipping a store update.
 */

export const SYSTEM_PROMPT = `You are an experienced language teacher who marks student writing in any
language. You have taught beginners through to near-native writers, and you
grade the way a good teacher does: honest about mistakes, specific about why,
and encouraging about what to do next.

WHAT YOU RECEIVE
The student submission arrives as typed text, as a photo of handwriting, or as
a PDF. When it is an image or a PDF, first transcribe it faithfully, keeping the
original mistakes exactly as written, and treat that transcription as the text.

HOW YOU MARK
1. Work in the language the student wrote in. Never translate their text.
2. Flag a span only when you can say what is wrong with it. Do not rewrite
   correct sentences just because you would have phrased them differently.
3. Judge against the stated level. An A2 learner is not marked for the register
   subtleties you would expect from C1, but a C1 learner is.
4. Each correction covers one problem. Split a sentence with two unrelated
   errors into two corrections rather than rewriting the whole sentence.
5. Prefer the smallest span that contains the error. Include just enough
   surrounding words for the fix to make sense.
6. Explanations name the rule in plain words and say why the original fails.
   "Wrong verb form" is not enough; "after \`il faut que\` French uses the
   subjunctive, so \`est\` becomes \`soit\`" is.
7. Set severity by how much it costs the reader: critical breaks understanding,
   moderate marks the writer as non-native, minor is a slip.

THE FIELDS
- \`original\`: copy the erroneous span EXACTLY as it appears in the student text,
  character for character. Do not normalise spacing, quotes or accents. The app
  locates it by exact string search, so an inexact copy loses the highlight.
- \`context_before\`: the 10 to 25 characters that immediately precede \`original\`
  in the student text, copied exactly. This disambiguates repeated spans. Use an
  empty string only when the span starts the text.
- \`correction\`: the replacement for that exact span. Use an empty string when
  the span should simply be deleted.
- \`rule\`: a short label for the underlying rule, reusable across submissions,
  such as "subject-verb agreement" or "preposition after arriver".
- \`scores\`: 0-100 per dimension. Anchor them: 90+ reads as written by an
  educated native, 70-89 is fluent with visible non-native traces, 50-69 is
  understandable but effortful, below 50 obstructs the reader.
- \`cefr_estimate\`: the CEFR band this piece of writing demonstrates (A1 to C2),
  which may differ from the level the student claims.
- \`strengths\`: 2-4 specific things done well, quoting the student where useful.
- \`priorities\`: 2-4 things to fix first, ordered by impact.
- \`next_steps\`: concrete practice suggestions, not generic advice.
- \`vocabulary_upgrades\`: correct wording that a stronger writer would sharpen.
  These are not errors and must not appear in \`corrections\`.

Return only the JSON object described by the schema. Every field is required.`;

const LANGUAGE_NAMES: Record<string, string> = {
  auto: "Unknown",
  en: "English",
  fr: "French",
  de: "German",
  es: "Spanish",
  it: "Italian",
  pt: "Portuguese",
  nl: "Dutch",
  tr: "Turkish",
  ru: "Russian",
  pl: "Polish",
  sv: "Swedish",
  ar: "Arabic",
  zh: "Chinese",
  ja: "Japanese",
  ko: "Korean",
  hi: "Hindi",
  id: "Indonesian",
  uk: "Ukrainian",
  el: "Greek",
};

export function languageName(code: string): string {
  return LANGUAGE_NAMES[code] ?? code;
}

export interface MarkingBrief {
  text: string;
  /** The language being learned; `auto` leaves it to be detected. */
  learningLanguage: string;
  /** The learner's mother tongue. Feedback is written in this. */
  nativeLanguage: string;
  hasAttachment: boolean;
}

export function buildUserInstructions(brief: MarkingBrief): string {
  const native = languageName(brief.nativeLanguage);
  const lines: string[] = ["MARKING BRIEF"];

  lines.push(`- The student is a native speaker of ${native}.`);
  lines.push(
    brief.learningLanguage === "auto"
      ? "- They are learning a language you should detect from the text itself. Mark in that language."
      : `- They are learning ${languageName(brief.learningLanguage)}, and this submission should be written in it. If it is in some other language, say so in your summary and mark it anyway.`,
  );

  lines.push(
    "- Level: unknown. Infer it from the writing and mark against what you infer.",
    `- Write every explanation, summary, strength, priority and next step in ${native}, the language the student actually speaks, even though their text is in another language. Words you quote from their writing, and your corrections, stay in the original language.`,
    `- Where a mistake is one that ${native} speakers typically make in this language, say so and contrast the two languages briefly. That is the most useful thing you can tell them.`,
    "- Focus on real errors. Flag style only when it genuinely hurts the writing.",
  );

  lines.push("");
  if (!brief.text.trim() && brief.hasAttachment) {
    lines.push(
      "STUDENT SUBMISSION",
      "The submission is the attached file above. Transcribe it faithfully, then mark the transcription. Put your transcription in `corrected_text` only after applying the corrections; the spans in `original` must match your transcription exactly.",
    );
  } else {
    lines.push(
      "STUDENT SUBMISSION (between the markers, marker lines are not part of the text)",
      "<<<SUBMISSION",
      brief.text,
      "SUBMISSION>>>",
    );
  }

  return lines.join("\n");
}

/** Schema for `output_config.format`, mirrored by the app's parser. */
export const RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    detected_language: {
      type: "string",
      description: "Language of the submission in English, e.g. French",
    },
    language_code: { type: "string", description: "ISO 639-1 code, e.g. fr" },
    cefr_estimate: {
      type: "string",
      enum: ["A1", "A2", "B1", "B2", "C1", "C2"],
    },
    word_count: { type: "integer" },
    summary: {
      type: "string",
      description: "Two to four sentences of overall teacher feedback",
    },
    scores: {
      type: "object",
      properties: {
        grammar: { type: "integer" },
        vocabulary: { type: "integer" },
        spelling: { type: "integer" },
        coherence: { type: "integer" },
        style: { type: "integer" },
        overall: { type: "integer" },
      },
      required: [
        "grammar",
        "vocabulary",
        "spelling",
        "coherence",
        "style",
        "overall",
      ],
      additionalProperties: false,
    },
    corrected_text: { type: "string" },
    strengths: { type: "array", items: { type: "string" } },
    priorities: { type: "array", items: { type: "string" } },
    next_steps: { type: "array", items: { type: "string" } },
    corrections: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          original: {
            type: "string",
            description: "Exact erroneous span copied from the student text",
          },
          context_before: {
            type: "string",
            description: "Exact 10-25 characters preceding the span, or empty",
          },
          correction: {
            type: "string",
            description: "Replacement span, empty string to delete",
          },
          category: {
            type: "string",
            enum: [
              "grammar",
              "spelling",
              "punctuation",
              "vocabulary",
              "style",
              "register",
              "coherence",
              "other",
            ],
          },
          severity: { type: "string", enum: ["minor", "moderate", "critical"] },
          explanation: { type: "string" },
          rule: { type: "string" },
        },
        required: [
          "id",
          "original",
          "context_before",
          "correction",
          "category",
          "severity",
          "explanation",
          "rule",
        ],
        additionalProperties: false,
      },
    },
    vocabulary_upgrades: {
      type: "array",
      items: {
        type: "object",
        properties: {
          original: { type: "string" },
          suggestion: { type: "string" },
          note: { type: "string" },
        },
        required: ["original", "suggestion", "note"],
        additionalProperties: false,
      },
    },
  },
  required: [
    "detected_language",
    "language_code",
    "cefr_estimate",
    "word_count",
    "summary",
    "scores",
    "corrected_text",
    "strengths",
    "priorities",
    "next_steps",
    "corrections",
    "vocabulary_upgrades",
  ],
  additionalProperties: false,
} as const;
