#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    echo "Usage: $0 <env_id>"
    exit 1
}

load_env
ensure_dirs

ENV_ID="${1:-}"
[[ -n "$ENV_ID" ]] || usage

STATE_FILE="$ENV_DIR/$ENV_ID.json"
PID_FILE="$ENV_DIR/$ENV_ID.logship.pid"
NGINX_ENV_CONF="$NGINX_CONF_DIR/$ENV_ID.conf"
ENV_LOG_DIR="$LOG_DIR/$ENV_ID"
ARCHIVE_DIR="$LOG_DIR/archived/$ENV_ID"

NETWORK_NAME=""
if [[ -f "$STATE_FILE" ]]; then
    NETWORK_NAME="$(read_json_field "$STATE_FILE" "network")"
fi

CONTAINERS="$(docker ps -aq --filter "label=sandbox.env=$ENV_ID")"
if [[ -n "$CONTAINERS" ]]; then
    while read -r cid; do
        [[ -n "$cid" ]] || continue
        docker rm -f "$cid" >/dev/null 2>&1 || true
    done <<<"$CONTAINERS"
fi

if [[ -f "$PID_FILE" ]]; then
    LOG_PID="$(cat "$PID_FILE" || true)"
    if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
        kill "$LOG_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE"
fi

if [[ -n "$NETWORK_NAME" ]]; then
    docker network disconnect -f "$NETWORK_NAME" sandbox-nginx >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
fi

if [[ -f "$NGINX_ENV_CONF" ]]; then
    rm -f "$NGINX_ENV_CONF"
    reload_nginx || true
fi

if [[ -d "$ENV_LOG_DIR" ]]; then
    mkdir -p "$ARCHIVE_DIR"
    find "$ENV_LOG_DIR" -mindepth 1 -maxdepth 1 -exec mv {} "$ARCHIVE_DIR/" \;
    rmdir "$ENV_LOG_DIR" 2>/dev/null || true
fi

rm -f "$ENV_DIR/$ENV_ID.outage"
rm -f "$STATE_FILE"

echo "ENV_ID=$ENV_ID"
echo "Environment destroyed successfully"
