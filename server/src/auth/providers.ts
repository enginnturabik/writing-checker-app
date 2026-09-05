import { createRemoteJWKSet, jwtVerify } from "jose";

import { env } from "../env.ts";

export type Provider = "google" | "apple";

export interface VerifiedIdentity {
  provider: Provider;
  /** Stable per-provider user id. This is what we key accounts on. */
  subject: string;
  email: string | null;
}

export class IdentityError extends Error {
  readonly status: number;

  constructor(message: string, status = 401) {
    super(message);
    this.name = "IdentityError";
    this.status = status;
  }
}

// Remote key sets cache and rotate on their own, so build them once.
const GOOGLE_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/oauth2/v3/certs"),
);
const APPLE_JWKS = createRemoteJWKSet(
  new URL("https://appleid.apple.com/auth/keys"),
);

const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
const APPLE_ISSUER = "https://appleid.apple.com";

function audiences(raw: string | undefined): string[] {
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * Verifies a sign-in token and returns who it belongs to.
 *
 * The token is checked against the provider's own public keys, so a forged one
 * cannot mint an account. The audience check matters just as much: without it,
 * a token issued to a completely different app would be accepted here.
 */
export async function verifyIdentity(
  provider: Provider,
  idToken: string,
): Promise<VerifiedIdentity> {
  if (env.AUTH_VERIFICATION === "mock") {
    return mockIdentity(provider, idToken);
  }

  const allowed =
    provider === "google"
      ? audiences(env.GOOGLE_OAUTH_CLIENT_IDS)
      : audiences(env.APPLE_CLIENT_IDS);

  if (allowed.length === 0) {
    throw new IdentityError(
      `Signing in with ${provider} is not available right now.`,
      503,
    );
  }

  try {
    const { payload } = await jwtVerify(
      idToken,
      provider === "google" ? GOOGLE_JWKS : APPLE_JWKS,
      {
        issuer: provider === "google" ? GOOGLE_ISSUERS : APPLE_ISSUER,
        audience: allowed,
      },
    );

    if (!payload.sub) {
      throw new IdentityError("That sign-in token is missing an account id.");
    }

    // Google marks unverified addresses; treating one as an identity would let
    // someone claim an account they do not own.
    const emailVerified = payload["email_verified"];
    const email =
      typeof payload["email"] === "string" && emailVerified !== false
        ? (payload["email"] as string)
        : null;

    return { provider, subject: payload.sub, email };
  } catch (error) {
    if (error instanceof IdentityError) throw error;
    console.error(`[auth] ${provider} token rejected`, error);
    throw new IdentityError("That sign-in could not be verified.");
  }
}

/**
 * Development shortcut: `mock:<subject>` or `mock:<subject>:<email>`.
 * Guarded by AUTH_VERIFICATION, which the server warns about on every boot.
 */
function mockIdentity(provider: Provider, idToken: string): VerifiedIdentity {
  const parts = idToken.split(":");
  if (parts[0] !== "mock" || !parts[1]) {
    throw new IdentityError(
      "Mock sign-in expects a token shaped like mock:<subject>:<email>.",
    );
  }
  console.warn(
    `[auth] MOCK identity accepted for ${provider}:${parts[1]}. ` +
      "Never run this in production.",
  );
  return { provider, subject: parts[1], email: parts[2] ?? null };
}
