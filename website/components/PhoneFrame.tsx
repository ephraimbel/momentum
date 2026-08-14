import Image from "next/image";
import { shotBlur } from "./blur";

/// A realistic CSS iPhone around a real simulator capture — titanium band, black bezel, dynamic
/// island, side buttons, and a soft screen gloss. No mockup tooling, so the site always shows the
/// product exactly as it renders.
///
/// The captures in public/shots are 820×1782 (simulator grabs downsampled by `sips`), NOT the
/// 1206×2622 native size this used to declare. Declaring the native size made next/image build a
/// srcset topping out at 3840 and point `src` at the 3840 variant — a 4.7× upscale request against
/// an 820px file — with no `sizes` hint to talk it down. The optimizer capped the output at the
/// source width so the bytes were always correct, but the browser was made to wait on the most
/// expensive variant for a screen that renders ~300 CSS px wide. Until it landed you saw the blur
/// placeholder, which for these dark-mode captures is a black rectangle — i.e. an empty phone.
const SHOT_W = 820;
const SHOT_H = 1782;

/// Every phone renders ~250–310 CSS px on desktop and never more than ~70vw stacked on mobile.
/// This keeps the browser on a ~750px variant instead of the 1920/3840 ones.
const SHOT_SIZES = "(max-width: 760px) 70vw, 380px";
export default function PhoneFrame({
  src,
  alt,
  small = false,
  large = false,
  priority = false,
}: {
  src: string;
  alt: string;
  small?: boolean;
  /** The hero's dominant device — one per page (see the brief's "avoid 4–5 devices at once"). */
  large?: boolean;
  priority?: boolean;
}) {
  // A tiny blurred placeholder (keyed by filename) paints instead of the black screen while the
  // full screenshot decodes — so a large hero image never flashes black on first load.
  const blur = shotBlur[src.split("/").pop() ?? ""];
  return (
    <div className={`phone${small ? " phone-sm" : ""}${large ? " phone-lg" : ""}`}>
      <span className="phone-btn pb-action" aria-hidden />
      <span className="phone-btn pb-volup" aria-hidden />
      <span className="phone-btn pb-voldn" aria-hidden />
      <span className="phone-btn pb-power" aria-hidden />
      <div className="phone-body">
        <div className="phone-screen">
          <Image
            src={src}
            alt={alt}
            width={SHOT_W}
            height={SHOT_H}
            sizes={SHOT_SIZES}
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
