#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$ROOT_DIR/envs"
LOG_DIR="$ROOT_DIR/logs"
NGINX_CONF_DIR="$ROOT_DIR/nginx/conf.d"

load_env() {
    if [[ -f "$ROOT_DIR/.env" ]]; then
        # shellcheck disable=SC1091
        source "$ROOT_DIR/.env"
    fi

    : "${SANDBOX_HOST:=localhost}"
    : "${NGINX_HTTP_PORT:=8080}"
    : "${DEFAULT_TTL_MINUTES:=30}"
    : "${API_PORT:=5000}"

    export SANDBOX_HOST NGINX_HTTP_PORT DEFAULT_TTL_MINUTES API_PORT
}

timestamp_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_dirs() {
    mkdir -p "$ENV_DIR" "$LOG_DIR" "$LOG_DIR/archived" "$NGINX_CONF_DIR"
}

is_container_running() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -qx "$name"
}

reload_nginx() {
    if is_container_running "sandbox-nginx"; then
        docker exec sandbox-nginx nginx -s reload >/dev/null
    else
        echo "sandbox-nginx container is not running" >&2
        return 1
    fi
}

random_suffix() {
    tr -dc 'a-z0-9' </dev/urandom | head -c 6
}

read_json_field() {
    local file="$1"
    local field="$2"
    python3 - "$file" "$field" <<'PY'
import json
import sys

path = sys.argv[1]
field = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data
for piece in field.split("."):
    value = value[piece]
print(value)
PY
}

write_state_atomically() {
    local target_file="$1"
    local payload="$2"
    local tmp_file

    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")"
    printf '%s\n' "$payload" >"$tmp_file"
    mv "$tmp_file" "$target_file"
}

log_line() {
    local file="$1"
    local message="$2"
    printf '[%s] %s\n' "$(timestamp_utc)" "$message" >>"$file"
}
