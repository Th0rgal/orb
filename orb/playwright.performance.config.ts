import {defineConfig} from '@playwright/test';
import base from './playwright.config';
export default defineConfig({...base,webServer:{command:'npm run dev -- --host 127.0.0.1 --port 1432',url:'http://127.0.0.1:1432',reuseExistingServer:false},use:{...base.use,baseURL:'http://127.0.0.1:1432'}});
