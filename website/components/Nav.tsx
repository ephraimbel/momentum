"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { APP_STORE_URL } from "./appStore";

/// Floating nav (Lavender Glass web, 2026-08-19): the glass-runner chip + lowercase wordmark on
/// the left, four quiet links, one black pill. Transparent over the white hero; frosts in with a
/// hairline once the page scrolls.
const LINKS: [string, string][] = [
  ["#product", "Product"],
  ["#method", "Method"],
  ["#pricing", "Pricing"],
  ["#faq", "FAQ"],
];

export default function Nav() {
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  // Close the menu on Escape.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  return (
    <header className={`nav${open ? " open" : ""}${scrolled ? " scrolled" : ""}`}>
      <div className="wrap nav-inner">
        <a className="brand" href="#top" aria-label="momentum home" onClick={() => setOpen(false)}>
          <span className="brand-chip">
            <Image src="/brandicon.png" alt="" width={52} height={52} priority />
          </span>
          <Image
            className="wordmark"
            src="/wordmark-black.png"
            alt="momentum"
            width={640}
            height={128}
            priority
          />
        </a>
        <div className="nav-right">
          <nav className="nav-links" aria-label="Primary">
            {LINKS.map(([href, label]) => (
              <a key={href} href={href}>
                {label}
              </a>
            ))}
            <a className="btn btn-ink btn-sm" href={APP_STORE_URL} target="_blank" rel="noopener">
              Get the app <span className="arrow" aria-hidden>↗</span>
            </a>
          </nav>
          <button
            className="nav-burger"
            aria-label={open ? "Close menu" : "Open menu"}
            aria-expanded={open}
            onClick={() => setOpen((v) => !v)}
          >
            <span aria-hidden />
            <span aria-hidden />
            <span aria-hidden />
          </button>
        </div>
      </div>
      <nav className="nav-menu" aria-label="Mobile" aria-hidden={!open}>
        {LINKS.map(([href, label]) => (
          <a key={href} href={href} onClick={() => setOpen(false)}>
            {label}
          </a>
        ))}
      </nav>
    </header>
  );
}
