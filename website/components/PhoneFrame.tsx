import Image from "next/image";

/// A CSS device frame around a real app screenshot (1206×2622 sim captures) — no mockup tooling,
/// so the site always shows the product as it actually renders.
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
      <div className="phone-screen">
        <Image src={src} alt={alt} width={1206} height={2622} priority={priority} />
      </div>
    </div>
  );
}
