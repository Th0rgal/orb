import { defineConfig } from '@playwright/test';
export default defineConfig({webServer:{command:'node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 1431',url:'http://127.0.0.1:1431',reuseExistingServer:false},testDir:'./tests',testMatch:['project-settings.browser.spec.ts','queued-messages.browser.spec.ts'],use:{baseURL:'http://127.0.0.1:1431',viewport:{width:1100,height:900}}});
