import { randomUUID } from "node:crypto";

import { SignJWT, jwtVerify } from "jose";

import { balanceOf, grant } from "./credits.ts";
import { db, now } from "./db.ts";
import { env } from "./env.ts";

const secret = new TextEncoder().encode(env.AUTH_SECRET);
const ISSUER = "writing-checker";
const TOKEN_TTL = "365d";

export interface User {
  id: string;
  install_id: string;
  platform: string;
  blocked: number;
  merged_into: string | null;
  created_at: number;
}

/**
 * Follows `merged_into` to the account that actually holds the credits.
 *
 * An anonymous account that has been folded into a signed-in one must never be
 * returned: its balance lives elsewhere now. The hop limit stops a cycle from
 * hanging a request, however it might have been introduced.
 */
function resolve(user: User | undefined): User | undefined {
  let current = user;
  for (let hops = 0; current?.merged_into && hops < 8; hops++) {
    current = db
      .prepare("SELECT * FROM users WHERE id = ?")
      .get(current.merged_into) as unknown as User | undefined;
  }
  return current;
}

export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

/**
 * Anonymous device accounts: the app generates an install id on first launch
 * and trades it for a long-lived token. No email, no password, nothing to
 * leak — the trade-off is that a reinstall looks like a new device, which is
 * why the free grant is small. Move to Sign in with Apple/Google when you want
 * balances to survive reinstalls.
 */
export async function registerDevice(
  installId: string,
  platform: string,
): Promise<{ user: User; token: string; balance: number; isNew: boolean }> {
  const existing = resolve(
    db.prepare("SELECT * FROM users WHERE install_id = ?").get(installId) as
      | unknown as User
      | undefined,
  );

  let user = existing;
  let isNew = false;

  if (!user) {
    const id = randomUUID();
    db.prepare(
      "INSERT INTO users (id, install_id, platform, blocked, created_at) VALUES (?, ?, ?, 0, ?)",
    ).run(id, installId, platform, now());
    user = db.prepare("SELECT * FROM users WHERE id = ?").get(id) as unknown as User;
    isNew = true;
  }

  // Idempotent by ref, so replaying registration never re-grants the trial.
  // Only brand new accounts get one: a device that followed a merge pointer to
  // a signed-in account must not collect a second trial there.
  if (env.FREE_TRIAL_CREDITS > 0 && isNew) {
    grant(user.id, env.FREE_TRIAL_CREDITS, "grant", `trial:${installId}`);
  }

  return {
    user,
    token: await issueToken(user.id),
    balance: balanceOf(user.id),
    isNew,
  };
}

export async function issueToken(userId: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuer(ISSUER)
    .setIssuedAt()
    .setExpirationTime(TOKEN_TTL)
    .sign(secret);
}

export async function userFromToken(token: string): Promise<User> {
  let subject: string | undefined;
  try {
    const { payload } = await jwtVerify(token, secret, { issuer: ISSUER });
    subject = payload.sub;
  } catch {
    throw new AuthError("Your session is no longer valid. Please reopen the app.");
  }

  if (!subject) throw new AuthError("Malformed session token.");

  const user = resolve(
    db.prepare("SELECT * FROM users WHERE id = ?").get(subject) as
      | unknown as User
      | undefined,
  );

  if (!user) throw new AuthError("This device is no longer registered.");
  if (user.blocked) throw new AuthError("This device has been blocked.");

  return user;
}

export function bearerToken(header: string | undefined): string {
  if (!header?.startsWith("Bearer ")) {
    throw new AuthError("Missing session token.");
  }
  return header.slice("Bearer ".length).trim();
}
