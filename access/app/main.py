"""Who may use which app: the authorization half of the domain's single sign-on.

Caddy asks two questions on every gated request:
  1. the `sso` oauth2-proxy: who is this?  (Google sign-in; sets X-Auth-Request-Email)
  2. this service, GET /authz:   may that person use this app?  (X-Access-App)
Owners (OWNER_EMAILS, from the environment, not the database) may use every app,
including this one's admin page, so nobody can lock themselves out from the UI.

Rules live in Mongo (db "access", collection "apps"): one document per app with
the emails allowed. Every change also rewrites SSO_EMAILS_FILE, the union of all
allowed emails, which the sso proxy watches: strangers are refused at sign-in
and known people are refused per app here. Fail closed: an unknown app, a
missing email or a database outage means no.
"""

from __future__ import annotations

import html
import logging
import os
import re
import threading
import time
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, Response
from pydantic import BaseModel
from pymongo import MongoClient

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
log = logging.getLogger("access")

STATIC = Path(__file__).parent.parent / "static"
OWNERS = {e.strip().lower() for e in os.environ.get("OWNER_EMAILS", "").split(",") if e.strip()}
EMAIL_HEADER = "X-Auth-Request-Email"
APP_HEADER = "X-Access-App"
SSO_EMAILS_FILE = Path(os.environ.get("SSO_EMAILS_FILE", "/data/sso-emails.txt"))
DOMAIN = os.environ.get("DOMAIN", "")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# The apps Caddy gates, by id (the first argument of its `gate` snippet). Created
# on first start with no extra emails (owners only); never overwritten after that.
SEED_APPS = {
    "access":         ("Access admin", "This page: who may use which app", "access"),
    "home":           ("Home page", "The tailnet home page with links to everything", ""),
    "hottub-admin":   ("Hot tub admin", "Settings on hottub.<domain>/admin (the guest page stays open)", "hottub"),
    "home-studio":    ("Home Studio", "Agents and automations over Home Assistant", "home.studio"),
    "witness-studio": ("Witness Studio", "Household agents, missions and transactions", "witness.studio"),
    "grafana":        ("Grafana", "Dashboards for both boxes", "grafana"),
    "mongo":          ("Mongo browser", "Read-only view of every database", "mongo"),
    "bench":          ("Model Bench", "Cases, runs and results", "bench"),
    "llm":            ("Local inference", "The inference box's admin page", "llm"),
    "dogs":           ("Dog Tracker", "", "dogs"),
}

client = MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=3000)
apps = client.get_database("access")["apps"]

_cache: dict[str, dict] = {}
_cache_at = 0.0
_lock = threading.Lock()
CACHE_S = 15


def _load() -> dict[str, dict]:
    global _cache, _cache_at
    with _lock:
        if time.time() - _cache_at > CACHE_S:
            _cache = {d["_id"]: d for d in apps.find()}
            _cache_at = time.time()
        return _cache


def _invalidate_and_sync() -> None:
    """After a change: reload the rules and rewrite the sso allow-list."""
    global _cache_at
    _cache_at = 0
    rules = _load()
    emails = set(OWNERS)
    for d in rules.values():
        emails.update(d.get("emails", []))
    SSO_EMAILS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = SSO_EMAILS_FILE.with_suffix(".tmp")
    tmp.write_text("".join(f"{e}\n" for e in sorted(emails)))
    tmp.replace(SSO_EMAILS_FILE)  # atomic, so the proxy never reads half a file
    log.info("sso allow-list: %d emails", len(emails))


def _seed() -> None:
    for app_id, (name, desc, sub) in SEED_APPS.items():
        apps.update_one(
            {"_id": app_id},
            {"$setOnInsert": {"name": name, "description": desc, "sub": sub, "emails": []}},
            upsert=True,
        )
    _invalidate_and_sync()


app = FastAPI(title="Access", docs_url=None, redoc_url=None)


