"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { APP_STORE_URL } from "./appStore";

const LINKS: [string, string][] = [
  ["#product", "Product"],
  ["#intelligence", "Intelligence"],
  ["#method", "Method"],
  ["#pricing", "Pricing"],
  ["#faq", "FAQ"],
];

/// The top nav sits transparent over the hero's iridescent wash (no dividing line). Once scrolled it
/// frosts white + hairline so the links stay legible. On mobile the inline links collapse into a
/// hamburger menu that drops down from the bar.
export default function Nav() {
  const [scrolled, setScrolled] = useState(false);
  const [open, setOpen] = useState(false);

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
    <header className={`nav${scrolled || open ? " scrolled" : ""}${open ? " open" : ""}`}>
      <div className="wrap nav-inner">
        <a href="#top" aria-label="momentum home" onClick={() => setOpen(false)}>
          <Image className="wordmark" src="/wordmark-black.png" alt="momentum" width={640} height={128} priority />
        </a>
        <div className="nav-right">
          <nav className="nav-links" aria-label="Primary">
            {LINKS.map(([href, label]) => (
              <a key={href} href={href}>
                {label}
              </a>
            ))}
            <a className="btn btn-ink btn-sm" href={APP_STORE_URL} target="_blank" rel="noopener">
              Get the app
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
