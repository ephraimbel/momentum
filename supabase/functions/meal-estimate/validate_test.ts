import { assertEquals } from "jsr:@std/assert@1";
import {
  base64DecodedLength, KCAL_TOLERANCE, macroEnergy, MAX_IMAGE_BYTES, parseRequest, reconcileEnergy, snapGrams, snapKcal,
  validateEstimate, type Item,
} from "./validate.ts";

const item = (over: Record<string, unknown> = {}) => ({
  name: "Banana", qty: 1, unit: "banana", grams: 118, kcal: 105, carbs_g: 27, protein_g: 1, fat_g: 0, alcohol_g: 0,
  sodium_mg: 1, fluids_ml: 0,
  potassium_mg: 422, magnesium_mg: 32, iron_mg: 0.3, calcium_mg: 6, fiber_g: 3, sugar_g: 14, satfat_g: 0, nova: 1,
  ...over,
});

Deno.test("text-only requests keep working exactly as before", () => {
  const r = parseRequest({ text: "2 eggs and toast", context: { session: "tomorrow's long run" } });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.text, "2 eggs and toast");
    assertEquals(r.value.image, null);
    assertEquals(r.value.context.session, "tomorrow's long run");
  }
});

Deno.test("an empty request with no photo is refused", () => {
  const r = parseRequest({ text: "   " });
  assertEquals(r, { ok: false, error: "empty" });
});

Deno.test("a photo alone is a valid request and its type and size are checked before anything else", () => {
  const png = btoa("\x89PNG\r\n\x1a\n" + "x".repeat(64));
  const ok = parseRequest({ image: { mime: "image/png", base64: png } });
  assertEquals(ok.ok, true);
  assertEquals(parseRequest({ image: { mime: "image/gif", base64: png } }), { ok: false, error: "image_type" });
  assertEquals(parseRequest({ image: { mime: "image/jpeg", base64: "not base64!!" } }), { ok: false, error: "image_encoding" });
  const tooBig = "A".repeat(Math.ceil((MAX_IMAGE_BYTES + 100) * 4 / 3 / 4) * 4);
  assertEquals(parseRequest({ image: { mime: "image/jpeg", base64: tooBig } }), { ok: false, error: "image_size" });
});

Deno.test("the declared type never outranks the bytes", () => {
  const jpegBytes = btoa("\xff\xd8\xff\xe0" + "x".repeat(64));
  const r = parseRequest({ image: { mime: "image/png", base64: jpegBytes } });
  assertEquals(r.ok, true);
  if (r.ok) assertEquals(r.value.image?.mime, "image/jpeg");
  const notAnImage = btoa("GIF89a" + "x".repeat(64));
  assertEquals(parseRequest({ image: { mime: "image/jpeg", base64: notAnImage } }), { ok: false, error: "image_type" });
});

Deno.test("base64 length arithmetic matches the decoded byte count", () => {
  for (const s of ["a", "ab", "abc", "abcd", "abcde", "hello world", "\x00\xff\x10"]) {
    assertEquals(base64DecodedLength(btoa(s)), s.length);
  }
});

Deno.test("a well-formed estimate passes with unknown micros kept as null", () => {
  const r = validateEstimate({
    items: [item({ potassium_mg: null, iron_mg: null })],
    confidence: 0.7, tags: ["carb-dense", "bogus"], note: "Good carbs.", reason: "",
  });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items[0].potassium_mg, null);
    assertEquals(r.value.items[0].iron_mg, null);
    assertEquals(r.value.items[0].kcal, 105);
    assertEquals(r.value.items[0].grams, 120);   // snapped to the hand's step
    assertEquals(r.value.tags, ["carb-dense"]);
    assertEquals(r.value.reason, "");
    assertEquals(r.stats.reconciled, 0);
  }
});

Deno.test("the deployed text-only item shape (no grams, no alcohol) still validates", () => {
  const legacy = item();
  delete (legacy as Record<string, unknown>).grams;
  delete (legacy as Record<string, unknown>).alcohol_g;
  const r = validateEstimate({ items: [legacy], confidence: 0.6, tags: [], note: "" });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items[0].grams, null);
    assertEquals(r.value.items[0].alcohol_g, null);
    assertEquals(r.value.items[0].kcal, 105);
  }
});

Deno.test("a not-food answer is honoured with no items and zero confidence, for a photo only", () => {
  const r = validateEstimate({ items: [item()], confidence: 0.9, tags: [], note: "A desk.", reason: "not_food" }, { hasImage: true });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items.length, 0);
    assertEquals(r.value.confidence, 0);
    assertEquals(r.value.reason, "not_food");
  }
  // Text is never "not food": the same answer for a sentence is just an estimate.
  const text = validateEstimate({ items: [item()], confidence: 0.9, tags: [], note: "", reason: "not_food" });
  assertEquals(text.ok, true);
  if (text.ok) assertEquals(text.value.items.length, 1);
  // An unfamiliar reason on a photo reads as unreadable, never as a meal.
  const odd = validateEstimate({ items: [], confidence: 0.2, tags: [], note: "", reason: "blurry_plate" }, { hasImage: true });
  assertEquals(odd.ok, true);
  if (odd.ok) assertEquals(odd.value.reason, "unreadable");
});

