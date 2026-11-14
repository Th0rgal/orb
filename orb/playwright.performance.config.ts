import {defineConfig} from '@playwright/test';
// Timing-sensitive specs (virtualized scrolling, history anchoring, render
// budgets). CI runs them report-only on PRs and blocking on master.
const preview = process.env.ORB_PERF_PREVIEW === '1';
const appSpecs = ['app-performance.browser.spec.ts', 'heavy-mission-performance.browser.spec.ts', 'history-performance.browser.spec.ts'];
const devServer = {command: 'node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 1442', url: 'http://127.0.0.1:1442', reuseExistingServer: false};
export default defineConfig({
  testDir: './tests',
  testMatch: '*performance.browser.spec.ts',
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  use: {baseURL: 'http://127.0.0.1:1442', viewport: {width: 1100, height: 850}},
  // Whole-app measurements consume the same production build as the browser
  // kernel probe. Source-module/HTML fixtures still require the dev server.
  projects: preview ? [
    {name: 'app-preview', testMatch: appSpecs, use: {baseURL: 'http://127.0.0.1:1443'}},
    {name: 'fixtures-dev', testIgnore: appSpecs},
  ] : undefined,
  webServer: preview ? [devServer, {
    command: 'node node_modules/vite/bin/vite.js preview --host 127.0.0.1 --port 1443 --strictPort',
    url: 'http://127.0.0.1:1443', reuseExistingServer: false,
  }] : devServer,
});
