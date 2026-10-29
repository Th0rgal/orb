import { defineConfig } from "@playwright/test";
const port = 1439;
const preview = process.env.ORB_KERNEL_PREVIEW === "1";
const browsers = (process.env.ORB_KERNEL_BROWSERS ?? "chromium").split(",").map(s => s.trim()).filter(Boolean) as ("chromium" | "webkit" | "firefox")[];
export default defineConfig({
  testDir: "./tests", testMatch: "kernel.browser.spec.ts", workers: 1,
  projects: browsers.map(browserName => ({ name: browserName, use: { browserName } })),
  use: { baseURL: `http://127.0.0.1:${port}` },
  webServer: {
    command: preview ? `./node_modules/.bin/vite preview --host 127.0.0.1 --port ${port}` : `./node_modules/.bin/vite --host 127.0.0.1 --port ${port}`,
    url: `http://127.0.0.1:${port}`, reuseExistingServer: false,
  },
});
