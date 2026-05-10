#!/usr/bin/env python3
import glob
import json
import os
import sys
import time

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ENV_DIR = os.path.join(ROOT_DIR, "envs")

now = int(time.time())
env_files = sorted(glob.glob(os.path.join(ENV_DIR, "env-*.json")))

if not env_files:
    sys.exit(0)

had_error = False
for path in env_files:
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        env_id = state.get("id", "unknown")
        status = state.get("status", "unknown")
        created = int(state.get("created_at_epoch", 0))
        ttl = int(state.get("ttl_seconds", 0))
        remaining = max(0, created + ttl - now)
        print(f"{env_id} status={status} ttl_remaining={remaining}s")
    except Exception as e:
        print(f"error: failed to read {path}: {e}", file=sys.stderr)
        had_error = True

sys.exit(1 if had_error else 0)