Deno.test("a single malformed item refuses the whole response", () => {
  assertEquals(validateEstimate({ items: [item(), item({ kcal: -5 })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ carbs_g: Number.POSITIVE_INFINITY })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ name: "" })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ qty: 0 })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ potassium_mg: "lots" })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ grams: -10 })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
});

Deno.test("item counts and confidence are bounded", () => {
  assertEquals(validateEstimate({ items: [], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "items" });
  assertEquals(validateEstimate({ items: Array.from({ length: 41 }, () => item()), confidence: 0.5, tags: [], note: "" }), { ok: false, error: "items" });
  assertEquals(validateEstimate({ items: [item()], confidence: 1.5, tags: [], note: "" }), { ok: false, error: "confidence" });
  assertEquals(validateEstimate("nope"), { ok: false, error: "shape" });
});

Deno.test("a wild NOVA class is clamped, a missing one stays unknown", () => {
  const r = validateEstimate({ items: [item({ nova: 9 }), item({ nova: null })], confidence: 0.5, tags: [], note: "" });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items[0].nova, 4);
    assertEquals(r.value.items[1].nova, null);
  }
});

Deno.test("the parts never exceed the whole", () => {
  const r = validateEstimate({ items: [item({ carbs_g: 20, sugar_g: 25, fiber_g: 30, fat_g: 2, satfat_g: 5 })], confidence: 0.5, tags: [], note: "" });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items[0].sugar_g, 20);
    assertEquals(r.value.items[0].fiber_g, 20);
    assertEquals(r.value.items[0].satfat_g, 2);
  }
});

Deno.test("energy is reconciled to the macros when they disagree, in either direction", () => {
  // Rice that the model called 100 kcal with 45 g of carbs is 190 kcal; alcohol counts.
  const low = validateEstimate({ items: [item({ name: "Rice", kcal: 100, carbs_g: 45, protein_g: 4, fat_g: 1 })], confidence: 0.5, tags: [], note: "" });
  assertEquals(low.ok, true);
  if (low.ok) {
    assertEquals(low.value.items[0].kcal, 205);   // 4*45 + 4*4 + 9*1 = 205
    assertEquals(low.stats.reconciled, 1);
  }
  const high = validateEstimate({ items: [item({ name: "Banana", kcal: 300, carbs_g: 27, protein_g: 1, fat_g: 0 })], confidence: 0.5, tags: [], note: "" });
  assertEquals(high.ok, true);
  if (high.ok) assertEquals(high.value.items[0].kcal, 110);   // 112 snapped to 5
  const beer = validateEstimate({ items: [item({ name: "Beer", kcal: 150, carbs_g: 13, protein_g: 2, fat_g: 0, alcohol_g: 14, fluids_ml: 355 })], confidence: 0.5, tags: [], note: "" });
  assertEquals(beer.ok, true);
  if (beer.ok) {
    assertEquals(beer.value.items[0].kcal, 150);   // 60 + 98 = 158, within the band: untouched
    assertEquals(beer.stats.reconciled, 0);
  }
});

Deno.test("the reconciliation band and floor are exactly what the contract says", () => {
  const base: Item = { ...item(), alcohol_g: null, grams: null } as Item;
  const energy = macroEnergy(base);   // 108 + 4 = 112
  assertEquals(energy, 112);
  const inside = { ...base, kcal: Math.round(energy * (1 + KCAL_TOLERANCE)) - 1 };
  assertEquals(reconcileEnergy(inside), false);
  const outside = { ...base, kcal: Math.round(energy * (1 + KCAL_TOLERANCE)) + 2 };
  assertEquals(reconcileEnergy(outside), true);
  assertEquals(outside.kcal, 112);
  // A tiny item (a lemon wedge, a pinch) is left alone: rounding dominates the identity there.
  const tiny = { ...base, kcal: 30, carbs_g: 2, protein_g: 0, fat_g: 0 };
  assertEquals(reconcileEnergy(tiny), false);
});

