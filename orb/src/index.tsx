import { initializeKernel } from "./orbKernelAbi";
import { startApp } from "./startup";
import { initTheme } from "./theme";

initTheme();
startApp(document.getElementById("root")!, initializeKernel, async () => {
  const { mountApp } = await import("./appEntry");
  await mountApp(document.getElementById("root")!);
});
