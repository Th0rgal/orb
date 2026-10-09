import { defineConfig } from "@playwright/test";
const port = process.env.ORB_TEST_PORT || "1451";
export default defineConfig({
  testDir: "./tests", testMatch: /inbox(?:-ui|-preferences)?\.browser\.spec\.ts/, workers: 1,
  metadata: { inboxVisualReferences: process.platform === "darwin" },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }, { name: "webkit", use: { browserName: "webkit" } }],
  use: { baseURL: `http://127.0.0.1:${port}`, viewport: { width: 1100, height: 900 } },
  webServer: { command: `./node_modules/.bin/vite --host 127.0.0.1 --port ${port}`, url: `http://127.0.0.1:${port}`, reuseExistingServer: false },
});
