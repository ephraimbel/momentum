import Image from "next/image";
import { shotBlur } from "./blur";

/// A realistic CSS iPhone around a real simulator capture (1206×2622) — titanium band, black
/// bezel, dynamic island, side buttons, and a soft screen gloss. No mockup tooling, so the site
/// always shows the product exactly as it renders.
export default function PhoneFrame({
  src,
  alt,
  small = false,
  priority = false,
}: {
  src: string;
  alt: string;
  small?: boolean;
  priority?: boolean;
}) {
  // A tiny blurred placeholder (keyed by filename) paints instead of the black screen while the
  // full screenshot decodes — so a large hero image never flashes black on first load.
  const blur = shotBlur[src.split("/").pop() ?? ""];
  return (
    <div className={`phone${small ? " phone-sm" : ""}`}>
      <span className="phone-btn pb-action" aria-hidden />
      <span className="phone-btn pb-volup" aria-hidden />
      <span className="phone-btn pb-voldn" aria-hidden />
      <span className="phone-btn pb-power" aria-hidden />
      <div className="phone-body">
        <div className="phone-screen">
          <Image
            src={src}
            alt={alt}
            width={1206}
            height={2622}
            priority={priority}
            {...(blur ? ({ placeholder: "blur", blurDataURL: blur } as const) : {})}
          />
          <span className="phone-island" aria-hidden />
          <span className="phone-gloss" aria-hidden />
        </div>
      </div>
    </div>
  );
}
