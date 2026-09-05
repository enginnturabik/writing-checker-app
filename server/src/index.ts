import { serve } from "@hono/node-server";

import { createApp } from "./app.ts";
import { env } from "./env.ts";

const app = createApp();

serve({ fetch: app.fetch, port: env.PORT, hostname: env.HOST }, (info) => {
  console.log(`Writing Checker server listening on http://${env.HOST}:${info.port}`);
  if (env.PURCHASE_VERIFICATION === "mock") {
    console.warn(
      "PURCHASE_VERIFICATION=mock - purchases are NOT verified. " +
        "Set it to `live` with store credentials before release.",
    );
  }
});
