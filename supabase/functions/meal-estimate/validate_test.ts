import { assertEquals } from "jsr:@std/assert@1";
import { base64DecodedLength, MAX_IMAGE_BYTES, parseRequest, validateEstimate } from "./validate.ts";

const item = (over: Record<string, unknown> = {}) => ({
  name: "Banana", qty: 1, unit: "banana", kcal: 105, carbs_g: 27, protein_g: 1, fat_g: 0, sodium_mg: 1, fluids_ml: 0,
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
    assertEquals(r.value.tags, ["carb-dense"]);
    assertEquals(r.value.reason, "");
  }
});

Deno.test("a not-food answer is honoured with no items and zero confidence", () => {
  const r = validateEstimate({ items: [item()], confidence: 0.9, tags: [], note: "A desk.", reason: "not_food" });
  assertEquals(r.ok, true);
  if (r.ok) {
    assertEquals(r.value.items.length, 0);
    assertEquals(r.value.confidence, 0);
    assertEquals(r.value.reason, "not_food");
  }
});

Deno.test("a single malformed item refuses the whole response", () => {
  assertEquals(validateEstimate({ items: [item(), item({ kcal: -5 })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ carbs_g: Number.POSITIVE_INFINITY })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ name: "" })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ qty: 0 })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
  assertEquals(validateEstimate({ items: [item({ potassium_mg: "lots" })], confidence: 0.5, tags: [], note: "" }), { ok: false, error: "item" });
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
