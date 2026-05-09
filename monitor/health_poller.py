#!/usr/bin/env python3
import glob
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ENV_DIR = os.path.join(ROOT_DIR, "envs")
LOG_DIR = os.path.join(ROOT_DIR, "logs")
POLL_INTERVAL_SECONDS = 30
FAILURE_THRESHOLD = 3

failure_counts: dict[str, int] = {}


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_state_atomic(path: str, payload: dict) -> None:
    tmp_path = f"{path}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, path)


def poll_health(url: str) -> tuple[int, int]:
    start = time.perf_counter()
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            status = response.getcode()
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception:
        status = 0
    latency_ms = int((time.perf_counter() - start) * 1000)
    return status, latency_ms


def main() -> None:
    os.makedirs(LOG_DIR, exist_ok=True)

    while True:
        for state_file in glob.glob(os.path.join(ENV_DIR, "env-*.json")):
            try:
                with open(state_file, "r", encoding="utf-8") as f:
                    state = json.load(f)
            except FileNotFoundError:
                continue
            except json.JSONDecodeError:
                continue

            env_id = state.get("id")
            if not env_id:
                continue

            health_url = f"{state.get('url', '').rstrip('/')}/health"
            status, latency_ms = poll_health(health_url)

            env_log_dir = os.path.join(LOG_DIR, env_id)
            os.makedirs(env_log_dir, exist_ok=True)
            health_log = os.path.join(env_log_dir, "health.log")
            with open(health_log, "a", encoding="utf-8") as f:
                f.write(f"{now_iso()} status={status} latency_ms={latency_ms}\n")

            if 200 <= status < 400:
                failure_counts[env_id] = 0
                if state.get("status") == "degraded":
                    state["status"] = "running"
                    write_state_atomic(state_file, state)
            else:
                failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
                if failure_counts[env_id] >= FAILURE_THRESHOLD and state.get("status") != "degraded":
                    state["status"] = "degraded"
                    write_state_atomic(state_file, state)
                    print(f"[{now_iso()}] warning: env {env_id} marked degraded")

        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
