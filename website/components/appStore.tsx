/** The one place the App Store product page is spelled — every download CTA routes here.
 *  (Live since 2026-07-24: "Momentum: Run Training Plans", Apple ID 6790830947.) */
export const APP_STORE_URL =
  "https://apps.apple.com/app/momentum-run-training-plans/id6790830947";

/** The official-geometry App Store badge, drawn inline (no external asset, matches the CSP-free
 *  zero-dependency rule). Black badge with the standard #a6a6a6 keyline reads correctly on both
 *  the white hero and the dark closer photo — same as Apple's own guidance. */
export function AppStoreBadge() {
  const text = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";
  return (
    <svg viewBox="0 0 120 40" role="img" aria-label="Download on the App Store" xmlns="http://www.w3.org/2000/svg">
      <rect x="0.5" y="0.5" width="119" height="39" rx="7" fill="#000" stroke="#a6a6a6" />
      <g transform="translate(9.2, 8.2) scale(0.98)" fill="#fff">
        <path
          transform="scale(0.72)"
          d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zm3.378-3.066c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.56-1.702"
        />
      </g>
      <text x="30" y="16.5" fill="#fff" fontFamily={text} fontSize="8.2" letterSpacing="0.02em">
        Download on the
      </text>
      <text x="29.5" y="31.5" fill="#fff" fontFamily={text} fontSize="15.5" fontWeight="600" letterSpacing="-0.02em">
        App Store
      </text>
    </svg>
  );
}
