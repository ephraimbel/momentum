"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";

const CONSENT_KEY = "momentum_openai_ads_measurement";

type MeasurementConsent = "granted" | "denied" | null;

declare global {
  interface Window {
    oaiq?: (...args: unknown[]) => void;
    __momentumOaiLastAppStoreClick?: { at: number; eventId: string };
  }
}

/**
 * Keeps ad measurement narrow and explicit: the Pixel receives an event only when a visitor who
 * opted in follows one of the site's App Store links. No app, account, health, or workout data is
 * available to this component.
 */
export default function OpenAIAdsMeasurement() {
  const [consent, setConsent] = useState<MeasurementConsent>(null);
  const [chooserOpen, setChooserOpen] = useState(false);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const stored = window.localStorage.getItem(CONSENT_KEY);
    if (stored === "granted" || stored === "denied") {
      setConsent(stored);
      window.oaiq?.("consent", stored === "granted");
    } else {
      setChooserOpen(true);
    }
    setReady(true);
  }, []);

  useEffect(() => {
    const measureAppStoreClick = (event: MouseEvent) => {
      if (consent !== "granted" || !(event.target instanceof Element)) return;

      const link = event.target.closest<HTMLAnchorElement>("a[href]");
      if (!link) return;

      const destination = new URL(link.href, window.location.href);
      if (destination.hostname !== "apps.apple.com") return;

      const now = Date.now();
      const previous = window.__momentumOaiLastAppStoreClick;
      if (previous && now - previous.at < 2_000) return;

      const eventId = `web_app_store_${crypto.randomUUID()}`;
      window.__momentumOaiLastAppStoreClick = { at: now, eventId };

      window.oaiq?.(
        "measure",
        "custom",
        { type: "custom" },
        { custom_event_name: "app_store_clicked", event_id: eventId },
      );
    };

    document.addEventListener("click", measureAppStoreClick, true);
    return () => document.removeEventListener("click", measureAppStoreClick, true);
  }, [consent]);

  const choose = useCallback((next: Exclude<MeasurementConsent, null>) => {
    window.localStorage.setItem(CONSENT_KEY, next);
    window.oaiq?.("consent", next === "granted");
    setConsent(next);
    setChooserOpen(false);
  }, []);

  if (!ready) return null;

  if (!chooserOpen) {
    return (
      <button className="ads-consent-manage" type="button" onClick={() => setChooserOpen(true)}>
        Ad choices
      </button>
    );
  }

  return (
    <aside className="ads-consent" aria-label="Advertising measurement choices">
      <p>
        Help us understand whether ads lead to App Store visits. This uses one measurement cookie
        and never includes health, workout, or account data. <Link href="/privacy">Learn more</Link>
      </p>
      <div className="ads-consent-actions">
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => choose("denied")}>
          No thanks
        </button>
        <button type="button" className="btn btn-ink btn-sm" onClick={() => choose("granted")}>
          Allow
        </button>
      </div>
    </aside>
  );
}
