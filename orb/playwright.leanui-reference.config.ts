import {defineConfig} from '@playwright/test';
// Reference screenshots of the SolidJS desktop for the LeanUI parity table
// (scripts/leanui_parity.py). Not a test suite: it writes PNGs and asserts nothing visual.
// Software raster without partial raster: with the default flags the split-diff
// screen came out with 1-level colour differences in 3 of 5 runs.
const port = process.env.ORB_TEST_PORT || '1447';
export default defineConfig({
  testDir: './tests',
  testMatch: 'leanui-reference.capture.ts',
  workers: 1,
  retries: 0,
  use: {baseURL: `http://127.0.0.1:${port}`, channel: process.env.ORB_REFERENCE_CHANNEL || 'chrome',
    launchOptions: {args: (process.env.ORB_REFERENCE_CHROME_ARGS ?? '--disable-gpu --disable-partial-raster').split(' ').filter(Boolean)}},
  webServer: {command: `node node_modules/vite/bin/vite.js --host 127.0.0.1 --port ${port}`, url: `http://127.0.0.1:${port}`, reuseExistingServer: false},
});
