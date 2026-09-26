// Renders services from /api/services. Port links use the tailnet FQDN the API
// on, so they keep working if the machine's name changes. Text is inserted as text.
const root = document.getElementById("groups");
// The tailnet FQDN the API reports; port links need it (see card()).
const config = { fqdn: "" };
const el = (tag, cls, ...kids) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  for (const k of kids) n.append(k?.nodeType ? k : document.createTextNode(k ?? ""));
  return n;
};

function card(s) {
  const linked = s.port !== null;
  const inner = [
    el("b", "", el("span", `dot ${s.status}`), s.name, linked && s.port !== 443 ? el("span", "port", `:${s.port}`) : null),
    el("span", "desc", s.description),
  ];
  if (!linked) return el("div", "card", ...inner);
  const a = el("a", "card", ...inner);
  // tailscale serve answers on the tailnet FQDN only, so a port link built from
  // a short hostname does not connect. That did not matter while this page was
  // always opened at the FQDN; it broke every link the moment nginx made
  // http://server/ a second way in. A port link therefore always uses the FQDN
  // the API reports, and a path link stays relative so it works from either.
  const host = s.port === 443 ? "" : (config.fqdn || location.hostname);
  a.href = s.port === 443
    ? `${s.path || "/"}`
    : `https://${host}:${s.port}${s.path || "/"}`;
  return a;
}

function section(g) {
  const grid = el("div", "grid", ...g.services.map(card));
  if (!g.collapsed) return el("div", "", el("h2", "", g.name), grid);
  const d = el("details", "", el("summary", "", el("h2", "", g.name)), grid);
  d.querySelector("summary h2").style.display = "inline-block";
  return d;
}

async function load() {
  try {
    const data = await (await fetch("/api/services")).json();
    config.fqdn = data.fqdn || "";
    document.title = data.title;
    document.getElementById("title").textContent = data.title;
    document.getElementById("checked").textContent = `checked ${new Date(data.checkedAt).toLocaleTimeString()}`;
    const open = new Set([...root.querySelectorAll("details[open] summary h2")].map(h => h.textContent));
    root.replaceChildren(...data.groups.map(section));
    for (const d of root.querySelectorAll("details")) if (open.has(d.querySelector("h2").textContent)) d.open = true;
  } catch {
    root.replaceChildren(el("div", "err", "Could not load the service list."));
  }
}
load();
setInterval(load, 20000);
