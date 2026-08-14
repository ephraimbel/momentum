"use client";

import Image from "next/image";
import { useEffect, useState } from "react";
import { APP_STORE_URL } from "./appStore";

/// Minimal by design (2026-08-14 rebuild): four destinations, nothing else. The bar is a fixed
/// paper-frosted strip with a single bottom hairline — no scroll state to manage, because the
/// page's first surface is paper too.
const LINKS: [string, string][] = [
  ["#product", "Product"],
  ["#method", "Method"],
  ["#pricing", "Pricing"],
];

export default function Nav() {
  const [open, setOpen] = useState(false);

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
    <header className={`nav${open ? " open" : ""}`}>
      <div className="wrap nav-inner">
        <a href="#top" aria-label="momentum home" onClick={() => setOpen(false)}>
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
              Download <span className="arrow" aria-hidden>↗</span>
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
