import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import Script from "next/script";
import OpenAIAdsMeasurement from "@/components/OpenAIAdsMeasurement";
import "./globals.css";

// The brief's voice (2026-08-14 rebuild): one excellent neutral grotesk, set tight.
// Inter Tight is Inter's display sibling — narrower forms that hold together at the −0.06em to
// −0.095em tracking the display sizes call for, where standard Inter starts to collide. Variable,
// so the 500/540 headline weights come from one file (headlines are NEVER 800 — brand rule).
const interTight = localFont({
  src: [{ path: "../public/fonts/InterTight-Variable.ttf", weight: "100 900", style: "normal" }],
  variable: "--font-display",
  display: "swap",
});

// Body/UI stays Inter — quiet, neutral, and already the iOS app's own UI face.
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
  // The canonical home (momentumrunning.app, primary since 2026-08-28 — momentumco.app and both
  // www variants 308 here): absolute URLs for OG/Twitter cards and canonicals resolve against
  // this, not the per-deployment *.vercel.app hostname. The @momentumco.app EMAIL addresses below
  // are unchanged — that mailbox is ImprovMX-backed and is what the App Store listing contacts.
  metadataBase: new URL("https://momentumrunning.app"),
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
    url: "https://momentumrunning.app",
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
  themeColor: "#ffffff",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${interTight.variable} ${inter.variable}`}>
      <body>
        <Script id="openai-ads-pixel" strategy="beforeInteractive">
          {`!function(w,d,s,u){if(w.oaiq)return;var q=function(){q.q.push(arguments)};q.q=[];w.oaiq=q;var j=d.createElement(s);j.async=1;j.src=u;var f=d.getElementsByTagName(s)[0];f.parentNode.insertBefore(j,f)}(window,document,"script","https://bzrcdn.openai.com/sdk/oaiq.min.js");
try{oaiq("consent",localStorage.getItem("momentum_openai_ads_measurement")==="granted")}catch(e){oaiq("consent",false)}
oaiq("init",{pixelId:"5rm91AenaY9ndfpPtADUdy",debug:${process.env.NODE_ENV !== "production"}});`}
        </Script>
        {children}
        <OpenAIAdsMeasurement />
      </body>
    </html>
  );
}
