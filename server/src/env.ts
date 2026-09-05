import { z } from "zod";

/**
 * Configuration, validated once at boot. A missing or malformed value should
 * stop the process here rather than surface as a confusing 500 later.
 */
const schema = z.object({
  PORT: z.coerce.number().int().positive().default(8787),
  HOST: z.string().default("0.0.0.0"),

  /** The only place the Anthropic key exists. Never leaves this process. */
  ANTHROPIC_API_KEY: z.string().min(1, "ANTHROPIC_API_KEY is required"),

  /** Signs device tokens. Rotating it logs every device out. */
  AUTH_SECRET: z
    .string()
    .min(32, "AUTH_SECRET must be at least 32 characters"),

  DATABASE_PATH: z.string().default("./data/app.db"),

  /**
   * Credits handed to a device the first time it registers. The default buys
   * 3 quick checks, 3 advanced ones and a single full report - enough to have
   * tasted the tier that costs the most to sell, at about 41 cents of upstream
   * cost per signup that never pays.
   */
  FREE_TRIAL_CREDITS: z.coerce.number().int().min(0).default(40),

  /**
   * Credits a user without a subscription is topped back up to each week.
   * This is the free plan, and it is a top-up rather than an addition, so it
   * cannot be hoarded. Set to 0 to switch the free plan off entirely.
   */
  FREE_WEEKLY_CREDITS: z.coerce.number().int().min(0).default(5),

  /**
   * Shared secret both stores must present on their notification endpoints.
   * Required once PURCHASE_VERIFICATION=live: without it the webhooks reject
   * everything, and renewals would only be noticed when the app next opens.
   */
  WEBHOOK_SECRET: z.string().optional(),

  /** Word ceilings, enforced before any tokens are spent. */
  MAX_WORDS_STANDARD: z.coerce.number().int().positive().default(600),
  MAX_WORDS_DEEP: z.coerce.number().int().positive().default(1500),

  /** Largest attachment accepted, in megabytes of decoded bytes. */
  MAX_ATTACHMENT_MB: z.coerce.number().positive().default(6),

  /** Abuse limits per device. */
  RATE_LIMIT_PER_MINUTE: z.coerce.number().int().positive().default(4),
  RATE_LIMIT_PER_DAY: z.coerce.number().int().positive().default(60),

  /** Comma-separated origins for the Flutter web build. Empty disables CORS. */
  ALLOWED_ORIGINS: z.string().default(""),

  /**
   * How purchases are verified. `mock` accepts anything and exists so the
   * app-side flow can be built and tested before store credentials arrive.
   * Never run `mock` in production.
   */
  PURCHASE_VERIFICATION: z.enum(["mock", "live"]).default("mock"),

  /**
   * How sign-in tokens are checked. `mock` accepts `mock:<subject>:<email>`
   * so the account flow can be built before OAuth clients exist.
   * Never run `mock` in production.
   */
  AUTH_VERIFICATION: z.enum(["mock", "live"]).default("mock"),

  /**
   * Comma-separated OAuth client ids accepted as the token audience. Android,
   * iOS and web each have their own, and all of them belong here.
   */
  GOOGLE_OAUTH_CLIENT_IDS: z.string().optional(),

  /** Bundle id for native Sign in with Apple, plus any Services ID for web. */
  APPLE_CLIENT_IDS: z.string().optional(),

  // --- Google Play, required when PURCHASE_VERIFICATION=live on Android ---
  GOOGLE_PACKAGE_NAME: z.string().optional(),
  GOOGLE_SERVICE_ACCOUNT_EMAIL: z.string().optional(),
  /** PEM private key from the service account JSON, newlines escaped as \n. */
  GOOGLE_SERVICE_ACCOUNT_KEY: z.string().optional(),

  // --- App Store, required when PURCHASE_VERIFICATION=live on iOS ---
  APPLE_BUNDLE_ID: z.string().optional(),
  APPLE_ISSUER_ID: z.string().optional(),
  APPLE_KEY_ID: z.string().optional(),
  /** Contents of the .p8 private key from App Store Connect. */
  APPLE_PRIVATE_KEY: z.string().optional(),
  APPLE_ENVIRONMENT: z.enum(["sandbox", "production"]).default("sandbox"),
});

export type Env = z.infer<typeof schema>;

function load(): Env {
  const parsed = schema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  ${i.path.join(".") || "(root)"}: ${i.message}`)
      .join("\n");
    console.error(`Invalid configuration:\n${issues}`);
    process.exit(1);
  }

  const env = parsed.data;

  if (env.PURCHASE_VERIFICATION === "live") {
    const missingGoogle =
      !env.GOOGLE_PACKAGE_NAME ||
      !env.GOOGLE_SERVICE_ACCOUNT_EMAIL ||
      !env.GOOGLE_SERVICE_ACCOUNT_KEY;
    const missingApple =
      !env.APPLE_BUNDLE_ID ||
      !env.APPLE_ISSUER_ID ||
      !env.APPLE_KEY_ID ||
      !env.APPLE_PRIVATE_KEY;

    if (missingGoogle && missingApple) {
      console.error(
        "PURCHASE_VERIFICATION=live but neither Google nor Apple credentials " +
          "are configured. Set at least one store.",
      );
      process.exit(1);
    }
  }

  if (env.PURCHASE_VERIFICATION === "live" && !env.WEBHOOK_SECRET) {
    console.error(
      "PURCHASE_VERIFICATION=live but WEBHOOK_SECRET is not set. Store " +
        "notifications would be rejected and renewals never credited.",
    );
    process.exit(1);
  }

  if (
    env.AUTH_VERIFICATION === "live" &&
    !env.GOOGLE_OAUTH_CLIENT_IDS &&
    !env.APPLE_CLIENT_IDS
  ) {
    console.error(
      "AUTH_VERIFICATION=live but no OAuth client ids are configured. " +
        "Set GOOGLE_OAUTH_CLIENT_IDS and/or APPLE_CLIENT_IDS.",
    );
    process.exit(1);
  }

  return env;
}

export const env = load();

export const allowedOrigins = env.ALLOWED_ORIGINS.split(",")
  .map((o) => o.trim())
  .filter(Boolean);
