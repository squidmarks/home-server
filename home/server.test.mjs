import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { buildStatus, checkOne, createServer, defaultServicesFile, tailnetSuffix } from "./server.mjs";

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

test("a service on another machine keeps its short host and scheme; {tailnet} checks use the suffix", async () => {
  const seen = [];
  const record = async url => { seen.push(url); return { status: 200 }; };
  const cfg = { fqdn: "home.example.ts.net", groups: [{ name: "G", services: [
    { name: "Remote", host: "server", port: 3443, check: "https://server.{tailnet}:3443/ping" },
    { name: "HA", host: "homeassistant", scheme: "http", port: null, check: "http://homeassistant.{tailnet}/" },
    { name: "Local", port: 3743, check: "http://127.0.0.1:3702/" },
  ] }] };
  const s = await buildStatus(cfg, record);
  assert.equal(s.tailnet, "example.ts.net");
  assert.deepEqual(seen, ["https://server.example.ts.net:3443/ping", "http://homeassistant.example.ts.net/", "http://127.0.0.1:3702/"]);
  assert.deepEqual(s.groups[0].services.map(x => [x.host, x.scheme]), [["server", "https"], ["homeassistant", "http"], [null, "https"]]);
});

test("a {tailnet} check without a tailnet name is unknown, not down", async () => {
  const s = await buildStatus({ fqdn: "", groups: [{ name: "G", services: [{ name: "R", host: "server", check: "https://server.{tailnet}/" }] }] }, fake);
  assert.equal(s.groups[0].services[0].status, "unknown");
  assert.equal(tailnetSuffix(""), "");
});

test("each box reads its own service list, else services.json", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "home-svc-"));
  try {
    assert.equal(defaultServicesFile(dir, "home"), path.join(dir, "services.json"));
    await fs.writeFile(path.join(dir, "services.home.json"), "{}");
    assert.equal(defaultServicesFile(dir, "home"), path.join(dir, "services.home.json"));
    assert.equal(defaultServicesFile(dir, "server"), path.join(dir, "services.json"));
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("with a domain, services carry their subdomain for https://<sub>.<domain> links", async () => {
  const s = await buildStatus({ domain: "example.com", groups: [{ name: "G", services: [
    { name: "Studio", sub: "studio", port: 3743 }, { name: "Home", sub: "" }, { name: "Plain", port: 1 },
  ] }] }, fake);
  assert.equal(s.domain, "example.com");
  assert.deepEqual(s.groups[0].services.map(x => x.sub), ["studio", "", null]);
});
