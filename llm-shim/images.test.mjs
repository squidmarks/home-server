import { test } from "node:test";
import assert from "node:assert/strict";
import { countImages, placeholder, trimImages } from "./images.mjs";

const img = tag => ({ type: "image", source: { type: "base64", media_type: "image/png", data: tag } });
const thread = () => ({
  model: "claude-local",
  messages: [
    { role: "user", content: [{ type: "text", text: "look" }, img("first")] },
    { role: "assistant", content: [{ type: "tool_use", id: "t1", name: "screenshot", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: [img("second")] }] },
    { role: "assistant", content: "ok" },
    { role: "user", content: [img("third"), { type: "text", text: "and this?" }] },
  ],
});
const kept = body => JSON.stringify(body).match(/"data":"(\w+)"/g)?.map(s => s.slice(8, -1)) ?? [];

test("images are counted across the whole conversation, tool results included", () => {
  assert.equal(countImages(thread()), 3);
  assert.equal(countImages({ messages: [{ role: "user", content: "plain string" }] }), 0);
  assert.equal(countImages(null), 0);
});

test("only the newest images are kept, and each dropped one says why", () => {
  const { body, dropped } = trimImages(thread(), 1);
  assert.equal(dropped, 2);
  assert.deepEqual(kept(body), ["third"]);
  assert.deepEqual(body.messages[0].content[1], { type: "text", text: placeholder(1) });
  // The tool result keeps its shape: a content array, now holding text.
  assert.deepEqual(body.messages[2].content[0].content, [{ type: "text", text: placeholder(1) }]);
  // Nothing else moves.
  assert.equal(body.messages[0].content[0].text, "look");
  assert.equal(body.messages[4].content[1].text, "and this?");
  assert.equal(body.model, "claude-local");
});

test("a limit of two keeps the two newest", () => {
  assert.deepEqual(kept(trimImages(thread(), 2).body), ["second", "third"]);
});

test("a conversation within the limit is returned as is", () => {
  const t = thread();
  const out = trimImages(t, 3);
  assert.equal(out.dropped, 0);
  assert.equal(out.body, t);
});

test("a limit of zero drops every image; an unknown limit drops none", () => {
  assert.deepEqual(kept(trimImages(thread(), 0).body), []);
  assert.equal(trimImages(thread(), null).dropped, 0);
});

test("the caller's body is never modified", () => {
  const t = thread();
  trimImages(t, 1);
  assert.deepEqual(kept(t), ["first", "second", "third"]);
});

test("the placeholder reads correctly for one image and for several", () => {
  assert.match(placeholder(1), /at most 1 image per conversation, and only the most recent is kept/);
  assert.match(placeholder(2), /at most 2 images per conversation, and only the most recent are kept/);
});
