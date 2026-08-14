import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";

// The app's two faces, byte-identical to the iOS bundle (both OFL):
// Space Grotesk = display (hero numbers, titles, wordmark), Inter = UI/body.
const spaceGrotesk = localFont({
  src: [
    { path: "../public/fonts/SpaceGrotesk-Regular.ttf", weight: "400" },
    { path: "../public/fonts/SpaceGrotesk-Medium.ttf", weight: "500" },
    { path: "../public/fonts/SpaceGrotesk-Bold.ttf", weight: "700" },
  ],
  variable: "--font-display",
  display: "swap",
});

const inter = localFont({
  src: [
    { path: "../public/fonts/Inter-Regular.ttf", weight: "400" },
    { path: "../public/fonts/Inter-Medium.ttf", weight: "500" },
    { path: "../public/fonts/Inter-SemiBold.ttf", weight: "600" },
    { path: "../public/fonts/Inter-Bold.ttf", weight: "700" },
  ],
  variable: "--font-ui",
  display: "swap",
});

// The editorial voice (2026-08-14 aesthetic pass): Instrument Serif — condensed, high-contrast,
// sharp-serifed display face with lively true italics (OFL). One optical weight, made for exactly
// the print-poster scale headlines this direction calls for. Headlines speak in this; Space
// Grotesk keeps the numbers (the app's data voice) and Inter keeps the UI.
const instrumentSerif = localFont({
  src: [
    { path: "../public/fonts/InstrumentSerif-Regular.ttf", weight: "400", style: "normal" },
    { path: "../public/fonts/InstrumentSerif-Italic.ttf", weight: "400", style: "italic" },
  ],
  variable: "--font-serif",
  display: "swap",
});

export const metadata: Metadata = {
  // The canonical home (momentumco.app, live 2026-07-12): absolute URLs for OG/Twitter cards
  // and canonicals resolve against this, not the per-deployment *.vercel.app hostname.
  metadataBase: new URL("https://momentumco.app"),
  alternates: { canonical: "/" },
  title: "momentum — the running coach that adapts to you",
  description:
    "Adaptive training plans, live guided runs, and honest coaching intelligence. From your first 5K to your first ultra. keep moving.",
  icons: { icon: "/brandicon.png", apple: "/icon-1024.png" },
  openGraph: {
    title: "momentum — keep moving",
    description:
      "The adaptive running coach: deterministic training science, live guidance, and a plan that bends around your life.",
    type: "website",
    url: "https://momentumco.app",
    siteName: "momentum",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
        alt: "momentum — the running coach that adapts to you",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "momentum — keep moving",
    description:
      "The adaptive running coach: deterministic training science, live guidance, and a plan that bends around your life.",
    images: ["/og.png"],
  },
};

export const viewport: Viewport = {
  themeColor: "#faf7f2",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${spaceGrotesk.variable} ${inter.variable} ${instrumentSerif.variable}`}>
      <body>{children}</body>
    </html>
  );
}
