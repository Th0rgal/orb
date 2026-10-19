import { execSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { defineConfig, type Plugin } from "vite";
import solid from "vite-plugin-solid";

function palomaPub(): Plugin {
  return {
    name: "paloma-pub",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url !== "/__paloma_pub") return next();
        try {
          res.setHeader("Content-Type", "text/plain");
          res.end(fs.readFileSync(path.join(os.homedir(), ".ssh/paloma.pub"), "utf8"));
        } catch {
          res.statusCode = 404;
          res.end("");
        }
      });
    },
  };
}

/** Short commit of the checkout being built, or "dev" outside git. */
function buildId(): string {
  try { return execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim() || "dev"; } catch { return "dev"; }
}
const pkg = JSON.parse(fs.readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string };

export default defineConfig({
  define: {
    "import.meta.env.VITE_ORB_VERSION": JSON.stringify(pkg.version),
    "import.meta.env.VITE_ORB_BUILD": JSON.stringify(buildId()),
  },
  plugins: [solid(), palomaPub()],
  clearScreen: false,
  // Polling also detects edits made by agent processes without macOS file events.
  server: { port: 1430, strictPort: true, watch: { usePolling: true, interval: 500, ignored: ["**/src-tauri/**", "**/target/**", "**/dist/**"] } },
  build: { target: "safari15" },
});
