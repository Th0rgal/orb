import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir:"./tests", testMatch:"overlays.browser.spec.ts", workers:1, timeout:30000,
  projects:[{name:"chromium",use:{browserName:"chromium"}},{name:"webkit",use:{browserName:"webkit"}}],
  use:{baseURL:"http://127.0.0.1:1449",viewport:{width:1100,height:850}},
  webServer:{command:"./node_modules/.bin/vite --host 127.0.0.1 --port 1449",url:"http://127.0.0.1:1449/tests/overlays.html",reuseExistingServer:false},
});
