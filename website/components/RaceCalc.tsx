"use client";

import { useState } from "react";

/// Interactive race-time predictor — the same Riegel endurance model (T₂ = T₁·(D₂/D₁)^1.06) the
/// app's RacePredictor engine uses. Runs entirely in the browser; an honest taste of the product's
/// deterministic engine rather than a marketing gimmick.
const DISTANCES = [
  { key: "5k", label: "5K", meters: 5000 },
  { key: "10k", label: "10K", meters: 10000 },
  { key: "half", label: "Half", meters: 21097.5 },
  { key: "marathon", label: "Marathon", meters: 42195 },
] as const;

const EXPONENT = 1.06;

function fmt(totalS: number): string {
  const h = Math.floor(totalS / 3600);
  const m = Math.floor((totalS % 3600) / 60);
  const s = Math.round(totalS % 60);
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

export default function RaceCalc() {
  const [distKey, setDistKey] = useState<(typeof DISTANCES)[number]["key"]>("5k");
  const [mm, setMm] = useState("25");
  const [ss, setSs] = useState("00");
  const [hh, setHh] = useState("0");

  const from = DISTANCES.find((d) => d.key === distKey)!;
  const t1 = Number(hh) * 3600 + Number(mm) * 60 + Number(ss);
  const valid = Number.isFinite(t1) && t1 >= 10 * 60 && t1 <= 10 * 3600;

  return (
    <div className="calc">
      <div className="calc-inputs">
        <div className="calc-field">
          <label htmlFor="calc-dist">Recent race</label>
          <div className="calc-chips" role="radiogroup" aria-label="Race distance" id="calc-dist">
            {DISTANCES.map((d) => (
              <button
                key={d.key}
                type="button"
                role="radio"
                aria-checked={d.key === distKey}
                className={`calc-chip${d.key === distKey ? " on" : ""}`}
                onClick={() => setDistKey(d.key)}
              >
                {d.label}
              </button>
            ))}
          </div>
        </div>
        <div className="calc-field">
          <label htmlFor="calc-h">Finish time</label>
          <div className="calc-time">
            <input id="calc-h" inputMode="numeric" value={hh} onChange={(e) => setHh(e.target.value)} aria-label="Hours" />
            <span>:</span>
            <input inputMode="numeric" value={mm} onChange={(e) => setMm(e.target.value)} aria-label="Minutes" />
            <span>:</span>
            <input inputMode="numeric" value={ss} onChange={(e) => setSs(e.target.value)} aria-label="Seconds" />
          </div>
        </div>
      </div>

      <div className="calc-results" aria-live="polite">
        {DISTANCES.filter((d) => d.key !== distKey).map((d) => {
          const t2 = valid ? t1 * Math.pow(d.meters / from.meters, EXPONENT) : null;
          return (
            <div className="calc-cell" key={d.key}>
              <p>{d.label}</p>
              <div className="num">{t2 ? fmt(t2) : "—"}</div>
            </div>
          );
        })}
      </div>
      <p className="calc-note">
        Riegel endurance model — the same math the app&apos;s race predictor runs. Flat-course,
        even-pacing estimate; momentum builds the plan that gets you there.
      </p>
    </div>
  );
}
