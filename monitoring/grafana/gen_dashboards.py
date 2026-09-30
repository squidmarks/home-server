#!/usr/bin/env python3
"""Generate the Grafana dashboards (JSON) for this server.

    python3 gen_dashboards.py            # write dashboards/*.json
    python3 gen_dashboards.py --verify   # also run every query against Prometheus
                                         # (http://localhost:9090) and list empty ones

To add capability to the dashboard: add a panel to a dashboard below, or add a
new dashboard() and register it in DASHBOARDS. Grafana reloads the files every
30 s. Panels are laid out automatically: each row is a list of panels whose
widths (out of 24) are split evenly unless given.
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

DS = {"type": "prometheus", "uid": "prom"}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")

# GPU chip label in node_hwmon_* (the amdgpu hwmon device).
GPU = 'chip=~"0000:02.*"'
LLAMA_HELP = "Needs llama-server started with --metrics."


def target(expr, legend="", ref="A", instant=False):
    t = {"datasource": DS, "expr": expr, "legendFormat": legend, "refId": ref}
    if instant:
        t.update(instant=True, range=False)
    return t


def _targets(exprs):
    out = []
    for i, e in enumerate(exprs):
        expr, legend = e if isinstance(e, tuple) else (e, "")
        out.append(target(expr, legend, chr(ord("A") + i)))
    return out


def stat(title, expr, unit="short", thresholds=None, desc="", decimals=None, color_mode="value", legend=""):
    steps = [{"color": "green", "value": None}]
    for value, color in thresholds or []:
        steps.append({"color": color, "value": value})
    p = {
        "type": "stat",
        "title": title,
        "description": desc,
        "datasource": DS,
        "targets": [target(expr, legend, instant=False)],
        "options": {"colorMode": color_mode, "graphMode": "area", "reduceOptions": {"calcs": ["lastNotNull"]}, "textMode": "auto"},
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}, "noValue": "n/a"}, "overrides": []},
    }
    if decimals is not None:
        p["fieldConfig"]["defaults"]["decimals"] = decimals
    return p


def gauge(title, expr, unit="percent", maxv=100, thresholds=None, desc=""):
    steps = [{"color": "green", "value": None}]
    for value, color in thresholds or [(70, "yellow"), (90, "red")]:
        steps.append({"color": color, "value": value})
    return {
        "type": "gauge",
        "title": title,
        "description": desc,
        "datasource": DS,
        "targets": [target(expr)],
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "showThresholdMarkers": True},
        "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": maxv, "thresholds": {"mode": "absolute", "steps": steps}, "noValue": "n/a"}, "overrides": []},
    }


def ts(title, exprs, unit="short", desc="", stack=False, fill=15, minv=None, maxv=None):
    d = {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": fill, "showPoints": "never", "spanNulls": True}, "noValue": "no data"}
    if stack:
        d["custom"]["stacking"] = {"mode": "normal"}
    if minv is not None:
        d["min"] = minv
    if maxv is not None:
        d["max"] = maxv
    return {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "datasource": DS,
        "targets": _targets(exprs if isinstance(exprs, list) else [exprs]),
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
        "fieldConfig": {"defaults": d, "overrides": []},
    }


def table(title, expr, columns=None, desc="", unit="short"):
    """Instant-query table. `columns` maps label/field -> display name (others hidden)."""
    p = {
        "type": "table",
        "title": title,
        "description": desc,
        "datasource": DS,
        "targets": [target(expr, instant=True)],
        "options": {"showHeader": True, "sortBy": [{"displayName": "Value", "desc": True}]},
        "fieldConfig": {"defaults": {"unit": unit}, "overrides": []},
        "transformations": [],
    }
    if columns:
        keep = {c: True for c in columns}
        p["transformations"] = [
            {"id": "organize", "options": {"excludeByName": {"Time": True, "__name__": True, "job": True, "instance": True}, "renameByName": columns}}
        ]
        del keep
    return p


def bargauge(title, expr, legend="{{collection}}", unit="short", desc=""):
    return {
        "type": "bargauge",
        "title": title,
        "description": desc,
        "datasource": DS,
        "targets": [target(expr, legend, instant=True)],
        "options": {"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"]}},
        "fieldConfig": {"defaults": {"unit": unit, "min": 0, "noValue": "no data"}, "overrides": []},
    }


# Host and container metrics come from both boxes; each series has a `host`
# label (home / inference, see prometheus.yml). History from before the move
# has none, and it all came from the inference box, so `inference|` matches it.
INFERENCE = 'host=~"inference|"'
HOME = 'host="home"'
_HOST_METRIC = re.compile(r'\b((?:node|container)_[A-Za-z0-9_]+)(\{[^}]*\})?')


def scoped(expr, matcher):
    """Add `matcher` to every node_*/container_* selector in `expr`."""
    def add(m):
        inner = m.group(2)[1:-1] if m.group(2) else ""
        return f"{m.group(1)}{{{matcher}{', ' + inner if inner else ''}}}"
    return _HOST_METRIC.sub(add, expr)


# The overview's box picker: the value is a regex (see INFERENCE above).
HOST_VAR = {
    "name": "host", "label": "Box", "type": "custom",
    "query": "inference : inference|,home : home",
    "current": {"text": "inference", "value": "inference|"},
    "options": [], "includeAll": False, "multi": False,
}


def row_title(text):
    return {"type": "row", "title": text, "collapsed": False, "panels": []}


def dashboard(uid, title, rows, tags=None, refresh="15s", time_from="now-6h", description="", scope=None, variables=None):
    """rows: list of (heading | None, [panel | (panel, width), ...], height).
    scope: a host matcher added to every node_*/container_* selector."""
    panels, y, pid = [], 0, 1
    for heading, items, height in rows:
        if heading:
            r = row_title(heading)
            r.update(id=pid, gridPos={"h": 1, "w": 24, "x": 0, "y": y})
            panels.append(r)
            pid += 1
            y += 1
        widths = [w if isinstance(i, tuple) else None for i in items for w in [i[1] if isinstance(i, tuple) else None]]
        fixed = sum(w for w in widths if w)
        free = [i for i, w in enumerate(widths) if not w]
        share = (24 - fixed) // max(len(free), 1)
        x = 0
        for idx, item in enumerate(items):
            panel = item[0] if isinstance(item, tuple) else item
            w = widths[idx] or share
            panel = dict(panel)
            if scope:
                panel["targets"] = [dict(t, expr=scoped(t["expr"], scope)) for t in panel.get("targets", [])]
            panel.update(id=pid, gridPos={"h": height, "w": w, "x": x, "y": y})
            panels.append(panel)
            pid += 1
            x += w
        y += height
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": tags or ["server"],
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 1,
        "refresh": refresh,
        "time": {"from": time_from, "to": "now"},
        "editable": True,
        "graphTooltip": 1,
        "links": [
            {"type": "dashboards", "title": "Server dashboards", "tags": ["server"], "asDropdown": True, "includeVars": False, "keepTime": True}
        ],
        "templating": {"list": variables or []},
        "annotations": {"list": []},
        "panels": panels,
    }


# ------------------------------------------------------------------ dashboards
CONTAINER = 'container_label_com_docker_compose_service!=""'
def cpu_by_container(over="2m"):
    return f'sum by (name) (rate(container_cpu_usage_seconds_total{{name!=""}}[{over}])) * 100'


def overview():
    return dashboard(
        "overview",
        "Overview",
        [
            (None, [
                stat("Targets up", 'sum(up)', desc="Scrape targets reporting healthy (llama needs --metrics)", thresholds=[(1, "green")], color_mode="background"),
                stat("GPU busy", 'node_drm_gpu_busy_percent', "percent", [(60, "yellow"), (90, "red")]),
                stat("VRAM used", '100 * node_drm_memory_vram_used_bytes / node_drm_memory_vram_size_bytes', "percent", [(80, "yellow"), (95, "red")]),
                stat("GPU temp", f'max(node_hwmon_temp_celsius{{{GPU}}})', "celsius", [(75, "yellow"), (90, "red")]),
                stat("GPU power", f'max(node_hwmon_power_average_watt{{{GPU}}})', "watt", decimals=0),
                stat("CPU", '100 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100', "percent", [(70, "yellow"), (90, "red")], decimals=0),
                stat("RAM used", '100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)', "percent", [(75, "yellow"), (90, "red")], decimals=0),
                stat("Disk used /", '100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})', "percent", [(70, "yellow"), (90, "red")], decimals=0),
            ], 4),
            ("Compute", [
                ts("GPU load and VRAM", [('node_drm_gpu_busy_percent', "GPU busy %"), ('100 * node_drm_memory_vram_used_bytes / node_drm_memory_vram_size_bytes', "VRAM used %")], "percent", minv=0, maxv=100),
                ts("CPU and memory", [('100 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100', "CPU %"), ('100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)', "RAM used %")], "percent", minv=0, maxv=100),
            ], 8),
            ("Services", [
                ts("Container CPU", [(cpu_by_container(), "{{name}}")], "percent", desc="% of one core, per container"),
                ts("Container memory", [('sum by (name) (container_memory_working_set_bytes{name!=""})', "{{name}}")], "bytes"),
            ], 8),
            ("Network and disk", [
                ts("Network (host)", [('sum(rate(node_network_receive_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[2m]))', "in"), ('sum(rate(node_network_transmit_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[2m]))', "out")], "Bps"),
                ts("Disk I/O", [('sum(rate(node_disk_read_bytes_total[2m]))', "read"), ('sum(rate(node_disk_written_bytes_total[2m]))', "write")], "Bps"),
                ts("Temperatures", [('node_hwmon_temp_celsius{chip!~"0000:02.*"} * on(chip, sensor) group_left(label) (node_hwmon_sensor_label or on(chip, sensor) node_hwmon_temp_celsius * 0)', "{{chip}} {{sensor}}")], "celsius"),
            ], 8),
        ],
        description="Either box at a glance (pick it above). Drill into the dashboards from the dropdown.",
        scope='host=~"$host"',
        variables=[HOST_VAR],
    )


def inference():
    return dashboard(
        "inference",
        "Inference Server",
        [
            (None, [
                stat("Generation speed", 'llamacpp:predicted_tokens_seconds', "short", desc="Average tokens/s while generating. " + LLAMA_HELP, decimals=1),
                stat("Prompt speed", 'llamacpp:prompt_tokens_seconds', "short", desc="Average prompt-processing tokens/s. " + LLAMA_HELP, decimals=0),
                stat("Requests running", 'llamacpp:requests_processing', "short", desc=LLAMA_HELP),
                stat("Requests waiting", 'llamacpp:requests_deferred', "short", [(1, "yellow"), (3, "red")], desc=LLAMA_HELP),
                stat("KV cache used", '100 * llamacpp:kv_cache_usage_ratio', "percent", [(70, "yellow"), (90, "red")], desc=LLAMA_HELP, decimals=0),
                stat("VRAM used", 'node_drm_memory_vram_used_bytes', "bytes"),
                stat("GPU temp", f'max(node_hwmon_temp_celsius{{{GPU}}})', "celsius", [(75, "yellow"), (90, "red")]),
                stat("GPU power", f'max(node_hwmon_power_average_watt{{{GPU}}})', "watt", decimals=0),
            ], 4),
            ("Throughput", [
                ts("Tokens per second", [('rate(llamacpp:prompt_tokens_total[1m])', "prompt in"), ('rate(llamacpp:tokens_predicted_total[1m])', "generated out")], "short", desc=LLAMA_HELP),
                ts("Requests and slots", [('llamacpp:requests_processing', "running"), ('llamacpp:requests_deferred', "waiting")], "short", desc=LLAMA_HELP, minv=0),
                ts("KV cache", [('100 * llamacpp:kv_cache_usage_ratio', "used %")], "percent", desc=LLAMA_HELP, minv=0, maxv=100),
            ], 8),
            ("GPU", [
                ts("GPU busy", [('node_drm_gpu_busy_percent', "busy %")], "percent", minv=0, maxv=100),
                ts("VRAM", [('node_drm_memory_vram_used_bytes', "used"), ('node_drm_memory_vram_size_bytes', "total")], "bytes", minv=0),
                ts("GPU clock", [(f'node_hwmon_freq_freq_mhz{{{GPU}}}', "{{sensor}} MHz")], "short"),
            ], 8),
            (None, [
                ts("GPU temperatures", [(f'node_hwmon_temp_celsius{{{GPU}}}', "{{sensor}}")], "celsius"),
                ts("GPU power", [(f'node_hwmon_power_average_watt{{{GPU}}}', "draw"), (f'node_hwmon_power_cap_watt{{{GPU}}}', "cap")], "watt", minv=0),
                ts("GPU fan", [(f'node_hwmon_fan_rpm{{{GPU}}}', "rpm")], "rpm", minv=0),
            ], 8),
            ("What Agent Studio sends to it", [
                ts("Requests to local models (last hour)", [('sum by (source) (studio_window_requests{window="1h",model=~"local.*"})', "{{source}}")], "short", desc="Rolling hour, by who asked (studio UI, scheduler, ...)"),
                ts("Local tokens (last hour)", [('sum(studio_window_input_tokens{window="1h",model=~"local.*"})', "input"), ('sum(studio_window_output_tokens{window="1h",model=~"local.*"})', "output")], "short"),
                ts("Cache share of input tokens", [('100 * sum(studio_window_cache_read_tokens{window="24h",model=~"local.*"}) / sum(studio_window_input_tokens{window="24h",model=~"local.*"})', "cached %")], "percent", desc="Share of prompt tokens served from llama.cpp's prompt cache", minv=0, maxv=100),
            ], 8),
        ],
        tags=["server", "inference"],
        description="llama.cpp on the R9700. Panels marked with --metrics fill in once llama-server is started with that flag.",
        scope=INFERENCE,
    )


def mongodb():
    return dashboard(
        "mongodb",
        "MongoDB",
        [
            (None, [
                stat("Up", 'mongodb_up', "short", [(1, "green")], color_mode="background", desc="1 = exporter can reach Mongo"),
                stat("Uptime", 'mongodb_instance_uptime_seconds', "s"),
                stat("Connections", 'mongodb_connections{state="current"}', "short", decimals=0),
                stat("Data size", 'sum(mongodb_dbstats_dataSize{database!~"admin|local|config"})', "bytes"),
                stat("Resident memory", 'mongodb_memory{type="resident"} * 1024 * 1024', "bytes"),
                stat("Container CPU", 'sum(rate(container_cpu_usage_seconds_total{name="mongo-mongo-1"}[2m])) * 100', "percent", decimals=1),
            ], 4),
            ("Activity", [
                ts("Operations per second", [('sum by (type) (rate(mongodb_op_counters_total[1m]))', "{{type}}")], "ops"),
                ts("Average operation latency", [('rate(mongodb_mongod_op_latencies_latency_total[2m]) / clamp_min(rate(mongodb_mongod_op_latencies_ops_total[2m]), 1) / 1000', "{{type}}")], "ms", desc="Per operation type"),
                ts("Connections", [('mongodb_connections{state="current"}', "current"), ('mongodb_connections{state="active"}', "active")], "short", minv=0),
            ], 8),
            ("Storage and memory", [
                ts("Database size", [('mongodb_dbstats_dataSize{database!~"admin|local|config"}', "{{database}} data"), ('mongodb_dbstats_indexSize{database!~"admin|local|config"}', "{{database}} index")], "bytes"),
                ts("Network", [('rate(mongodb_ss_network_bytesIn[1m])', "in"), ('rate(mongodb_ss_network_bytesOut[1m])', "out")], "Bps"),
                ts("Container memory", [('container_memory_working_set_bytes{name="mongo-mongo-1"}', "working set")], "bytes", minv=0),
            ], 8),
            ("Tables", [
                table("Databases", 'mongodb_dbstats_dataSize{database!~"admin|local|config"}', {"database": "Database", "Value": "Data size"}, unit="bytes"),
                table("Documents per database", 'mongodb_dbstats_objects{database!~"admin|local|config"}', {"database": "Database", "Value": "Documents"}),
            ], 8),
        ],
        tags=["server", "mongodb"],
        description="The Mongo 8 on home, shared by every studio.",
        scope=HOME,
    )


def studio():
    return dashboard(
        "studio",
        "Agent Studio",
        [
            (None, [
                stat("Requests (24h)", 'sum(studio_window_requests{window="24h"})', "short", decimals=0),
                stat("Errors (24h)", 'sum(studio_window_requests{window="24h",status="error"})', "short", [(1, "yellow"), (10, "red")], decimals=0),
                stat("Local model share (24h)", '100 * sum(studio_window_requests{window="24h",model=~"local.*"}) / sum(studio_window_requests{window="24h"})', "percent", decimals=0),
                stat("Cost (24h)", 'sum(studio_window_cost_usd{window="24h"})', "currencyUSD", decimals=2, desc="Reported API cost; local models cost nothing"),
                stat("Open sessions", 'studio_sessions{state="open"}', "short", decimals=0),
                stat("Live agents", 'studio_agents{kind="live"}', "short", decimals=0),
                stat("Last request", 'time() - max(studio_last_request_timestamp_seconds)', "s", desc="Seconds since the most recent request of any kind"),
                stat("Exporter", 'studio_exporter_up', "short", [(1, "green")], color_mode="background"),
            ], 4),
            ("Traffic", [
                ts("Requests in the last hour, by model", [('sum by (model) (studio_window_requests{window="1h"})', "{{model}}")], "short", stack=True),
                ts("Requests in the last hour, by source", [('sum by (source) (studio_window_requests{window="1h"})', "{{source}}")], "short", stack=True, desc="studio UI, scheduler, Telegram, ..."),
                ts("Errors in the last hour", [('sum by (model) (studio_window_requests{window="1h",status="error"})', "{{model}}")], "short", stack=True),
            ], 8),
            ("Tokens, cost, speed", [
                ts("Tokens in the last hour", [('studio_window_input_tokens{window="1h"}', "{{model}} in"), ('studio_window_output_tokens{window="1h"}', "{{model}} out")], "short"),
                ts("Cost in the last hour", [('studio_window_cost_usd{window="1h"}', "{{model}}")], "currencyUSD"),
                ts("Average request time (last hour)", [('studio_window_duration_seconds{window="1h"} / on(model) sum by (model) (studio_window_requests{window="1h"})', "{{model}}")], "s"),
            ], 8),
            ("Behaviour", [
                bargauge("Top tools (all time)", 'topk(15, sum by (tool) (studio_tool_calls_total))', "{{tool}}", desc="Tool calls made by agents"),
                bargauge("Data in the system", 'studio_domain_documents', "{{collection}}"),
                table("Scheduled jobs", 'studio_scheduled_job_next_run_timestamp_seconds * 1000', {"job": "Job", "Value": "Next run"}, unit="dateTimeAsLocal"),
            ], 8),
            ("Agent Studio containers", [
                ts("CPU", [('sum by (name) (rate(container_cpu_usage_seconds_total{name=~"studios-.*"}[2m])) * 100', "{{name}}")], "percent"),
                ts("Memory", [('sum by (name) (container_memory_working_set_bytes{name=~"studios-.*"})', "{{name}}")], "bytes"),
                ts("Sessions and open items", [('studio_sessions', "sessions {{state}}"), ('studio_open_items', "open items {{status}}")], "short"),
            ], 8),
        ],
        tags=["server", "agent-studio"],
        description="Built from what Agent Studio already records in Mongo (requests, tokens, cost, tools). Native app metrics can be added later.",
        scope=HOME,
    )


def agent_service():
    A = "agent_service_"
    return dashboard(
        "agent-service",
        "Agent Service (live)",
        [
            (None, [
                stat("Requests running", A + "requests_in_flight", "short", [(3, "yellow"), (8, "red")], decimals=0),
                stat("Connected clients", A + "sockets_connected", "short", decimals=0),
                stat("LLM calls / min", f'60 * sum(rate({A}llm_calls_total[5m]))', "short", decimals=1),
                stat("LLM error rate", f'100 * sum(rate({A}llm_calls_total{{outcome="error"}}[15m])) / clamp_min(sum(rate({A}llm_calls_total[15m])), 0.001)', "percent", [(1, "yellow"), (10, "red")], decimals=1),
                stat("Tool error rate", f'100 * sum(rate({A}tool_calls_total{{outcome="error"}}[15m])) / clamp_min(sum(rate({A}tool_calls_total[15m])), 0.001)', "percent", [(5, "yellow"), (20, "red")], decimals=1),
                stat("Event loop lag p99", f'{A}nodejs_eventloop_lag_p99_seconds * 1000', "ms", [(50, "yellow"), (250, "red")], decimals=0),
                stat("Heap used", f'{A}nodejs_heap_size_used_bytes', "bytes"),
                stat("Uptime", f'time() - {A}process_start_time_seconds', "s"),
            ], 4),
            ("LLM calls", [
                ts("Calls per minute by model", [(f'60 * sum by (model, outcome) (rate({A}llm_calls_total[3m]))', "{{model}} {{outcome}}")], "short", stack=True),
                ts("Call latency (p50 / p95)", [
                    (f'histogram_quantile(0.5, sum by (le, model) (rate({A}llm_call_duration_seconds_bucket[5m])))', "{{model}} p50"),
                    (f'histogram_quantile(0.95, sum by (le, model) (rate({A}llm_call_duration_seconds_bucket[5m])))', "{{model}} p95"),
                ], "s"),
                ts("Time to first token (p50 / p95)", [
                    (f'histogram_quantile(0.5, sum by (le, model) (rate({A}llm_time_to_first_token_seconds_bucket[5m])))', "{{model}} p50"),
                    (f'histogram_quantile(0.95, sum by (le, model) (rate({A}llm_time_to_first_token_seconds_bucket[5m])))', "{{model}} p95"),
                ], "s", desc="Streaming calls only"),
            ], 8),
            ("Tokens", [
                ts("Tokens per second", [(f'sum by (model, type) (rate({A}llm_tokens_total[3m]))', "{{model}} {{type}}")], "short"),
                ts("Prompt cache hit share", [(f'100 * sum by (model) (rate({A}llm_tokens_total{{type="cache_read"}}[10m])) / sum by (model) (rate({A}llm_tokens_total{{type=~"input|cache_read|cache_creation"}}[10m]))', "{{model}}")], "percent", minv=0, maxv=100, desc="Share of prompt tokens served from the provider's cache"),
                ts("Output tokens per LLM call", [(f'sum by (model) (rate({A}llm_tokens_total{{type="output"}}[10m])) / sum by (model) (rate({A}llm_calls_total{{outcome="success"}}[10m]))', "{{model}}")], "short"),
            ], 8),
            ("Tools", [
                bargauge("Most-used tools (last hour)", f'topk(12, sum by (tool) (increase({A}tool_calls_total[1h])))', "{{tool}}"),
                bargauge("Tool errors (last hour)", f'topk(12, sum by (tool) (increase({A}tool_calls_total{{outcome="error"}}[1h])) > 0)', "{{tool}}"),
                ts("Slowest tools (p95)", [(f'topk(6, histogram_quantile(0.95, sum by (le, tool) (rate({A}tool_call_duration_seconds_bucket[15m]))))', "{{tool}}")], "s"),
            ], 8),
            ("Requests", [
                ts("AI requests per minute", [(f'60 * sum by (source, status) (rate({A}ai_requests_total[5m]))', "{{source}} {{status}}")], "short", stack=True),
                ts("Request duration (p50 / p95)", [
                    (f'histogram_quantile(0.5, sum by (le, source) (rate({A}ai_request_duration_seconds_bucket[15m])))', "{{source}} p50"),
                    (f'histogram_quantile(0.95, sum by (le, source) (rate({A}ai_request_duration_seconds_bucket[15m])))', "{{source}} p95"),
                ], "s"),
                ts("Running requests and clients", [(A + "requests_in_flight", "requests running"), (A + "sockets_connected", "clients connected")], "short", minv=0),
            ], 8),
            ("Process", [
                ts("Event loop lag", [(f'{A}nodejs_eventloop_lag_p99_seconds * 1000', "p99"), (f'{A}nodejs_eventloop_lag_mean_seconds * 1000', "mean")], "ms", minv=0),
                ts("Memory", [(f'{A}nodejs_heap_size_used_bytes', "heap used"), (f'{A}process_resident_memory_bytes', "resident")], "bytes"),
                ts("CPU", [(f'rate({A}process_cpu_seconds_total[2m]) * 100', "cpu % of one core")], "percent", minv=0),
            ], 8),
        ],
        tags=["server", "agent-studio"],
        description="Native metrics from the agent-service (/metrics): what only the running service knows.",
    )


DASHBOARDS = [overview, inference, mongodb, studio, agent_service]


def verify(dash):
    """Run each panel's queries against Prometheus; return list of (panel, expr, problem)."""
    problems = []
    for p in dash["panels"]:
        for t in p.get("targets", []):
            url = "http://localhost:9090/api/v1/query?" + urllib.parse.urlencode({"query": t["expr"]})
            try:
                data = json.load(urllib.request.urlopen(url, timeout=15))
            except Exception as e:
                problems.append((p["title"], t["expr"], f"request failed: {e}"))
                continue
            if data.get("status") != "success":
                problems.append((p["title"], t["expr"], data.get("error", "error")))
            elif not data["data"]["result"]:
                problems.append((p["title"], t["expr"], "no data"))
    return problems


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    total_bad = 0
    for build in DASHBOARDS:
        d = build()
        with open(os.path.join(OUT, f"{d['uid']}.json"), "w") as f:
            json.dump(d, f, indent=1)
        print(f"wrote {d['uid']}.json ({len([p for p in d['panels'] if p['type'] != 'row'])} panels)")
        if "--verify" in sys.argv:
            for title, expr, why in verify(d):
                total_bad += 1
                print(f"   [{why}] {d['uid']} / {title}: {expr[:110]}")
    if "--verify" in sys.argv:
        print(f"{total_bad} query(ies) empty or failing")
