// Renders services from /api/services. Links use the address you opened this page
// on, so they keep working if the machine's name changes. Text is inserted as text.
const root = document.getElementById("groups");
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
  a.href = `https://${location.hostname}${s.port === 443 ? "" : `:${s.port}`}${s.path || "/"}`;
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
