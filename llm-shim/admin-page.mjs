// The shim's own admin page. Small, dependency-free, and the only place the
// backend can be switched — the homepage links here rather than carrying the
// control itself, so a status board stays a status board.
export function adminPage() {
  return `<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Local inference</title>
<style>
 :root{--bg:#f6f7f9;--panel:#fff;--line:#e3e6eb;--fg:#111;--muted:#667;--good:#137333;--bad:#c5221f;--warn:#a06000;--accent:#2563eb}
 @media (prefers-color-scheme:dark){:root{--bg:#0c0f13;--panel:#151a21;--line:#2a303a;--fg:#e8eaed;--muted:#9aa0a6}}
 *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 ui-sans-serif,system-ui,sans-serif}
 main{max-width:720px;margin:0 auto;padding:24px 16px}
 h1{font-size:22px;margin:0 0 4px} .sub{color:var(--muted);margin:0 0 20px}
 .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:14px}
 .row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
 .dot{width:9px;height:9px;border-radius:50%;display:inline-block}
 .up{background:var(--good)} .down{background:var(--bad)} .unknown{background:var(--muted)}
 .name{font-weight:600} .note{color:var(--muted);font-size:13px}
 .spacer{flex:1}
 button{font:inherit;padding:7px 14px;border-radius:7px;border:1px solid var(--line);background:var(--panel);color:var(--fg);cursor:pointer}
 button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
 button[disabled]{opacity:.5;cursor:default}
 pre{background:var(--bg);border:1px solid var(--line);border-radius:7px;padding:10px;overflow:auto;font-size:12px;max-height:220px;margin:10px 0 0}
 .pill{font-size:12px;padding:2px 8px;border-radius:99px;border:1px solid var(--line);color:var(--muted)}
 .crumb{display:inline-block;margin:0 0 14px;color:var(--muted);text-decoration:none;font-size:13px}
 .crumb:hover{color:var(--accent)}
</style>
<main>
 <!-- Back to the index. nginx mounts this under /llm/, so the link is the
      site root, not a relative hop: a relative "../" lands on /llm/ and
      redirects straight back here. -->
 <a class="crumb" href="/">&larr; server</a>
 <h1>Local inference</h1>
 <p class="sub">One endpoint in front of the GPU. The card holds one model at a time: loading another stops the one running, and takes a few minutes. Requests for a model that is not loaded are refused, never queued.</p>
 <div id="app"><p class="note">Loading…</p></div>
</main>
<script>
const app = document.getElementById("app");
// Where this page is mounted. tailscale serve can publish it under a path
// prefix (https://server/llm/admin/), and it forwards the request with the
// prefix stripped -- so the page must ask for its API relative to wherever it
// was actually loaded, not from the site root.
// No regex here on purpose: this whole page is a template literal, and a
// backslash in it is an escape the literal eats before the browser sees it.
// The first attempt collapsed into a line comment and took the rest of the
// line with it. No backticks in here either: they close this literal.
const BASE = location.pathname.endsWith("/admin/")
  ? location.pathname.slice(0, -"/admin/".length)
  : location.pathname.endsWith("/admin")
    ? location.pathname.slice(0, -"/admin".length)
    : "";
const esc = s => String(s).replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
let busy = false;

async function draw(){
  let s; try { s = await (await fetch(BASE + "/admin/status")).json(); }
  catch { app.innerHTML = '<div class="card">Could not reach the shim.</div>'; return; }
  const sw = s.switching && !s.switching.finishedAt;
  // Models are the unit here, not engines. A studio asks for a model id; which
  // engine serves it is ours to change. One card, one model: loading another
  // stops this one, so the button is a deliberate act and never a side effect
  // of a request arriving.
  const models = (s.models || []).map(m => \`
    <div class="card"><div class="row">
      <span class="dot \${m.resident ? 'up' : 'down'}"></span>
      <span class="name">\${esc(m.name)}</span>
      \${m.resident ? '<span class="pill">loaded</span>' : ''}
      <span class="spacer"></span>
      <span class="note">\${esc(m.id)} · \${esc(m.engine)}</span>
      <button class="\${m.resident?'':'primary'}" \${(m.resident||sw||busy||!s.canSwitch||s.inFlight>0)?'disabled':''}
        onclick="loadModel('\${m.id}')">\${m.resident?'Loaded':'Load this'}</button>
    </div></div>\`).join("");
  const engineNote = Object.entries(s.engines)
    .map(([id,e]) => esc(e.name) + " " + e.health).join(" · ");
  const notes = [];
  if (!s.canSwitch) notes.push("Switching is not configured on this host (SWITCH_CMD unset).");
  if (s.inFlight > 0) notes.push(s.inFlight + " request(s) in flight — loading is blocked until idle.");
  if (!s.model) notes.push("No model is loaded: requests are refused until one is.");
  const r = s.residency || {};
  if (r.canSwitchAt) notes.push("Held less than the " + Math.round((r.minMs||0)/60000)
    + " min minimum residency — another model can be loaded after "
    + new Date(r.canSwitchAt).toLocaleTimeString() + ".");
  app.innerHTML = models
    + (sw ? \`<div class="card"><div class="row"><span class="dot unknown"></span>
        <span class="name">Loading \${esc(s.switching.to)}…</span>
        <span class="note">this takes minutes: vLLM compiles kernels, llama.cpp reloads ~16&nbsp;GB</span></div>
        <pre>\${esc(s.switching.log || "starting…")}</pre></div>\` : "")
    + \`<div class="card"><div class="row"><span class="name">Engines</span><span class="spacer"></span>
        <span class="note">\${engineNote}</span></div></div>\`
    + \`<div class="card"><div class="row"><span class="name">Power</span><span class="spacer"></span>
        <span class="note">\${s.power.plug ? esc(s.power.plug)+" · idle "+s.power.idleWatts+" W · "+esc(s.power.schedule||"flat rate") : "no meter configured"}</span></div></div>\`
    + (notes.length ? \`<div class="card note">\${notes.map(esc).join("<br>")}</div>\` : "");
}
async function loadModel(id){
  if (!confirm("Load " + id + "? The card holds one model, so whatever is loaded now stops. This takes a few minutes.")) return;
  busy = true; draw();
  try {
    const r = await fetch(BASE + "/admin/model", {method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({model:id})});
    if (!r.ok) { const b = await r.json().catch(() => ({})); alert(b.error || ("HTTP " + r.status)); }
  } finally { busy = false; }
  draw();
}
draw(); setInterval(draw, 4000);
</script>`;
}
