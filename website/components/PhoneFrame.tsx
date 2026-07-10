import Image from "next/image";

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
  return (
    <div className={`phone${small ? " phone-sm" : ""}`}>
      <span className="phone-btn pb-action" aria-hidden />
      <span className="phone-btn pb-volup" aria-hidden />
      <span className="phone-btn pb-voldn" aria-hidden />
      <span className="phone-btn pb-power" aria-hidden />
      <div className="phone-body">
        <div className="phone-screen">
          <Image src={src} alt={alt} width={1206} height={2622} priority={priority} />
          <span className="phone-island" aria-hidden />
          <span className="phone-gloss" aria-hidden />
        </div>
      </div>
    </div>
  );
}
