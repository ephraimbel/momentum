import Image from "next/image";

/// A realistic CSS Apple Watch around a real watchOS capture — brushed-metal case with edge
/// highlights, a curved edge-to-edge black-glass front, a knurled Digital Crown + side button, and
/// a glass reflection. Pairs with the iPhone in the hero (Runna-style two-device story).
export default function WatchFrame({ src, alt }: { src: string; alt: string }) {
  return (
    <div className="watch">
      <span className="watch-crown" aria-hidden />
      <span className="watch-btn" aria-hidden />
      <div className="watch-body">
        <div className="watch-glass">
          <div className="watch-screen">
            <Image src={src} alt={alt} width={416} height={496} />
          </div>
        </div>
        <span className="watch-shine" aria-hidden />
      </div>
    </div>
  );
}
