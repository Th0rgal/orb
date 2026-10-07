import { useMDXComponents as getDocsMDXComponents } from "nextra-theme-docs";
import type { ReactNode } from "react";
import { OrbHero } from "./components/OrbHero";
import { ArchitectureDiagram, IosShowcase, DesktopShowcase } from "./components/DocVisuals";

const docsComponents = getDocsMDXComponents();

function FeatureCard({
  title,
  children,
  icon,
}: {
  title: string;
  children: ReactNode;
  icon?: string;
}) {
  return (
    <div className="orb-feature-card">
      <div className="orb-feature-card-head">
        {icon && <span className="orb-feature-card-icon">{icon}</span>}
        <h4>{title}</h4>
      </div>
      <div className="orb-feature-card-body">{children}</div>
    </div>
  );
}

function Badge({
  children,
  variant = "default",
}: {
  children: ReactNode;
  variant?: "default" | "success" | "warning" | "error";
}) {
  return <span className={`orb-badge orb-badge-${variant}`}>{children}</span>;
}

export const useMDXComponents = (components?: Record<string, unknown>) => ({
  ...docsComponents,
  FeatureCard,
  Badge,
  OrbHero,
  ArchitectureDiagram,
  IosShowcase,
  DesktopShowcase,
  ...(components || {}),
});
