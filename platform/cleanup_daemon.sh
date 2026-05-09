#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

load_env
ensure_dirs

CLEANUP_LOG="$LOG_DIR/cleanup.log"
log_line "$CLEANUP_LOG" "cleanup daemon started"

while true; do
    NOW_EPOCH="$(date +%s)"

    shopt -s nullglob
    for state_file in "$ENV_DIR"/env-*.json; do
        [[ -f "$state_file" ]] || continue

        if ! INFO="$(python3 - "$state_file" "$NOW_EPOCH" <<'PY'
import json
import sys

path = sys.argv[1]
now = int(sys.argv[2])

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

expires = int(data["created_at_epoch"]) + int(data["ttl_seconds"])
expired = now > expires
print(data["id"])
print("1" if expired else "0")
print(expires)
PY
)"; then
            log_line "$CLEANUP_LOG" "failed to parse state file: $state_file"
            continue
        fi

        ENV_ID="$(echo "$INFO" | sed -n '1p')"
        EXPIRED="$(echo "$INFO" | sed -n '2p')"
        EXPIRES_AT="$(echo "$INFO" | sed -n '3p')"

        if [[ "$EXPIRED" == "1" ]]; then
            log_line "$CLEANUP_LOG" "destroying expired env=$ENV_ID expires_at=$EXPIRES_AT"
            if "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >>"$CLEANUP_LOG" 2>&1; then
                log_line "$CLEANUP_LOG" "destroyed env=$ENV_ID"
            else
                log_line "$CLEANUP_LOG" "destroy failed env=$ENV_ID"
            fi
        fi
    done
    shopt -u nullglob

    sleep 60
done
