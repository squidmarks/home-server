import { test } from "node:test";
import assert from "node:assert/strict";
import { ctxFromProps } from "./adapters/index.mjs";

test("llama.cpp's n_ctx is found wherever that build put it", () => {
  // The shape llama-server uses today.
  assert.equal(ctxFromProps({ default_generation_settings: { n_ctx: 262144 } }), 262144);
  // A nesting older builds used.
  assert.equal(ctxFromProps({ default_generation_settings: { params: { n_ctx: 131072 } } }), 131072);
  // And a flat one some expose.
  assert.equal(ctxFromProps({ n_ctx: 65536 }), 65536);
});

test("an unset window is not an answer", () => {
  // 0 is llama.cpp's "unset". Returning it would hand a caller a context window
  // of zero, which is worse than telling them we do not know.
  assert.equal(ctxFromProps({ default_generation_settings: { n_ctx: 0 } }), null);
  assert.equal(ctxFromProps({}), null);
  assert.equal(ctxFromProps(null), null);
  assert.equal(ctxFromProps({ default_generation_settings: { n_ctx: "lots" } }), null);
});

test("the first place that has a real number wins", () => {
  // A build that carries both must not have the deeper, staler one preferred.
  assert.equal(
    ctxFromProps({ default_generation_settings: { n_ctx: 262144, params: { n_ctx: 4096 } } }),
    262144,
  );
});
