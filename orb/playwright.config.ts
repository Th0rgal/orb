import { defineConfig } from "@playwright/test";
const port = process.env.ORB_TEST_PORT || "1431";
export default defineConfig({
  testDir: "./tests", testMatch: "*.browser.spec.ts", workers: 1,
  // The specs measure timing-sensitive behaviour (virtualized scrolling,
  // send polls); a shared runner makes one of them miss its window in about
  // one run out of three. A retry separates that from a real regression,
  // and the report still lists what was retried.
  retries: process.env.CI ? 2 : 0,
  use: { baseURL: `http://127.0.0.1:${port}`, viewport: { width: 1100, height: 900 } },
  webServer: { command: `pnpm dev --host 127.0.0.1 --port ${port}`, url: `http://127.0.0.1:${port}`, reuseExistingServer: false },
});
