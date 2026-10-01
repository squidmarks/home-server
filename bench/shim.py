#!/usr/bin/env python3
"""The inference box's engine, as the bench sees it: through the shim's admin API.

    shim.py label              the running profile's name ("" if none)
    shim.py describe           JSON: what is serving right now (recorded with results)
    shim.py set <profile>      switch profile and wait until it is the one running

Replaces calling llama/profiles.sh and llama/vllm-profiles.sh on the box, so the
bench can run on another machine. It is also the better witness: those scripts
read a name file, which said vLLM was "down" with no profile while the shim --
asking the running container -- knew it was up on `sly`. Everything here is
what the shim observed, never what a file claims.

SHIM_ADMIN_URL (from env.sh) is the shim's base, e.g. http://<inference>:8091.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

ADMIN = os.environ.get("SHIM_ADMIN_URL", "http://172.18.0.1:8091").rstrip("/")
# A profile switch restarts the engine; a 27B model takes minutes to load.
SWITCH_TIMEOUT_S = int(os.environ.get("SHIM_SWITCH_TIMEOUT_S", "1200"))


def call(method, path, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(ADMIN + path, data=data, method=method,
                                 headers={"content-type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


def status():
    code, s = call("GET", "/admin/status")
    return s if code == 200 and isinstance(s, dict) else None


def describe():
    """Same shape the profile scripts' `describe` gave: engine, profile, health."""
    s = status()
    if not s:
        return {"source": "shim", "health": "down"}
    p = s.get("profile") or {}
    return {
        "source": "shim",
        "engine": p.get("engine") or s.get("backend"),
        "profile": p.get("profile"),
        "model": s.get("model"),
        # The shim reports a resident model only when the engine answers.
        "health": "up" if s.get("model") else "down",
    }


def switching(s):
    sw = (s or {}).get("switching")
    return bool(sw) and not sw.get("finishedAt")


def set_profile(want):
    # Asking for what is already running is a no-op, even on an engine with no
    # profiles (which refuses every switch, including to itself).
    if describe().get("profile") == want:
        return 0
    code, r = call("POST", "/admin/profile", {"profile": want}, timeout=30)
    if code == 200:
        return 0  # already running it
    if code != 202:
        print(f"shim refused profile {want} (HTTP {code}): {(r or {}).get('error', r)}", file=sys.stderr)
        return 1
    print(f"switching to {want} (estimate {(r or {}).get('estimateS', '?')} s)", file=sys.stderr)
    deadline = time.time() + SWITCH_TIMEOUT_S
    while time.time() < deadline:
        time.sleep(10)
        s = status()
        if s and not switching(s) and (s.get("profile") or {}).get("profile") == want and s.get("model"):
            print(f"running {want}", file=sys.stderr)
            return 0
    print(f"profile {want} was not running after {SWITCH_TIMEOUT_S} s; last seen: {json.dumps(describe())}", file=sys.stderr)
    return 1


def main(argv):
    verb = argv[1] if len(argv) > 1 else ""
    if verb == "label":
        print(describe().get("profile") or "")
        return 0
    if verb == "describe":
        print(json.dumps(describe()))
        return 0
    if verb == "set" and len(argv) == 3:
        return set_profile(argv[2])
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
