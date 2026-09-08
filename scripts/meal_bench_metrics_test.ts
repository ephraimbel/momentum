import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { parseTruth, summarize, total } from "./meal_bench_metrics.ts";

Deno.test("unknown micros do not become zero or partial meal totals", () => {
  assertEquals(total([{ iron_mg: 1 }, { iron_mg: null }], "iron_mg"), null);
  assertEquals(total([{ iron_mg: 0 }, { iron_mg: 0 }], "iron_mg"), 0);
  assertEquals(total([{ kcal: 10 }, {}], "kcal"), null);
});
Deno.test("no responses and a single success cannot claim repeatability", () => {
  assertEquals(summarize([]).nutrients.kcal.cvPct, null);
  const r = summarize([{ status: 503 }, { status: 200, items: [{ kcal: 100 }] }]);
  assertEquals(r.nutrients.kcal.cvPct, null);
  assertEquals(r.successful, 1);
  assertEquals(r.failedOrRejected, 1);
});
Deno.test("consistent but wrong is reported separately from accuracy", () => {
  const r = summarize([{ status: 200, items: [{ kcal: 200 }] }, { status: 200, items: [{ kcal: 200 }] }],
    { source: "weighed recipe", nutrients: { kcal: 100 } });
  assertEquals(r.nutrients.kcal.cvPct, 0);
  assertEquals(r.nutrients.kcal.meanAbsolutePercentError, 100);
});
Deno.test("opposite errors cannot cancel each other in the accuracy report", () => {
  const r = summarize([{ status: 200, items: [{ kcal: 80 }] }, { status: 200, items: [{ kcal: 120 }] }],
    { source: "label", nutrients: { kcal: 100 } });
  assertEquals(r.nutrients.kcal.mean, 100);
  assertEquals(r.nutrients.kcal.meanAbsoluteError, 20);
});
Deno.test("known zero reference uses absolute error and missing data stays missing", () => {
  const r = summarize([{ status: 200, items: [{ sodium_mg: 5 }] }],
    { source: "label", nutrients: { sodium_mg: 0, iron_mg: 1 } });
  assertEquals(r.nutrients.sodium_mg.meanAbsoluteError, 5);
  assertEquals(r.nutrients.sodium_mg.meanAbsolutePercentError, null);
  assertEquals(r.nutrients.iron_mg.meanAbsoluteError, null);
  assertEquals(r.nutrients.iron_mg.missing, 1);
});
Deno.test("non-food references require an actual successful rejection", () => {
  const r = summarize([{ status: 503, reason: "not_food", items: [] }, { status: 200, reason: "not_food", items: [] }],
    { source: "human review", reason: "not_food" });
  assertEquals(r.expectedRejectionMatches, 1);
});
Deno.test("references require provenance, known units and finite nonnegative values", () => {
  assertThrows(() => parseTruth({ photo: { nutrients: { kcal: 100 } } }));
  assertThrows(() => parseTruth({ photo: { source: "label", nutrients: { iron_g: 2 } } }));
  assertThrows(() => parseTruth({ photo: { source: "label", nutrients: { kcal: null } } }));
  assertEquals(parseTruth({ photo: { source: "label", nutrients: { kcal: 100 } } }).photo.nutrients?.kcal, 100);
});
