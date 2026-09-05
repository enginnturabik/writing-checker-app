import type { User } from "./auth.ts";

/** Variables attached to a request by the auth middleware. */
export interface AppEnv {
  Variables: {
    user: User;
  };
}
