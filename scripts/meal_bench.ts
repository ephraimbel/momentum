#!/usr/bin/env -S deno run --allow-net --allow-read --allow-env --allow-write
// meal_bench.ts — the photo estimator's repeatability and cost bench (2026-09-07).
//
// Sends every photo in a directory to a deployed `meal-estimate` (or a canary copy of it) N times
// and reports, per photo: the item set each run found, kcal / carbs mean and spread, latency and
// token usage. "Consistent" is a number here, not a feeling: the coefficient of variation of kcal
// across identical requests, and how often the item list was byte-identical.
//
//   MEAL_BENCH_URL=https://<ref>.supabase.co/functions/v1/meal-estimate-canary \
//   MEAL_BENCH_TOKEN=<anon key or a user JWT> \
//   deno run --allow-net --allow-read --allow-env --allow-write scripts/meal_bench.ts \
//     --dir /path/to/photos --runs 3 [--text "two of these"] [--only bigmac,banana] [--label baseline]
//
// Writes <dir>/bench-<label>.json with every raw answer so two configurations can be diffed.
// Photos: JPEGs at the app's own size (≤1280 px); the script sends them as the app would.

import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import { parseArgs } from "jsr:@std/cli@1/parse-args";

const args = parseArgs(Deno.args, {
  string: ["dir", "runs", "text", "only", "label", "session", "bench"],
  default: { runs: "3", label: "run", session: "tomorrow's long run" },
});
const URL_ = Deno.env.get("MEAL_BENCH_URL") ?? "";
const TOKEN = Deno.env.get("MEAL_BENCH_TOKEN") ?? "";
if (!URL_ || !TOKEN || !args.dir) {
  console.error("need MEAL_BENCH_URL, MEAL_BENCH_TOKEN and --dir");
  Deno.exit(2);
}
const runs = Math.max(1, Number(args.runs));
const only = args.only ? new Set(args.only.split(",").map((s) => s.trim())) : null;

// Price sheet for the cost column (USD per million tokens), gemini-3.8-flash paid tier as of
// 2026-09 ($0.75 in / $3.75 out; thoughts bill as output). Override for another model, e.g.
// gemini-3.5-flash-lite at 0.30 / 2.50.
const PRICE_IN = Number(Deno.env.get("MEAL_PRICE_IN") ?? "0.75");
const PRICE_OUT = Number(Deno.env.get("MEAL_PRICE_OUT") ?? "3.75");

type Item = { name: string; qty: number; unit: string; grams: number | null; kcal: number; carbs_g: number; protein_g: number; fat_g: number };
type Answer = {
  status: number; ms: number; reason?: string; confidence?: number; items?: Item[]; provider?: string; model?: string;
  usage?: { in?: number; out?: number; thought?: number }; error?: string; note?: string;
};

async function ask(bytes: Uint8Array, text: string): Promise<Answer> {
  const body = JSON.stringify({
    text,
    context: { session: args.session },
    image: { mime: "image/jpeg", base64: encodeBase64(bytes) },
    // A canary with MEAL_DEBUG=1 reads `bench` as per-request knob overrides; production ignores it.
    ...(args.bench ? { bench: JSON.parse(args.bench) } : {}),
  });
  const t0 = performance.now();
  try {
    const res = await fetch(URL_, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
      body,
    });
    const ms = Math.round(performance.now() - t0);
    const data = await res.json().catch(() => ({}));
    return { status: res.status, ms, ...data };
  } catch (e) {
    return { status: 0, ms: Math.round(performance.now() - t0), error: e instanceof Error ? e.message : String(e) };
  }
}

const total = (items: Item[] | undefined, key: keyof Item) => (items ?? []).reduce((s, i) => s + (Number(i[key]) || 0), 0);
const mean = (xs: number[]) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0;
const sd = (xs: number[]) => {
  if (xs.length < 2) return 0;
  const m = mean(xs);
  return Math.sqrt(xs.reduce((s, x) => s + (x - m) ** 2, 0) / (xs.length - 1));
};
const fmt = (n: number, d = 0) => n.toFixed(d);

const entries: { name: string; path: string }[] = [];
for await (const e of Deno.readDir(args.dir)) {
  if (!e.isFile || !/\.jpe?g$/i.test(e.name)) continue;
  const name = e.name.replace(/\.jpe?g$/i, "");
  if (only && !only.has(name)) continue;
  entries.push({ name, path: `${args.dir}/${e.name}` });
}
entries.sort((a, b) => a.name.localeCompare(b.name));

const dump: Record<string, Answer[]> = {};
let costTotal = 0;
console.log(`bench "${args.label}" → ${URL_}\n${entries.length} photos × ${runs} runs, text: ${JSON.stringify(args.text ?? "")}\n`);

for (const { name, path } of entries) {
  const bytes = await Deno.readFile(path);
  const answers: Answer[] = [];
  for (let r = 0; r < runs; r++) answers.push(await ask(bytes, args.text ?? ""));
  dump[name] = answers;

  const ok = answers.filter((a) => a.status === 200 && !a.reason && (a.items?.length ?? 0) > 0);
  const kcals = ok.map((a) => total(a.items, "kcal"));
  const carbs = ok.map((a) => total(a.items, "carbs_g"));
  const lists = answers.map((a) => (a.items ?? []).map((i) => `${i.name}×${i.qty}${i.grams != null ? `@${i.grams}g` : ""}`).join(" · ") || `[${a.reason || (a as { detail?: string }).detail || a.error || a.status}]`);
  const identical = new Set(lists).size === 1;
  const cost = answers.reduce((s, a) => s + ((a.usage?.in ?? 0) * PRICE_IN + ((a.usage?.out ?? 0) + (a.usage?.thought ?? 0)) * PRICE_OUT) / 1e6, 0);
  costTotal += cost;
  const cv = kcals.length > 1 && mean(kcals) > 0 ? sd(kcals) / mean(kcals) * 100 : 0;

  console.log(`■ ${name}  (${(bytes.length / 1024).toFixed(0)} KB)`);
  console.log(`  kcal ${kcals.map((k) => fmt(k)).join(" / ")}  mean ${fmt(mean(kcals))} sd ${fmt(sd(kcals))} cv ${fmt(cv, 1)}%   carbs ${carbs.map((c) => fmt(c)).join(" / ")} g`);
  console.log(`  items ${identical ? "IDENTICAL across runs" : "DIFFER"}; confidence ${ok.map((a) => a.confidence).join("/")}; ms ${answers.map((a) => a.ms).join("/")}; ` +
    `tokens in/out/thought ${answers.map((a) => `${a.usage?.in ?? "?"}/${a.usage?.out ?? "?"}/${a.usage?.thought ?? "?"}`).join(" ")}; cost $${cost.toFixed(4)}; model ${answers[0]?.model ?? "?"}`);
  for (const [i, l] of lists.entries()) console.log(`  ${i + 1}. ${l}`);
  const notes = answers.map((a) => a.note).filter(Boolean);
  if (notes.length) console.log(`  note: ${notes[0]}`);
  console.log();
}
console.log(`total cost $${costTotal.toFixed(4)} for ${entries.length * runs} calls (≈$${(costTotal / Math.max(1, entries.length * runs)).toFixed(4)} per photo)`);
const out = `${args.dir}/bench-${args.label}.json`;
await Deno.writeTextFile(out, JSON.stringify(dump, null, 1));
console.log(`raw answers → ${out}`);
