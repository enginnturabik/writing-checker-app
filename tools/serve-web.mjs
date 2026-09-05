// Serves the built Flutter web app for local use.
//
// Deliberately plain Node with no dependencies: the launcher already needs
// Node for the API server, so this adds nothing new to install.

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../build/web/", import.meta.url));
const port = Number(process.env["WEB_PORT"] ?? 5123);

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".bin": "application/octet-stream",
};

const server = createServer(async (req, res) => {
  try {
    const { pathname } = new URL(req.url ?? "/", "http://localhost");
    let rel = decodeURIComponent(pathname);
    if (rel.endsWith("/")) rel += "index.html";

    const path = normalize(join(root, rel));
    // Never serve anything outside the build directory.
    if (!path.startsWith(normalize(root))) {
      res.writeHead(403).end("Forbidden");
      return;
    }

    const info = await stat(path).catch(() => null);
    // Unknown paths fall back to the app shell, so in-app routes still load.
    const file = info?.isFile() ? path : join(root, "index.html");

    res.writeHead(200, {
      "content-type": TYPES[extname(file)] ?? "application/octet-stream",
      // The bundle is rebuilt in place, so a cached copy would hide changes.
      "cache-control": "no-store",
    });
    res.end(await readFile(file));
  } catch {
    res.writeHead(404).end("Not found");
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Writing Checker app: http://127.0.0.1:${port}`);
  console.log("Close this window to stop it.");
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error(`Port ${port} is already in use - the app may already be running.`);
    process.exit(1);
  }
  throw error;
});
