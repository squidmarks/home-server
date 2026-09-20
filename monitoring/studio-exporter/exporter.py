"""Prometheus exporter for Agent Studio, built from what it already records in Mongo.

Read-only. Counters are all-time totals recomputed from the collections, so
Prometheus' rate()/increase() work on them; if documents are ever deleted the
counter just resets, which Prometheus handles. Add a metric by adding a block
in collect().
"""
import datetime
import os
import time

from prometheus_client import start_http_server
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily, REGISTRY
from pymongo import MongoClient

client = MongoClient(os.environ["MONGO_URI"], serverSelectionTimeoutMS=5000)
db = client[os.environ.get("MONGO_DB", "witness_deployed")]

CACHE_SECONDS = 10
_cache = {"at": 0.0, "families": []}


def model_of(doc_id):
    return doc_id.get("model") or "unknown"


class StudioCollector:
    def collect(self):
        now = time.time()
        if now - _cache["at"] < CACHE_SECONDS:
            yield from _cache["families"]
            return
        try:
            families = list(self._collect())
        except Exception as exc:  # keep serving the last good data
            print("collect failed:", exc, flush=True)
            yield from _cache["families"]
            up = GaugeMetricFamily("studio_exporter_up", "Exporter could query Mongo")
            up.add_metric([], 0)
            yield up
            return
        up = GaugeMetricFamily("studio_exporter_up", "Exporter could query Mongo")
        up.add_metric([], 1)
        families.append(up)
        _cache.update(at=now, families=families)
        yield from families

    def _collect(self):
        # ---- LLM requests: count / tokens / cost / duration by model, source, status
        req = CounterMetricFamily("studio_requests", "AI requests", labels=["model", "source", "status"])
        dur = CounterMetricFamily("studio_request_duration_seconds", "Total request duration", labels=["model", "source"])
        tin = CounterMetricFamily("studio_input_tokens", "Input tokens", labels=["model"])
        tout = CounterMetricFamily("studio_output_tokens", "Output tokens", labels=["model"])
        tcache = CounterMetricFamily("studio_cache_read_tokens", "Cache-read (cached) input tokens", labels=["model"])
        cost = CounterMetricFamily("studio_cost_usd", "Reported cost in USD", labels=["model"])
        tools_total = CounterMetricFamily("studio_request_tool_calls", "Tool calls made", labels=["model"])
        by_model = {}
        pipeline = [
            {
                "$group": {
                    "_id": {
                        "model": {"$arrayElemAt": ["$metadata.models", 0]},
                        "source": {"$ifNull": ["$source", "unknown"]},
                        "status": {"$ifNull": ["$status", "unknown"]},
                    },
                    "n": {"$sum": 1},
                    "duration": {"$sum": {"$ifNull": ["$metadata.duration", {"$ifNull": ["$metadata.durationMs", 0]}]}},
                    "input": {"$sum": {"$ifNull": ["$metadata.tokens.input", 0]}},
                    "output": {"$sum": {"$ifNull": ["$metadata.tokens.output", 0]}},
                    "cache": {"$sum": {"$ifNull": ["$metadata.tokens.cacheReadTokens", 0]}},
                    "cost": {"$sum": {"$convert": {"input": {"$ifNull": ["$metadata.cost.total", "$metadata.cost"]}, "to": "double", "onError": 0, "onNull": 0}}},
                    "tools": {"$sum": {"$ifNull": ["$metadata.totalToolCalls", 0]}},
                }
            }
        ]
        dur_by = {}
        for g in db.ai_requests.aggregate(pipeline):
            k = g["_id"]
            m = model_of(k)
            req.add_metric([m, k["source"], k["status"]], g["n"])
            dur_by[(m, k["source"])] = dur_by.get((m, k["source"]), 0) + g["duration"] / 1000.0
            agg = by_model.setdefault(m, dict(input=0, output=0, cache=0, cost=0.0, tools=0))
            for f in ("input", "output", "cache", "tools"):
                agg[f] += g[f]
            agg["cost"] += g["cost"]
        for (m, s), v in dur_by.items():
            dur.add_metric([m, s], v)
        for m, a in by_model.items():
            tin.add_metric([m], a["input"])
            tout.add_metric([m], a["output"])
            tcache.add_metric([m], a["cache"])
            cost.add_metric([m], a["cost"])
            tools_total.add_metric([m], a["tools"])
        yield from (req, dur, tin, tout, tcache, cost, tools_total)

        last = GaugeMetricFamily("studio_last_request_timestamp_seconds", "Time of the most recent request", labels=["source"])
        for g in db.ai_requests.aggregate([{"$group": {"_id": {"$ifNull": ["$source", "unknown"]}, "t": {"$max": "$createdAt"}}}]):
            if g["t"]:
                last.add_metric([g["_id"]], g["t"].timestamp())
        yield last

        # ---- rolling windows computed straight from Mongo, so they are exact from the
        # first scrape (Prometheus increase() needs a full window of history).
        w_req = GaugeMetricFamily("studio_window_requests", "Requests in the rolling window", labels=["window", "model", "source", "status"])
        w_in = GaugeMetricFamily("studio_window_input_tokens", "Input tokens in the rolling window", labels=["window", "model"])
        w_out = GaugeMetricFamily("studio_window_output_tokens", "Output tokens in the rolling window", labels=["window", "model"])
        w_cache = GaugeMetricFamily("studio_window_cache_read_tokens", "Cached input tokens in the rolling window", labels=["window", "model"])
        w_cost = GaugeMetricFamily("studio_window_cost_usd", "Cost in the rolling window", labels=["window", "model"])
        w_dur = GaugeMetricFamily("studio_window_duration_seconds", "Total request time in the rolling window", labels=["window", "model"])
        now_dt = datetime.datetime.now(datetime.timezone.utc)
        for label, hours in (("1h", 1), ("24h", 24), ("7d", 24 * 7)):
            since = now_dt - datetime.timedelta(hours=hours)
            per_model = {}
            for g in db.ai_requests.aggregate([{"$match": {"createdAt": {"$gte": since}}}, *pipeline]):
                k = g["_id"]
                m = model_of(k)
                w_req.add_metric([label, m, k["source"], k["status"]], g["n"])
                a = per_model.setdefault(m, dict(input=0, output=0, cache=0, cost=0.0, dur=0.0))
                a["input"] += g["input"]
                a["output"] += g["output"]
                a["cache"] += g["cache"]
                a["cost"] += g["cost"]
                a["dur"] += g["duration"] / 1000.0
            for m, a in per_model.items():
                w_in.add_metric([label, m], a["input"])
                w_out.add_metric([label, m], a["output"])
                w_cache.add_metric([label, m], a["cache"])
                w_cost.add_metric([label, m], a["cost"])
                w_dur.add_metric([label, m], a["dur"])
        yield from (w_req, w_in, w_out, w_cache, w_cost, w_dur)

        # ---- tool usage by name
        tool_calls = CounterMetricFamily("studio_tool_calls", "Tool calls by tool", labels=["tool"])
        for g in db.ai_requests.aggregate(
            [
                {"$unwind": "$turns"},
                {"$unwind": "$turns.toolCalls"},
                {"$group": {"_id": "$turns.toolCalls.name", "n": {"$sum": 1}}},
            ]
        ):
            tool_calls.add_metric([str(g["_id"])], g["n"])
        yield tool_calls

        # ---- sessions, agents, and domain data (simple gauges; easy to extend)
        sessions = GaugeMetricFamily("studio_sessions", "AI sessions by state", labels=["state"])
        for g in db.aisessions.aggregate([{"$group": {"_id": {"$ifNull": ["$state", "unknown"]}, "n": {"$sum": 1}}}]):
            sessions.add_metric([str(g["_id"])], g["n"])
        yield sessions

        agents = GaugeMetricFamily("studio_agents", "User agents (non-archived) by version kind", labels=["kind"])
        agents.add_metric(["draft"], db.useragents.count_documents({"archived": {"$ne": True}, "version": "draft"}))
        agents.add_metric(["live"], db.useragents.count_documents({"archived": {"$ne": True}, "version": {"$ne": "draft"}}))
        yield agents

        domain = GaugeMetricFamily("studio_domain_documents", "Documents in Witness domain collections", labels=["collection"])
        for coll in (
            "classified_transactions",
            "tiller_transaction_mirror",
            "amazon_order_items",
            "merchant_lookup",
            "agent_memories",
            "missions",
            "taxonomy_nodes",
        ):
            domain.add_metric([coll], db[coll].estimated_document_count())
        yield domain

        open_items = GaugeMetricFamily("studio_open_items", "Open items by status", labels=["status"])
        for g in db.open_items.aggregate([{"$group": {"_id": {"$ifNull": ["$status", "unknown"]}, "n": {"$sum": 1}}}]):
            open_items.add_metric([str(g["_id"])], g["n"])
        yield open_items

        jobs = GaugeMetricFamily("studio_scheduled_job_next_run_timestamp_seconds", "Next scheduled run", labels=["job"])
        for j in db.scheduled_jobs.find({}, {"name": 1, "nextRunAt": 1}):
            nxt = j.get("nextRunAt")
            if hasattr(nxt, "timestamp"):
                jobs.add_metric([j.get("name", "?")], nxt.timestamp())
        yield jobs


if __name__ == "__main__":
    REGISTRY.register(StudioCollector())
    start_http_server(9500)
    print("studio-exporter listening on :9500", flush=True)
    while True:
        time.sleep(3600)
