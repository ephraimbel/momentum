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

export const metadata: Metadata = {
  title: "momentum — the running coach that adapts to you",
  description:
    "Adaptive training plans, live guided runs, and honest coaching intelligence. From your first 5K to your first ultra. keep moving.",
  icons: { icon: "/brandicon.png", apple: "/icon-1024.png" },
  openGraph: {
    title: "momentum — keep moving",
    description:
      "The adaptive running coach: deterministic training science, live guidance, and a plan that bends around your life.",
    type: "website",
  },
};

export const viewport: Viewport = {
  themeColor: "#ffffff",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${spaceGrotesk.variable} ${inter.variable}`}>
      <body>{children}</body>
    </html>
  );
}
