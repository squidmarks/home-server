#!/usr/bin/env python3
"""Show scrape-target health and which metric families exist in Prometheus.

    python3 check.py            # targets + family counts
    python3 check.py <prefix>   # list metric names starting with <prefix>
"""
import json
import sys
import urllib.request

PROM = "http://localhost:9090"


def get(path):
    return json.load(urllib.request.urlopen(PROM + path, timeout=15))["data"]


if len(sys.argv) > 1:
    names = [n for n in get("/api/v1/label/__name__/values") if n.startswith(sys.argv[1])]
    print("\n".join(sorted(names)))
    sys.exit(0)

for t in get("/api/v1/targets")["activeTargets"]:
    err = (t.get("lastError") or "")[:100]
    print(f"{t['labels']['job']:12} {t['health']:5} {t['scrapeUrl']}  {err}")
print()
names = get("/api/v1/label/__name__/values")
for prefix in ("node_drm", "node_hwmon", "node_cpu", "container_cpu", "mongodb_up", "mongodb_ss_", "studio_", "llamacpp:"):
    print(f"{prefix:16} {len([n for n in names if n.startswith(prefix)])} metrics")
