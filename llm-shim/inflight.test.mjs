// The leak this fixes: a client that disconnects mid-response must still
// release its slot, or every later request is wrongly reported as "shared".
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

function makeRelease(counter) {
  counter.n += 1;
  let released = false;
  const release = () => { if (released) return; released = true; counter.n -= 1; };
  const res = new EventEmitter();
  res.on("close", release);
  res.on("finish", release);
  return { res, release };
}

test("a normal response releases exactly once", () => {
  const c = { n: 0 };
  const { res, release } = makeRelease(c);
  release();            // the explicit call at the end of the body
  res.emit("finish");   // and the lifecycle event
  res.emit("close");
  assert.equal(c.n, 0);
});

test("a client that disconnects mid-stream still releases", () => {
  const c = { n: 0 };
  const { res } = makeRelease(c);   // body throws, never calls release()
  res.emit("close");
  assert.equal(c.n, 0);
});

test("concurrent requests do not release each other's slots", () => {
  const c = { n: 0 };
  const a = makeRelease(c), b = makeRelease(c);
  assert.equal(c.n, 2);
  a.res.emit("close");
  assert.equal(c.n, 1, "b still holds its slot");
  b.res.emit("close");
  assert.equal(c.n, 0);
});
