"use client";

import Image from "next/image";
import { useEffect, useState } from "react";

/// The top nav sits transparent over the hero's iridescent wash (no dividing line — it reads as one
/// surface). Once the page scrolls past the hero it fades in a frosted-white backdrop + hairline so
/// the links stay legible over the white content below.
export default function Nav() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 24);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header className={`nav${scrolled ? " scrolled" : ""}`}>
      <div className="wrap nav-inner">
        <a href="#top" aria-label="momentum home">
          <Image className="wordmark" src="/wordmark-black.png" alt="momentum" width={640} height={128} priority />
        </a>
        <nav className="nav-links" aria-label="Primary">
          <a href="#product">Product</a>
          <a href="#intelligence">Intelligence</a>
          <a href="#method">Method</a>
          <a href="#pricing">Pricing</a>
          <a href="#faq">FAQ</a>
          <a className="btn btn-ink btn-sm" href="#download">
            Get the app
          </a>
        </nav>
      </div>
    </header>
  );
}
