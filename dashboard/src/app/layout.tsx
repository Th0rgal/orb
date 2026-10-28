import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Script from "next/script";
import "./globals.css";
import { AppShell } from "@/components/app-shell";
import { AuthGate } from "@/components/auth-gate";
import { LibraryProvider } from "@/contexts/library-context";
import { MissionSwitcherProvider } from "@/contexts/mission-switcher-context";
import { ToastProvider } from "@/components/toast";
import { DevFetchThrottleInstaller } from "@/components/dev-fetch-throttle-installer";
import { BackendPreconnect } from "@/components/backend-preconnect";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "Core",
  description: "Autonomous coding agents in isolated environments",
  icons: {
    icon: "/favicon.svg",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <Script id="theme-init" strategy="beforeInteractive">
          {`
              (() => {
                try {
                  const query = window.matchMedia("(prefers-color-scheme: light)");
                  const getSystemTheme = () => query.matches ? "light" : "dark";
                  const getStoredTheme = () => {
                    const stored = localStorage.getItem("sandboxed-theme");
                    return stored === "light" || stored === "dark" ? stored : null;
                  };
                  const applyTheme = () => {
                    document.documentElement.dataset.theme = getStoredTheme() || getSystemTheme();
                  };
                  applyTheme();
                  query.addEventListener("change", applyTheme);
                  window.addEventListener("storage", (event) => {
                    if (event.key === "sandboxed-theme") applyTheme();
                  });
                } catch {
                  document.documentElement.dataset.theme = "dark";
                }
              })();
            `}
        </Script>
        <BackendPreconnect />
        <DevFetchThrottleInstaller />
        <AuthGate>
          <ToastProvider>
            <LibraryProvider>
              <MissionSwitcherProvider>
                <AppShell>{children}</AppShell>
              </MissionSwitcherProvider>
            </LibraryProvider>
          </ToastProvider>
        </AuthGate>
      </body>
    </html>
  );
}
