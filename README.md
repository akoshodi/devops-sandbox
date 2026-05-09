# DevOps Sandbox Platform (HNG14 Stage 5)

A self-service sandbox platform that creates short-lived app environments behind Nginx, monitors health, supports outage simulation, and auto-cleans expired environments.

## Architecture

```text
                           +-----------------------+
                           |       Client          |
                           | Browser / curl / API  |
                           +-----------+-----------+
                                       |
                                       v
                           +-----------------------+
                           |    Nginx Gateway      |
                           |  docker: sandbox-nginx|
                           +-----------+-----------+
                                       |
             dynamic /env/<id>/ routes |
                                       v
                   +-------------------+-------------------+
                   |                                       |
        +----------+----------+                 +----------+----------+
        | app-env-1 container |                 | app-env-N container |
        | label sandbox.env=..|                 | label sandbox.env=..|
        +----------+----------+                 +----------+----------+
                   |                                       |
                   +--------- per-env docker net ----------+

Host processes:
- platform/api.py           (Control API)
- monitor/health_poller.py  (health checks every 30s)
- platform/cleanup_daemon.sh (TTL cleanup every 60s)

Runtime data:
- env state files: envs/env-*.json
- logs: logs/<env_id>/app.log, health.log
- archived logs: logs/archived/<env_id>/
```

## Stack

- Docker + Docker Compose
- Nginx (containerized)
- Bash scripts for lifecycle and outage simulation
- Python 3 (stdlib API + health poller)

## Repo Layout

```text
devops-sandbox/
├── platform/          # create, destroy, cleanup, outage, API, shared helpers
├── nginx/             # nginx.conf + conf.d/ per-env route files
├── monitor/           # health poller
├── logs/              # runtime logs (gitignored)
├── envs/              # runtime state files (gitignored)
├── demo-app/          # sample app image used for each sandbox env
├── Makefile
└── README.md
```

## Prerequisites

- Linux VM with Docker + Docker Compose plugin
- Python 3.10+
- `make`

## Quick Start (Under 5 Commands)

1. `cp .env.example .env`
2. `make up`
3. `make create` (enter name + TTL when prompted)
4. Open printed env URL in browser
5. `curl http://localhost:5000/envs`

## Environment Lifecycle

### Create

`bash platform/create_env.sh <name> [ttl_minutes]`

What it does:
- Generates a unique env ID (`env-xxxxxx`)
- Creates dedicated Docker network (`sbx-<env_id>`)
- Starts demo app container with label `sandbox.env=<env_id>`
- Writes atomic state file: `envs/<env_id>.json`
- Creates Nginx route file: `nginx/conf.d/<env_id>.conf`
- Reloads Nginx via `docker exec sandbox-nginx nginx -s reload`
- Starts log shipping (`docker logs -f`) and stores PID

### Destroy

`bash platform/destroy_env.sh <env_id>`

What it does:
- Stops/removes all containers labeled with env ID
- Removes network
- Removes Nginx env config + reloads Nginx
- Kills log shipper process by PID
- Archives logs into `logs/archived/<env_id>/`
- Deletes env state file

## Auto Cleanup Daemon

`platform/cleanup_daemon.sh` checks `envs/*.json` every 60s.

For each env:
- Calculates expiration (`created_at_epoch + ttl_seconds`)
- Calls destroy script when expired
- Writes timestamped entries to `logs/cleanup.log`

Started in background by `make up` using `nohup`.

## Dynamic Routing (Nginx)

Main `nginx/nginx.conf` includes `conf.d/*.conf`.

Each created env gets a file like:

```nginx
location /env/env-abc123/ {
    rewrite ^/env/env-abc123/(.*)$ /$1 break;
    proxy_pass http://app-env-abc123:8000;
}
```

Network approach:
- Nginx runs on shared control network (`sandbox-control`)
- Each env has isolated network (`sbx-<env_id>`)
- Create script connects Nginx container to env network, allowing proxy by container name

## Log Shipping (Approach A)

At creation:
- `docker logs -f <container_id> >> logs/<env_id>/app.log &`
- PID stored at `envs/<env_id>.logship.pid`

At destroy:
- PID is terminated to avoid zombie log tail processes

Query logs:
- `make logs ENV=<env_id>`
- API: `GET /envs/<id>/logs` (last 100 lines)

## Health Monitoring

`monitor/health_poller.py` runs every 30s:
- Calls `<env_url>/health`
- Writes timestamp, status, latency to `logs/<env_id>/health.log`
- After 3 consecutive failures, marks env `status=degraded`
- Restores `status=running` on successful checks

API endpoint:
- `GET /envs/<id>/health` (last 10 entries)

## Outage Simulation

`bash platform/simulate_outage.sh --env <env_id> --mode <mode>`

Modes:
- `crash`: kills app container
- `pause`: pauses app container
- `network`: disconnects app container from env network
- `recover`: unpause/reconnect/start container
- `stress`: runs temporary CPU stress workload

Safety guard:
- Script refuses to target protected containers (`sandbox-nginx` / daemon role)

## Control API

Run by `make up` on `API_PORT` (default 5000).

Endpoints:
- `POST /envs` -> create env (`{"name":"demo","ttl_minutes":20}`)
- `GET /envs` -> list envs with TTL remaining
- `DELETE /envs/<id>` -> destroy env
- `GET /envs/<id>/logs` -> last 100 app log lines
- `GET /envs/<id>/health` -> last 10 health checks
- `POST /envs/<id>/outage` -> trigger outage (`{"mode":"crash"}`)

## Make Targets

- `make up` start Nginx + API + health poller + cleanup daemon
- `make down` stop everything and destroy all envs
- `make create` prompt for name/TTL and create env
- `make destroy ENV=...` destroy env
- `make logs ENV=...` show app logs
- `make health` show env health summary
- `make simulate ENV=... MODE=...` outage simulation
- `make clean` wipe runtime state and logs

## Full Demo Walkthrough

1. `make up`
2. `make create` (name: `demo`, TTL: `3`)
3. Visit printed URL and confirm app response
4. `make health` and verify env status is `running`
5. `make simulate ENV=<env_id> MODE=crash`
6. Wait up to 90 seconds, then check:
   - `make health` (`degraded` expected)
   - `curl http://localhost:5000/envs/<env_id>/health`
7. Recover: `make simulate ENV=<env_id> MODE=recover`
8. Confirm health returns to running
9. Wait for TTL expiry and inspect `logs/cleanup.log` for auto-destroy event

## Known Limitations

- API, health poller, and cleanup daemon run as host processes (not containerized)
- Stress mode installs `stress-ng` inside container on demand and may be slow
- No authentication or RBAC on control API
- No persistent metrics stack (Prometheus/Grafana optional, not included)

## Secrets

Place all secrets and overrides in `.env` (not committed).
