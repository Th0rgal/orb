import type { ReactNode } from "react";
import { Layout, Navbar } from "nextra-theme-docs";
import { getPageMap } from "nextra/page-map";
import "nextra-theme-docs/style.css";
import "./docs.css";

function Logo() {
  return (
    <div className="orb-nav-brand">
      <img
        src="/images/orb-icon.png"
        alt="Orb"
        width={22}
        height={22}
        className="orb-nav-logo-img"
      />
      <span className="orb-nav-title">
        Orb <span className="orb-nav-subtitle">· sandboxed.sh</span>
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
