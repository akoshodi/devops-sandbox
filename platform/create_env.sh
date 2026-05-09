#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    echo "Usage: $0 [--json] <name> [ttl_minutes]"
    exit 1
}

load_env
ensure_dirs

OUTPUT_JSON=false
if [[ "${1:-}" == "--json" ]]; then
    OUTPUT_JSON=true
    shift
fi

NAME="${1:-}"
TTL_MINUTES="${2:-$DEFAULT_TTL_MINUTES}"

[[ -n "$NAME" ]] || usage
[[ "$TTL_MINUTES" =~ ^[0-9]+$ ]] || { echo "ttl_minutes must be an integer" >&2; exit 1; }

if ! is_container_running "sandbox-nginx"; then
    echo "sandbox-nginx is not running. Start platform first with make up." >&2
    exit 1
fi

if ! docker image inspect sandbox-demo-app:latest >/dev/null 2>&1; then
    docker build -t sandbox-demo-app:latest "$ROOT_DIR/demo-app" >/dev/null
fi

ENV_ID="env-$(random_suffix)"
NETWORK_NAME="sbx-$ENV_ID"
CONTAINER_NAME="app-$ENV_ID"
STATE_FILE="$ENV_DIR/$ENV_ID.json"
ENV_LOG_DIR="$LOG_DIR/$ENV_ID"
NGINX_ENV_CONF="$NGINX_CONF_DIR/$ENV_ID.conf"
CREATED_AT_EPOCH="$(date +%s)"
CREATED_AT_ISO="$(timestamp_utc)"
TTL_SECONDS="$((TTL_MINUTES * 60))"
URL="http://$SANDBOX_HOST:$NGINX_HTTP_PORT/env/$ENV_ID/"

mkdir -p "$ENV_LOG_DIR"

docker network create "$NETWORK_NAME" >/dev/null

cleanup_on_failure() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    rm -f "$NGINX_ENV_CONF"
}
trap cleanup_on_failure ERR

CONTAINER_ID="$(docker run -d \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.role=app" \
    sandbox-demo-app:latest)"

docker network connect "$NETWORK_NAME" sandbox-nginx >/dev/null 2>&1 || true

cat >"$NGINX_ENV_CONF" <<EOF
location /env/$ENV_ID/ {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    rewrite ^/env/$ENV_ID/(.*)$ /\$1 break;
    proxy_pass http://$CONTAINER_NAME:8000;
}
EOF

reload_nginx

docker logs -f "$CONTAINER_ID" >>"$ENV_LOG_DIR/app.log" 2>&1 &
LOG_SHIP_PID="$!"
echo "$LOG_SHIP_PID" >"$ENV_DIR/$ENV_ID.logship.pid"

STATE_JSON="$(python3 - <<PY
import json
print(json.dumps({
    "id": "$ENV_ID",
    "name": "$NAME",
    "created_at": "$CREATED_AT_ISO",
    "created_at_epoch": int($CREATED_AT_EPOCH),
    "ttl_seconds": int($TTL_SECONDS),
    "status": "running",
    "url": "$URL",
    "network": "$NETWORK_NAME",
    "container_name": "$CONTAINER_NAME",
    "container_id": "$CONTAINER_ID",
    "log_ship_pid": int($LOG_SHIP_PID)
}, indent=2))
PY
)"

write_state_atomically "$STATE_FILE" "$STATE_JSON"
trap - ERR

if [[ "$OUTPUT_JSON" == "true" ]]; then
    python3 - "$STATE_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.dumps(json.load(f)))
PY
else
    echo "ENV_ID=$ENV_ID"
    echo "URL=$URL"
    echo "TTL_MINUTES=$TTL_MINUTES"
    echo "Environment created successfully"
fi
