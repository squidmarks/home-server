// Fitting a conversation's images to what the engine will take.
//
// vLLM's image limit is per PROMPT, and an Anthropic client sends the whole
// conversation as the prompt every turn. So once a thread holds one image more
// than the limit, every later turn is refused outright -- the user added a
// second screenshot an hour ago and now nothing works. The Claude desktop app
// does not trim for the engine (it was built for Claude, which takes many), so
// the shim does: the NEWEST images are kept, since they are what the
// conversation is about now, and each older one is replaced by a line of text
// saying so, so the model knows something was there rather than meeting a gap.
//
// Images inside tool results count too: that is where Claude Code's screenshots
// arrive.

/** The text an image is replaced with. */
export function placeholder(limit) {
  return `[image removed by the local inference server: it accepts at most ${limit} image${limit === 1 ? "" : "s"} per conversation, and only the most recent ${limit === 1 ? "is" : "are"} kept]`;
}

const isImage = b => b && typeof b === "object" && b.type === "image";

/** Every image block in an Anthropic messages body, oldest first, with how to replace it. */
function imageSlots(body) {
  const slots = [];
  const scan = (blocks) => {
    if (!Array.isArray(blocks)) return;
    for (let i = 0; i < blocks.length; i++) {
      const b = blocks[i];
      if (isImage(b)) slots.push({ blocks, i });
      else if (b?.type === "tool_result") scan(b.content);
    }
  };
  for (const m of Array.isArray(body?.messages) ? body.messages : []) scan(m?.content);
  return slots;
}

/** How many images a messages body carries, across the whole conversation. */
export function countImages(body) {
  return imageSlots(body).length;
}

/**
 * Pure: the body with all but its newest `limit` images replaced by text.
 * Returns { body, dropped }. The input is not modified. An unknown limit (null)
 * changes nothing -- absent means "could not tell", not "refuse".
 */
export function trimImages(body, limit) {
  if (!Number.isInteger(limit) || limit < 0) return { body, dropped: 0 };
  const copy = structuredClone(body);
  const slots = imageSlots(copy);
  const excess = slots.length - limit;
  if (excess <= 0) return { body, dropped: 0 };
  const text = { type: "text", text: placeholder(limit) };
  for (const { blocks, i } of slots.slice(0, excess)) blocks[i] = { ...text };
  return { body: copy, dropped: excess };
}
