#!/usr/bin/env python3
import glob
import json
import os
import subprocess
import time
from flask import Flask, jsonify, request

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ENV_DIR = os.path.join(ROOT_DIR, "envs")
LOG_DIR = os.path.join(ROOT_DIR, "logs")
PLATFORM_DIR = os.path.join(ROOT_DIR, "platform")

app = Flask(__name__)


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
        return f.readlines()[-count:]


@app.post("/envs")
def create_env():
    payload = request.get_json(silent=True) or {}
    name = payload.get("name")
    ttl_minutes = payload.get("ttl_minutes")
    if not name:
        return jsonify({"error": "name is required"}), 400

    args = [os.path.join(PLATFORM_DIR, "create_env.sh"), "--json", name]
    if ttl_minutes is not None:
        args.append(str(ttl_minutes))

    result = run_cmd(args)
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip() or "create failed"}), 500

    return jsonify(json.loads(result.stdout.strip()))


@app.get("/envs")
def list_envs():
    now = int(time.time())
    envs = []
    for state_file in glob.glob(os.path.join(ENV_DIR, "env-*.json")):
        with open(state_file, "r", encoding="utf-8") as f:
            state = json.load(f)
        expires = int(state["created_at_epoch"]) + int(state["ttl_seconds"])
        state["ttl_remaining_seconds"] = max(0, expires - now)
        envs.append(state)
    envs.sort(key=lambda item: item["created_at_epoch"])
    return jsonify(envs)


@app.delete("/envs/<env_id>")
def destroy_env(env_id: str):
    result = run_cmd([os.path.join(PLATFORM_DIR, "destroy_env.sh"), env_id])
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip() or "destroy failed"}), 500
    return jsonify({"env_id": env_id, "message": "destroyed"})


@app.get("/envs/<env_id>/logs")
def env_logs(env_id: str):
    log_path = os.path.join(LOG_DIR, env_id, "app.log")
    return jsonify({"env_id": env_id, "lines": [line.rstrip("\n") for line in tail_lines(log_path, 100)]})


@app.get("/envs/<env_id>/health")
def env_health(env_id: str):
    health_path = os.path.join(LOG_DIR, env_id, "health.log")
    return jsonify({"env_id": env_id, "lines": [line.rstrip("\n") for line in tail_lines(health_path, 10)]})


@app.post("/envs/<env_id>/outage")
def outage(env_id: str):
    state = load_state(env_id)
    if state is None:
        return jsonify({"error": "env not found"}), 404

    payload = request.get_json(silent=True) or {}
    mode = payload.get("mode")
    if not mode:
        return jsonify({"error": "mode is required"}), 400

    result = run_cmd([os.path.join(PLATFORM_DIR, "simulate_outage.sh"), "--env", env_id, "--mode", mode])
    if result.returncode != 0:
        return jsonify({"error": result.stderr.strip() or "outage failed"}), 500
    return jsonify({"env_id": env_id, "mode": mode, "message": "ok"})


if __name__ == "__main__":
    api_port = int(os.getenv("API_PORT", "5000"))
    app.run(host="0.0.0.0", port=api_port)
