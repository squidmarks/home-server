// Home page for the tailnet: links to every app, with a live up/down dot.
// Zero dependencies. Each box reads services.<hostname>.json (else services.json);
// edit it to add or change an app. A service on another machine names it by its
// short name in `host`, and checks may use "{tailnet}" for the tailnet suffix --
// both are completed from TAILNET_FQDN, so no tailnet name is committed. When
// DOMAIN is set, a service with `sub` links to https://<sub>.<DOMAIN> instead.
//   PORT (default 3090), HOST (default 127.0.0.1), SERVICES_FILE, TAILNET_FQDN, DOMAIN
import http from "node:http";
import fs from "node:fs/promises";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECK_TIMEOUT_MS = 2000;
const CACHE_MS = 8000;

async function loadConfig(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}

// A service is "up" if it answers at all with anything below a server error.
export async function checkOne(url, fetchImpl = fetch) {
  if (!url) return "unknown";
  try {
    const res = await fetchImpl(url, { redirect: "manual", signal: AbortSignal.timeout(CHECK_TIMEOUT_MS) });
    return res.status < 500 ? "up" : "down";
  } catch {
    return "down";
  }
}

/** "home.example.ts.net" -> "example.ts.net": the part every machine shares. */
export function tailnetSuffix(fqdn) {
  const dot = (fqdn ?? "").indexOf(".");
  return dot < 0 ? "" : fqdn.slice(dot + 1);
}

/** services.<hostname>.json when it exists, else services.json. */
export function defaultServicesFile(dir = HERE, hostname = os.hostname()) {
  const own = path.join(dir, `services.${hostname}.json`);
  return existsSync(own) ? own : path.join(dir, "services.json");
}

export async function buildStatus(config, fetchImpl = fetch) {
  const fqdn = config.fqdn ?? process.env.TAILNET_FQDN ?? "";
  const tailnet = tailnetSuffix(fqdn);
  // A check naming {tailnet} can't be made without it; report unknown, not down.
  const check = url => (url && url.includes("{tailnet}") ? (tailnet ? url.replaceAll("{tailnet}", tailnet) : undefined) : url);
  const groups = await Promise.all(
    config.groups.map(async g => ({
      name: g.name,
      collapsed: !!g.collapsed,
      services: await Promise.all(
        g.services.map(async s => ({
          name: s.name,
          description: s.description ?? "",
          port: s.port ?? null,
          path: s.path ?? "",
          host: s.host ?? null,
          sub: s.sub ?? null,
          scheme: s.scheme ?? "https",
          status: await checkOne(check(s.check), fetchImpl),
        })),
      ),
    })),
  );
  return {
    title: config.title ?? "server",
    // Port links only resolve on the tailnet FQDN, so the page is told what it
    // is rather than guessing from the address it happened to be opened at.
    fqdn,
    tailnet,
    // With a domain, every service is https://<sub>.<domain> (served by caddy/).
    domain: config.domain ?? process.env.DOMAIN ?? "",
    groups,
    checkedAt: new Date().toISOString(),
  };
}

const MIME = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8" };

export function createServer({ servicesFile = defaultServicesFile(), fetchImpl = fetch } = {}) {
  let cache = { at: 0, body: null };
  return http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://x");
      if (req.method !== "GET") { res.writeHead(405).end(); return; }
      if (url.pathname === "/api/services") {
        if (!cache.body || Date.now() - cache.at > CACHE_MS) cache = { at: Date.now(), body: await buildStatus(await loadConfig(servicesFile), fetchImpl) };
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        res.end(JSON.stringify(cache.body));
        return;
      }
      const name = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
      if (!/^[A-Za-z0-9._-]+$/.test(name) || name.startsWith(".")) { res.writeHead(404).end("not found"); return; }
      const body = await fs.readFile(path.join(HERE, "public", name));
      res.writeHead(200, { "content-type": MIME[path.extname(name)] ?? "application/octet-stream" });
      res.end(body);
    } catch (e) {
      res.writeHead(e.code === "ENOENT" ? 404 : 500).end(e.code === "ENOENT" ? "not found" : "error");
    }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 3090);
  const host = process.env.HOST || "127.0.0.1";
  createServer({ servicesFile: process.env.SERVICES_FILE || defaultServicesFile() }).listen(port, host, () => console.log(`home on ${host}:${port}`));
}
