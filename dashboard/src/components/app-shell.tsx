'use client';

import { useEffect, useState } from 'react';
import { usePathname } from 'next/navigation';
import { List } from '@phosphor-icons/react';
import { Sidebar } from '@/components/sidebar';
import { BrainLogo } from '@/components/icons';

/**
 * Authenticated app shell. On desktop (lg+) it renders exactly the original
 * layout: a fixed sidebar plus a left-margined <main>. Below lg the sidebar
 * collapses into an off-canvas drawer toggled from a mobile top bar, so the
 * 224px sidebar no longer permanently eats the viewport on phones.
 *
 * Mobile top bar height is `h-12` (3rem) — see `MOBILE_TOP_BAR_HEIGHT` in
 * `@/lib/responsive-layout`.
 */
export function AppShell({ children }: { children: React.ReactNode }) {
  const [navOpen, setNavOpen] = useState(false);
  const pathname = usePathname();
  const [lastPathname, setLastPathname] = useState(pathname);

  const closeNav = () => setNavOpen(false);

  // Close the drawer whenever the route changes so navigating from it doesn't
  // leave the overlay covering the destination page. Adjusting state during
  // render (rather than in an effect) avoids an extra commit and satisfies the
  // react-hooks/set-state-in-effect rule.
  if (pathname !== lastPathname) {
    setLastPathname(pathname);
    setNavOpen(false);
  }

  // Prevent the page behind the drawer from scrolling (especially on iOS).
  useEffect(() => {
    if (!navOpen) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, [navOpen]);

  // Close the drawer on Escape from anywhere in the app.
  useEffect(() => {
    if (!navOpen) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        closeNav();
      }
    };
    document.addEventListener('keydown', onKeyDown);
    return () => document.removeEventListener('keydown', onKeyDown);
  }, [navOpen]);

  return (
    <>
      {/* Mobile top bar — never rendered at lg+, so desktop is untouched. */}
      <div className="lg:hidden sticky top-0 z-30 flex h-12 items-center gap-3 border-b border-white/[0.06] glass-panel px-4">
        <button
          type="button"
          onClick={() => setNavOpen(true)}
          aria-label="Open navigation"
          aria-expanded={navOpen}
          aria-controls="app-sidebar"
          className="flex h-8 w-8 items-center justify-center rounded-lg text-white/70 transition-colors hover:bg-white/[0.06] hover:text-white"
        >
          <List className="h-5 w-5" />
        </button>
        <BrainLogo size={24} />
        <span className="text-sm font-medium text-white">Core</span>
      </div>

      {/* Backdrop behind the open drawer (mobile only). */}
      {navOpen && (
        <div
          className="lg:hidden fixed inset-0 z-30 bg-black/50 backdrop-blur-sm"
          onClick={closeNav}
          aria-hidden="true"
        />
      )}

      <Sidebar id="app-sidebar" open={navOpen} onClose={closeNav} />

      <main className="lg:ml-56 min-h-[calc(100vh-3rem)] lg:min-h-screen">
        {children}
      </main>
    </>
  );
}
