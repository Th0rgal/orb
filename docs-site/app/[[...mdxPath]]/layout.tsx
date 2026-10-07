import type { ReactNode } from "react";
import { Layout, Navbar } from "nextra-theme-docs";
import { getPageMap } from "nextra/page-map";
import "nextra-theme-docs/style.css";
import "./docs.css";

function Logo() {
  return (
    <div style={{ display: "inline-flex", alignItems: "center", gap: 10 }}>
      <span
        style={{
          fontWeight: 600,
          fontSize: 16,
          color: "rgb(var(--foreground))",
        }}
      >
        Orb <span style={{ opacity: 0.6, fontWeight: 400 }}>· sandboxed.sh</span>
      </span>
    </div>
  );
}

export default async function DocsLayout({
  children,
}: {
  children: ReactNode;
}) {
  const navbar = (
    <Navbar
      logo={<Logo />}
      logoLink="/"
      projectLink="https://github.com/Th0rgal/sandboxed.sh"
    />
  );
  const pageMap = await getPageMap("/");
  return (
    <Layout
      navbar={navbar}
      editLink="Edit this page on GitHub"
      docsRepositoryBase="https://github.com/Th0rgal/sandboxed.sh/blob/master/docs-site"
      sidebar={{ defaultMenuCollapseLevel: 1 }}
      pageMap={pageMap}
      footer={null}
    >
      {children}
    </Layout>
  );
}