Deno.test("kcal and grams snap to the steps a hand would use", () => {
  assertEquals(snapKcal(23), 23);
  assertEquals(snapKcal(52), 50);
  assertEquals(snapKcal(53), 55);
  assertEquals(snapKcal(618), 620);
  assertEquals(snapGrams(23), 25);
  assertEquals(snapGrams(97), 95);
  assertEquals(snapGrams(104), 100);
  assertEquals(snapGrams(158), 160);
  const r = validateEstimate({ items: [item({ grams: 0 })], confidence: 0.55, tags: [], note: "" });
  assertEquals(r.ok, true);
  if (r.ok) assertEquals(r.value.items[0].grams, null);   // a weight of nothing is unknown
});

Deno.test("names and units are tidied and confidence is rounded to two places", () => {
  const r = validateEstimate({ items: [item({ name: "  Grilled   Chicken ", unit: " serving " })], confidence: 0.61234, tags: [], note: "" });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items[0].name, "Grilled Chicken");
    assertEquals(r.value.items[0].unit, "serving");
    assertEquals(r.value.confidence, 0.61);
  }
});

Deno.test("a photo's items are listed largest first; a sentence keeps the athlete's order", () => {
  const plate = { items: [item({ name: "Toast", kcal: 80, carbs_g: 15, protein_g: 3, fat_g: 1 }), item({ name: "Sausage", kcal: 250, carbs_g: 2, protein_g: 12, fat_g: 21 }), item({ name: "Egg", kcal: 80, carbs_g: 0, protein_g: 6, fat_g: 6 })], confidence: 0.6, tags: [], note: "" };
  const photo = validateEstimate(structuredClone(plate), { hasImage: true });
  assertEquals(photo.ok, true);
  if (photo.ok) assertEquals(photo.value.items.map((i) => i.name), ["Sausage", "Egg", "Toast"]);
  const text = validateEstimate(structuredClone(plate));
  assertEquals(text.ok, true);
  if (text.ok) assertEquals(text.value.items.map((i) => i.name), ["Toast", "Sausage", "Egg"]);
});

Deno.test("legible label calories and portion weights are preserved instead of rewritten", () => {
  const result = validateEstimate({ items: [item({ name: "Fibre bar", nutrition_basis: "label",
    grams: 53, kcal: 153, carbs_g: 30, protein_g: 10, fat_g: 5, fiber_g: 15 })], confidence: 0.8 });
  assertEquals(result.ok, true);
  if (result.ok) {
    assertEquals(result.value.items[0].kcal, 153);
    assertEquals(result.value.items[0].grams, 53);
    assertEquals(result.stats.reconciled, 0);
  }
});

Deno.test("fibre energy is a range, not automatically four calories per gram", () => {
  const result = validateEstimate({ items: [item({ name: "Fibre cereal", kcal: 150,
    carbs_g: 45, protein_g: 8, fat_g: 3, fiber_g: 25 })], confidence: 0.6 });
  assertEquals(result.ok, true);
  if (result.ok) {
    assertEquals(result.value.items[0].kcal, 150);
    assertEquals(result.stats.reconciled, 0);
  }
});

Deno.test("impossible nutrient mass rejects the entire response", () => {
  for (const changes of [{ grams: 10, protein_g: 50 }, { grams: 100, iron_mg: 200000 }]) {
    assertEquals(validateEstimate({ items: [item(), item(changes)], confidence: 0.7 }),
      { ok: false, error: "item" });
  }
  // Ordinary rounding on a small portion is tolerated.
  const oil = item({ name: "Oil", grams: 14, kcal: 126, carbs_g: 0, protein_g: 0, fat_g: 14 });
  assertEquals(validateEstimate({ items: [oil], confidence: 0.6 }).ok, true);
});

Deno.test("provider invented nutrition provenance is refused", () => {
  assertEquals(validateEstimate({ items: [item({ nutrition_basis: "laboratory_verified" })], confidence: 0.9 }),
    { ok: false, error: "item" });
});

Deno.test("chunked image requests cannot bypass the body ceiling", async () => {
  const { BodyTooLarge, readBoundedJSON } = await import("./validate.ts");
  let canceled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) { controller.enqueue(new Uint8Array(32)); },
    cancel() { canceled = true; },
  });
  let tooLarge = false;
  try { await readBoundedJSON(new Request("https://example.com", { method: "POST", body }), 64); }
  catch (error) { tooLarge = error instanceof BodyTooLarge; }
  assertEquals(tooLarge, true);
  assertEquals(canceled, true);
});

Deno.test("bounded JSON decodes UTF-8 split across network chunks", async () => {
  const { readBoundedJSON } = await import("./validate.ts");
  const bytes = new TextEncoder().encode(JSON.stringify({ text: "café" }));
  const body = new ReadableStream<Uint8Array>({ start(controller) {
    for (const byte of bytes) controller.enqueue(Uint8Array.of(byte));
    controller.close();
  } });
  const result = await readBoundedJSON(new Request("https://example.com", { method: "POST", body }), bytes.length);
  assertEquals(result, { text: "café" });
});
