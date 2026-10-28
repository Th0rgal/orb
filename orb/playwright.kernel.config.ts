import { defineConfig } from "@playwright/test";
const port = 1439;
export default defineConfig({
  testDir: "./tests", testMatch: "kernel.browser.spec.ts", workers: 1,
  use: { baseURL: `http://127.0.0.1:${port}` },
  webServer: {
    command: `pnpm dev --host 127.0.0.1 --port ${port}`,
    url: `http://127.0.0.1:${port}`, reuseExistingServer: false,
  },
});
