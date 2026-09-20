import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { buildStatus, checkOne, createServer } from "./server.mjs";

let server, base, tmp;
const config = { title: "t", groups: [{ name: "G", services: [
  { name: "A", port: 1, check: "http://a/" }, { name: "B", port: 2, check: "http://b/" },
  { name: "C", check: "http://c/" }, { name: "D", port: 4 },
] }] };
const fake = async url => { if (url.includes("//b/")) throw new Error("refused"); return { status: url.includes("//c/") ? 503 : 302 }; };

before(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), "home-"));
  await fs.writeFile(path.join(tmp, "s.json"), JSON.stringify(config));
  server = createServer({ servicesFile: path.join(tmp, "s.json"), fetchImpl: fake });
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(async () => { server.close(); await fs.rm(tmp, { recursive: true, force: true }); });

test("a service is up below a 500, down on error or 5xx, unknown without a check", async () => {
  assert.equal(await checkOne("http://a/", fake), "up");
  assert.equal(await checkOne("http://b/", fake), "down");
  assert.equal(await checkOne("http://c/", fake), "down");
  assert.equal(await checkOne(undefined, fake), "unknown");
});

test("status keeps the config's grouping and fields", async () => {
  const s = await buildStatus(config, fake);
  assert.deepEqual(s.groups[0].services.map(x => [x.name, x.status, x.port]), [["A", "up", 1], ["B", "down", 2], ["C", "down", null], ["D", "unknown", 4]]);
});

test("serves the page, the api, and refuses odd paths", async () => {
  assert.equal((await fetch(base + "/")).status, 200);
  const api = await (await fetch(base + "/api/services")).json();
  assert.equal(api.groups[0].services.length, 4);
  assert.equal((await fetch(base + "/..%2fserver.mjs")).status, 404);
  assert.equal((await fetch(base + "/.hidden")).status, 404);
  assert.equal((await fetch(base + "/", { method: "POST" })).status, 405);
});
