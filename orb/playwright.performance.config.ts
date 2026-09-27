import {defineConfig} from '@playwright/test';
export default defineConfig({testDir:'./tests',testMatch:'performance.browser.spec.ts',workers:1,use:{baseURL:'http://127.0.0.1:1442',viewport:{width:1100,height:850}},webServer:{command:'node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 1442',url:'http://127.0.0.1:1442',reuseExistingServer:false}});
