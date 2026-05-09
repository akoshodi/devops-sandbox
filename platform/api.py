#!/usr/bin/env python3
import glob
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ENV_DIR = os.path.join(ROOT_DIR, "envs")
LOG_DIR = os.path.join(ROOT_DIR, "logs")
PLATFORM_DIR = os.path.join(ROOT_DIR, "platform")


def run_cmd(args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=ROOT_DIR, capture_output=True, text=True, check=False)


def load_state(env_id: str) -> dict | None:
    path = os.path.join(ENV_DIR, f"{env_id}.json")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def tail_lines(path: str, count: int) -> list[str]:
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return [line.rstrip("\n") for line in f.readlines()[-count:]]


class Handler(BaseHTTPRequestHandler):
    def _json_response(self, status: int, payload: dict | list) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            return {}
        raw = self.rfile.read(content_length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        payload = self._read_json_body()

        if path == "/envs":
            name = payload.get("name")
            ttl_minutes = payload.get("ttl_minutes")
            if not name:
                self._json_response(400, {"error": "name is required"})
                return

            args = [os.path.join(PLATFORM_DIR, "create_env.sh"), "--json", str(name)]
            if ttl_minutes is not None:
                args.append(str(ttl_minutes))

            result = run_cmd(args)
            if result.returncode != 0:
                self._json_response(500, {"error": result.stderr.strip() or "create failed"})
                return

            self._json_response(200, json.loads(result.stdout.strip()))
            return

        parts = [p for p in path.split("/") if p]
        if len(parts) == 3 and parts[0] == "envs" and parts[2] == "outage":
            env_id = parts[1]
            if load_state(env_id) is None:
                self._json_response(404, {"error": "env not found"})
                return

            mode = payload.get("mode")
            if not mode:
                self._json_response(400, {"error": "mode is required"})
                return

            result = run_cmd([os.path.join(PLATFORM_DIR, "simulate_outage.sh"), "--env", env_id, "--mode", str(mode)])
            if result.returncode != 0:
                self._json_response(500, {"error": result.stderr.strip() or "outage failed"})
                return

            self._json_response(200, {"env_id": env_id, "mode": mode, "message": "ok"})
            return

        self._json_response(404, {"error": "not found"})

    def do_GET(self) -> None:
        path = urlparse(self.path).path

        if path == "/envs":
            now = int(time.time())
            envs = []
            for state_file in glob.glob(os.path.join(ENV_DIR, "env-*.json")):
                with open(state_file, "r", encoding="utf-8") as f:
                    state = json.load(f)
                expires = int(state["created_at_epoch"]) + int(state["ttl_seconds"])
                state["ttl_remaining_seconds"] = max(0, expires - now)
                envs.append(state)
            envs.sort(key=lambda item: item["created_at_epoch"])
            self._json_response(200, envs)
            return

        parts = [p for p in path.split("/") if p]
        if len(parts) == 3 and parts[0] == "envs" and parts[2] in {"logs", "health"}:
            env_id = parts[1]
            if parts[2] == "logs":
                payload = {"env_id": env_id, "lines": tail_lines(os.path.join(LOG_DIR, env_id, "app.log"), 100)}
                self._json_response(200, payload)
                return
            payload = {"env_id": env_id, "lines": tail_lines(os.path.join(LOG_DIR, env_id, "health.log"), 10)}
            self._json_response(200, payload)
            return

        self._json_response(404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        parts = [p for p in path.split("/") if p]
        if len(parts) == 2 and parts[0] == "envs":
            env_id = parts[1]
            result = run_cmd([os.path.join(PLATFORM_DIR, "destroy_env.sh"), env_id])
            if result.returncode != 0:
                self._json_response(500, {"error": result.stderr.strip() or "destroy failed"})
                return
            self._json_response(200, {"env_id": env_id, "message": "destroyed"})
            return

        self._json_response(404, {"error": "not found"})


if __name__ == "__main__":
    api_port = int(os.getenv("API_PORT", "5000"))
    server = ThreadingHTTPServer(("0.0.0.0", api_port), Handler)
    server.serve_forever()
