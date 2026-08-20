"use client";

import { useEffect, useRef } from "react";

/// The scroll statement: a big two-tone paragraph whose words ink in from warm gray to
/// near-black as the reader scrolls it through the viewport. Transform-free (color only),
/// rAF-throttled, and inert under reduced motion (every word starts inked).
export default function InkReveal({ text }: { text: string }) {
  const ref = useRef<HTMLParagraphElement>(null);
  const words = text.split(" ");

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const spans = Array.from(el.querySelectorAll<HTMLSpanElement>(".w"));

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      spans.forEach((s) => s.classList.add("on"));
      return;
    }

    let raf = 0;
    const update = () => {
      raf = 0;
      const rect = el.getBoundingClientRect();
      // 0 when the paragraph's top reaches ~85% of the viewport, 1 by ~35% — the words finish
      // inking while the statement is still comfortably on screen.
      const start = window.innerHeight * 0.85;
      const end = window.innerHeight * 0.35;
      const p = Math.min(1, Math.max(0, (start - rect.top) / (start - end)));
      const lit = Math.round(p * spans.length);
      spans.forEach((s, i) => s.classList.toggle("on", i < lit));
    };
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };
    update();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, []);

  return (
    <p ref={ref}>
      {words.map((w, i) => (
        <span className="w" key={i}>
          {w}
          {i < words.length - 1 ? " " : ""}
        </span>
      ))}
    </p>
  );
}
