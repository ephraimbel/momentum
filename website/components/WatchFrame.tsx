import Image from "next/image";

/// A realistic CSS Apple Watch around a real watchOS capture — aluminium case, squircle screen,
/// digital crown + side button. Pairs with the iPhone in the hero (Runna-style two-device story).
export default function WatchFrame({ src, alt }: { src: string; alt: string }) {
  return (
    <div className="watch" aria-hidden={false}>
      <span className="watch-crown" aria-hidden />
      <span className="watch-side" aria-hidden />
      <div className="watch-case">
        <div className="watch-screen">
          <Image src={src} alt={alt} width={416} height={496} />
          <span className="watch-gloss" aria-hidden />
        </div>
      </div>
    </div>
  );
}
