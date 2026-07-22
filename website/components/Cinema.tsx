"use client";

import Image from "next/image";
import { useEffect, useRef, type ReactNode } from "react";

/**
 * A full-bleed cinematic photo band — the luxury-endurance moment. The photograph is graded
 * monochrome in CSS (the brand is ink and paper; iridescence stays an earned accent), shaded
 * for legibility, and drifts slowly on scroll (transform-only parallax, ~60fps, no layout).
 * Reduce-motion leaves the image still. Children render as light-on-dark editorial content.
 */
export default function Cinema({
  src,
  blur,
  alt,
  children,
  tall = false,
  anchor = "center",
}: {
  src: string;
  blur?: string;
  alt: string;
  children: ReactNode;
  tall?: boolean;
  anchor?: "center" | "bottom";
}) {
  const shell = useRef<HTMLDivElement>(null);
  const img = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce) return;
    let raf = 0;
    const tick = () => {
      raf = 0;
      const el = shell.current, im = img.current;
      if (!el || !im) return;
      const r = el.getBoundingClientRect();
      const vh = window.innerHeight;
      // Progress of the band through the viewport: -1 (below) → 1 (above).
      const p = Math.max(-1, Math.min(1, (r.top + r.height / 2 - vh / 2) / (vh / 2 + r.height / 2)));
      im.style.transform = `translate3d(0, ${(-p * 6).toFixed(2)}%, 0) scale(1.14)`;
    };
    const onScroll = () => { if (!raf) raf = requestAnimationFrame(tick); };
    tick();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll, { passive: true });
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, []);

  return (
    <section ref={shell} className={`cinema${tall ? " cinema-tall" : ""}`}>
      <div ref={img} className="cinema-img" aria-hidden>
        <Image
          src={src}
          alt={alt}
          fill
          sizes="100vw"
          quality={82}
          placeholder={blur ? "blur" : undefined}
          blurDataURL={blur}
          style={{ objectFit: "cover", objectPosition: anchor === "bottom" ? "center 78%" : "center" }}
        />
      </div>
      <div className="cinema-shade" aria-hidden />
      <div className="wrap cinema-content">{children}</div>
    </section>
  );
}
