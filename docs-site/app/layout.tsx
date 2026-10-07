import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Head } from "nextra/components";
import { ThemeProvider } from "@/components/theme-provider";
import "./globals.css";

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
    { media: "(prefers-color-scheme: dark)", color: "#0c0b0a" },
  ],
  colorScheme: "light dark",
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export const metadata: Metadata = {
  metadataBase: new URL("https://orb.thomas.md"),
  title: {
    default: "Orb (sandboxed.sh) | Your agents, machines and subscriptions",
    template: "%s | Orb (sandboxed.sh)",
  },
  description:
    "Run and orchestrate AI coding agents across your computer, your private cloud, and managed cloud services. Built for Claude Code, Codex, Antigravity (agy), OpenCode, Grok, Hermes, ChatGPT, and Cursor Cloud.",
  applicationName: "Orb",
  generator: "Next.js",
  keywords: [
    "orb",
    "sandboxed.sh",
    "ai agent",
    "claude code",
    "codex",
    "antigravity",
    "opencode",
    "grok",
    "hermes",
    "mcp",
    "model context protocol",
  ],
  authors: [{ name: "Thomas Marchand", url: "https://thomas.md" }],
  creator: "Thomas Marchand",
  publisher: "Orb",
  robots: {
    index: true,
    follow: true,
  },
  twitter: {
    card: "summary_large_image",
    title: "Orb (sandboxed.sh)",
    description:
      "Your agents, machines and subscriptions. One place to work on macOS and iOS.",
    creator: "@music_music_yo",
    images: ["/og-image.png"],
  },
  openGraph: {
    type: "website",
    locale: "en_US",
    url: "https://orb.thomas.md",
    siteName: "Orb",
    title: "Orb (sandboxed.sh)",
    description:
      "Your agents, machines and subscriptions. One place to work on macOS and iOS.",
    images: [
      {
        url: "/og-image.png",
        width: 1200,
        height: 630,
        alt: "Orb (sandboxed.sh) - Your agents, machines and subscriptions",
      },
    ],
  },
  icons: {
    icon: "/favicon.svg",
    apple: "/apple-touch-icon.png",
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "Orb",
  },
  other: {
    "msapplication-TileColor": "#0c0b0a",
  },
};

export default function RootLayout({
  children,
}: {
  children: ReactNode;
}) {
  return (
    <html lang="en" dir="ltr" suppressHydrationWarning>
      <Head>
        <meta
          name="theme-color"
          media="(prefers-color-scheme: light)"
          content="#ffffff"
        />
        <meta
          name="theme-color"
          media="(prefers-color-scheme: dark)"
          content="#0c0b0a"
        />
      </Head>
      <body className="min-h-dvh bg-mesh-subtle">
        <ThemeProvider>{children}</ThemeProvider>
      </body>
    </html>
  );
}
