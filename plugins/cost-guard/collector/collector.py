#!/usr/bin/env python3
"""
Tiny central collector for cost-guard session records.

Zero dependencies (Python 3.8+ stdlib only).

Endpoints:
  POST /            -> append one session record (JSON body) to sessions.jsonl
  GET  /stats       -> aggregate stats (per user and totals)
  GET  /health      -> "ok"

Run:
  python3 collector.py --port 8787 --data-dir ./data

Point the hooks at it:
  export COST_GUARD_COLLECTOR_URL=http://your-host:8787/
"""
import argparse
import json
import os
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA_DIR = "./data"


def data_file() -> str:
    return os.path.join(DATA_DIR, "sessions.jsonl")


def load_records():
    path = data_file()
    if not os.path.exists(path):
        return []
    records = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def build_stats():
    records = load_records()
    totals = {
        "sessions": 0,
        "toolCalls": 0,
        "denials": 0,
        "loops": 0,
        "wastedSessions": 0,  # ended with error/timeout/abort
        "totalDurationSec": 0,
        "outputBytes": 0,
    }
    per_user = defaultdict(lambda: {
        "sessions": 0, "toolCalls": 0, "denials": 0,
        "loops": 0, "wastedSessions": 0, "totalDurationSec": 0,
    })

    for r in records:
        user = r.get("gitEmail") or r.get("user") or "unknown"
        u = per_user[user]
        totals["sessions"] += 1
        u["sessions"] += 1
        for key, field in (("toolCalls", "count"), ("denials", "denials"),
                           ("loops", "loops"), ("totalDurationSec", "durationSec")):
            val = int(r.get(field) or 0)
            totals[key] += val
            u[key] += val
        totals["outputBytes"] += int(r.get("outputBytes") or 0)
        if r.get("endReason") in ("error", "timeout", "abort"):
            totals["wastedSessions"] += 1
            u["wastedSessions"] += 1

    if totals["sessions"]:
        totals["avgToolCallsPerSession"] = round(totals["toolCalls"] / totals["sessions"], 1)
        totals["avgDurationSec"] = round(totals["totalDurationSec"] / totals["sessions"], 1)

    return {"totals": totals, "perUser": dict(per_user)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: str, ctype: str = "application/json"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/stats"):
            self._send(200, json.dumps(build_stats(), indent=2))
        elif self.path.startswith("/health"):
            self._send(200, "ok", "text/plain")
        else:
            self._send(404, '{"error":"not found"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > 1_000_000:
            self._send(400, '{"error":"bad content length"}')
            return
        raw = self.rfile.read(length)
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            self._send(400, '{"error":"invalid json"}')
            return
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(data_file(), "a", encoding="utf-8") as f:
            f.write(json.dumps(record, separators=(",", ":")) + "\n")
        self._send(200, '{"status":"stored"}')

    def log_message(self, fmt, *args):  # quiet by default
        pass


def main():
    global DATA_DIR
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--data-dir", default="./data")
    args = parser.parse_args()
    DATA_DIR = args.data_dir
    os.makedirs(DATA_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"cost-guard collector listening on :{args.port}, data in {DATA_DIR}")
    server.serve_forever()


if __name__ == "__main__":
    main()
