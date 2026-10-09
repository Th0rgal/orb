import { defineConfig } from '@playwright/test';
const port = process.env.ORB_TEST_PORT || '1433';
export default defineConfig({
  testDir: './tests',
  testMatch: 'antigravity-provider.browser.spec.ts',
  workers: 1,
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
    { name: 'webkit', use: { browserName: 'webkit' } },
  ],
  use: { baseURL: `http://127.0.0.1:${port}`, viewport: { width: 1100, height: 900 } },
  webServer: { command: `pnpm dev --host 127.0.0.1 --port ${port}`, url: `http://127.0.0.1:${port}`, reuseExistingServer: false },
});
