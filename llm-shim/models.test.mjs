import { test } from "node:test";
import assert from "node:assert/strict";
import { ANTHROPIC_TIERS, engineModelId, modelFor, withAnthropicFields } from "./models.mjs";

// What vLLM answered with on 2026-10-01, trimmed to the fields that matter.
const vllmModels = () => ({
  object: "list",
  data: [
    { id: "local-qwen3.8-27b-mxfp4", object: "model", created: 1790864560, owned_by: "vllm", max_model_len: 262144 },
    { id: "Qwen3.8", object: "model", created: 1790864560, owned_by: "vllm", max_model_len: 262144 },
    { id: "Qwen3.8-MXFP4", object: "model", created: 1790864560, owned_by: "vllm", max_model_len: 262144 },
  ],
});

// The Claude desktop app's two filters, as read out of its bundle (v. 2026-10-01).
// Discovery keeps a row if its id looks like a Claude model or it carries a
// known anthropic_family_tier; the PICKER then keeps only ids that look like an
// Anthropic route, after rejecting any id that names another vendor's model.
// The vendor list here is an excerpt, but "qwen" and "gemma" are on it.
const OTHER_VENDORS = /qwen|gemma|llama|deepseek|gpt|mistral|gemini|glm|kimi/;
const looksAnthropic = id => {
  const t = id.toLowerCase();
  if (OTHER_VENDORS.test(t)) return false;
  return new RegExp(`^(${ANTHROPIC_TIERS.join("|")})(-[\\d.]+)?$`).test(t)
    || ["claude", ...ANTHROPIC_TIERS, "anthropic"].some(w => t.includes(w));
};
const usable = body => body.data.filter(m =>
  looksAnthropic(m.id) || ANTHROPIC_TIERS.includes(String(m.anthropic_family_tier).toLowerCase()));
const picker = body => usable(body).filter(m => looksAnthropic(m.id));

test("the desktop app's picker shows exactly one model: claude-local, named for what it is", () => {
  const out = withAnthropicFields(vllmModels());
  const shown = picker(out);
  assert.equal(shown.length, 1);
  assert.equal(shown[0].id, "claude-local");
  assert.equal(shown[0].display_name, "Qwen3.8 27B MXFP4 (vLLM)");
  assert.equal(shown[0].anthropic_family_tier, "sonnet");
  assert.equal(shown[0].max_input_tokens, 262144);
});

test("a request for claude-local reaches the engine as a name it serves", () => {
  assert.equal(engineModelId("claude-local"), "local-qwen3.8-27b-mxfp4");
  // And the residency check knows which model was meant.
  assert.equal(modelFor("claude-local")?.id, "local-qwen3.8-27b-mxfp4");
  // Every other id passes through untouched, unknown ones included.
  for (const id of ["local-qwen3.8-27b-mxfp4", "Qwen3.8", "local-gemma-4-26b-a4b", "mystery-7b", undefined]) {
    assert.equal(engineModelId(id), id);
  }
});

test("an OpenAI caller reads the same rows it always has, plus the one alias", () => {
  const before = vllmModels();
  const out = withAnthropicFields(vllmModels());
  assert.equal(out.object, "list");
  assert.deepEqual(out.data.map(m => m.id), [...before.data.map(m => m.id), "claude-local"]);
  for (const [i, m] of before.data.entries()) {
    for (const [k, v] of Object.entries(m)) assert.deepEqual(out.data[i][k], v, `${m.id}.${k}`);
  }
});

test("every row carries Anthropic's common fields, and the list says it is complete", () => {
  const out = withAnthropicFields(vllmModels());
  for (const m of out.data) {
    assert.equal(m.type, "model");
    assert.equal(typeof m.display_name, "string");
    assert.equal(m.created_at, "2026-10-01T14:22:40.000Z");
  }
  // has_more must be false, or the app pages with after_id and logs a failure.
  assert.equal(out.has_more, false);
  assert.equal(out.first_id, "local-qwen3.8-27b-mxfp4");
  assert.equal(out.last_id, "claude-local");
});

test("an engine that only answers to one of its own aliases still gets claude-local", () => {
  const out = withAnthropicFields({ object: "list", data: [{ id: "Qwen3.8", object: "model", created: 0 }] });
  assert.deepEqual(picker(out).map(m => m.id), ["claude-local"]);
});

test("a model this registry does not know is listed but never tiered", () => {
  const out = withAnthropicFields({ object: "list", data: [{ id: "mystery-7b", object: "model" }] });
  assert.equal(out.data.length, 1);
  assert.equal(usable(out).length, 0);
});

test("an empty or broken engine answer stays empty", () => {
  assert.deepEqual(withAnthropicFields({ object: "list", data: [] }).data, []);
  assert.deepEqual(withAnthropicFields(null).data, []);
});
