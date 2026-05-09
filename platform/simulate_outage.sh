#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
    echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>"
    exit 1
}

load_env
ensure_dirs

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_ID="${2:-}"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$ENV_ID" && -n "$MODE" ]] || usage

STATE_FILE="$ENV_DIR/$ENV_ID.json"
[[ -f "$STATE_FILE" ]] || { echo "unknown env: $ENV_ID" >&2; exit 1; }

CONTAINER_ID="$(docker ps -aq --filter "label=sandbox.env=$ENV_ID" | head -n1)"
[[ -n "$CONTAINER_ID" ]] || { echo "no container found for $ENV_ID" >&2; exit 1; }

TARGET_NAME="$(docker inspect --format '{{.Name}}' "$CONTAINER_ID" | sed 's#^/##')"
TARGET_ROLE="$(docker inspect --format '{{ index .Config.Labels "sandbox.role" }}' "$CONTAINER_ID")"

if [[ "$TARGET_NAME" == "sandbox-nginx" || "$TARGET_ROLE" == "daemon" ]]; then
    echo "refusing to simulate outage on protected container" >&2
    exit 1
fi

NETWORK_NAME="$(read_json_field "$STATE_FILE" "network")"
OUTAGE_FILE="$ENV_DIR/$ENV_ID.outage"

case "$MODE" in
    crash)
        docker kill "$CONTAINER_ID" >/dev/null
        echo "crash" >"$OUTAGE_FILE"
        ;;
    pause)
        docker pause "$CONTAINER_ID" >/dev/null
        echo "pause" >"$OUTAGE_FILE"
        ;;
    network)
        docker network disconnect -f "$NETWORK_NAME" "$CONTAINER_ID" >/dev/null
        echo "network" >"$OUTAGE_FILE"
        ;;
    recover)
        LAST_MODE=""
        [[ -f "$OUTAGE_FILE" ]] && LAST_MODE="$(cat "$OUTAGE_FILE")"

        if [[ "$LAST_MODE" == "pause" ]]; then
            docker unpause "$CONTAINER_ID" >/dev/null 2>&1 || true
        fi

        if [[ "$LAST_MODE" == "network" ]]; then
            docker network connect "$NETWORK_NAME" "$CONTAINER_ID" >/dev/null 2>&1 || true
        fi

        docker start "$CONTAINER_ID" >/dev/null 2>&1 || true
        rm -f "$OUTAGE_FILE"
        ;;
    stress)
        docker exec "$CONTAINER_ID" sh -lc 'command -v stress-ng >/dev/null 2>&1 || (apt-get update && apt-get install -y stress-ng >/dev/null 2>&1); stress-ng --cpu 1 --timeout 45s' >/dev/null 2>&1 &
        echo "stress" >"$OUTAGE_FILE"
        ;;
    *)
        usage
        ;;
esac

echo "ENV_ID=$ENV_ID"
echo "MODE=$MODE"
echo "Outage simulation command completed"
