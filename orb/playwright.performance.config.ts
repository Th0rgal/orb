import {defineConfig} from '@playwright/test';
// Timing-sensitive specs (virtualized scrolling, history anchoring, render
// budgets). CI runs them report-only on PRs and blocking on master.
export default defineConfig({
  testDir: './tests',
  testMatch: '*performance.browser.spec.ts',
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  use: {baseURL: 'http://127.0.0.1:1442', viewport: {width: 1100, height: 850}},
  webServer: {command: 'node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 1442', url: 'http://127.0.0.1:1442', reuseExistingServer: false},
});