@app.on_event("startup")
def startup() -> None:
    for _ in range(20):  # Mongo may still be starting
        try:
            _seed()
            return
        except Exception as e:  # noqa: BLE001
            log.warning("waiting for Mongo: %s", e)
            time.sleep(3)
    raise RuntimeError("Mongo unreachable")


# --- the gate ----------------------------------------------------------------
DENIED = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>No access</title>
<style>body{{font:16px/1.5 system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;
background:#f3f6f7;color:#0f2530}}main{{max-width:28em;padding:24px}}h1{{font-size:22px;margin:0 0 8px}}
p{{color:#5b6f78}}a{{color:#0e8fb0}}@media(prefers-color-scheme:dark){{body{{background:#0b1d26;color:#e8f2f5}}
p{{color:#93adb7}}a{{color:#38b6d6}}}}</style></head><body><main>
<h1>No access to {app}</h1><p>You're signed in as <b>{email}</b>, which isn't on the list for this app.
Ask the owner to add you on the access page.</p>
<p><a href="https://auth.{domain}/oauth2/sign_out?rd=https://{domain}/">Sign in as someone else</a></p>
</main></body></html>"""


@app.get("/authz")
def authz(request: Request):
    email = (request.headers.get(EMAIL_HEADER) or "").strip().lower()
    app_id = request.headers.get(APP_HEADER) or ""
    if not email:
        return Response(status_code=401)
    allowed = email in OWNERS
    if not allowed:
        try:
            rule = _load().get(app_id)
        except Exception:  # noqa: BLE001  (database down: fail closed)
            log.exception("rules unavailable")
            rule = None
        allowed = bool(rule) and email in rule.get("emails", [])
    if allowed:
        return Response(status_code=200, headers={EMAIL_HEADER: email})
    log.info("denied %s -> %s", email, app_id)
    name = _cache.get(app_id, {}).get("name", app_id or "this app")
    return HTMLResponse(DENIED.format(app=html.escape(name), email=html.escape(email), domain=DOMAIN),
                        status_code=403)


# --- admin -------------------------------------------------------------------
def owner(request: Request) -> str:
    email = (request.headers.get(EMAIL_HEADER) or "").strip().lower()
    if email not in OWNERS:
        raise HTTPException(403, "owner only")
    return email


@app.get("/api/apps")
def list_apps(me: str = Depends(owner)):
    rules = _load()
    return {
        "me": me, "owners": sorted(OWNERS), "domain": DOMAIN,
        "apps": [{"id": k, "name": d.get("name", k), "description": d.get("description", ""),
                  "sub": d.get("sub", ""), "emails": sorted(d.get("emails", []))}
                 for k, d in sorted(rules.items(), key=lambda kv: kv[1].get("name", kv[0]).lower())],
    }


class Email(BaseModel):
    email: str


@app.post("/api/apps/{app_id}/emails")
def add_email(app_id: str, body: Email, me: str = Depends(owner)):
    e = body.email.strip().lower()
    if not EMAIL_RE.match(e):
        raise HTTPException(422, "not an email address")
    if not apps.update_one({"_id": app_id}, {"$addToSet": {"emails": e}}).matched_count:
        raise HTTPException(404, "no such app")
    log.info("%s allowed %s on %s", me, e, app_id)
    _invalidate_and_sync()
    return {"ok": True}


@app.delete("/api/apps/{app_id}/emails/{email}")
def remove_email(app_id: str, email: str, me: str = Depends(owner)):
    e = email.strip().lower()
    if not apps.update_one({"_id": app_id}, {"$pull": {"emails": e}}).matched_count:
        raise HTTPException(404, "no such app")
    log.info("%s removed %s from %s", me, e, app_id)
    _invalidate_and_sync()
    return {"ok": True}


@app.get("/healthz")
def healthz():
    try:
        client.admin.command("ping")
        return {"ok": True}
    except Exception:  # noqa: BLE001
        raise HTTPException(503, "mongo unreachable")


@app.get("/")
def index(_: str = Depends(owner)):
    return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})
