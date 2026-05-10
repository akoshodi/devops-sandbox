# Ubuntu Server Deployment Guide

Complete step-by-step instructions for deploying the DevOps Sandbox Platform on a fresh Ubuntu server.

## Prerequisites

### System Requirements

- **OS:** Ubuntu 22.04 LTS or later (20.04+ supported)
- **CPU:** 2+ cores recommended
- **RAM:** 2GB minimum (4GB+ recommended for multiple concurrent environments)
- **Disk:** 10GB+ free space (grows with archived logs)
- **Network:** Internet access to pull Docker images

### Pre-Deployment Checklist

- [ ] Sudo access on the target server
- [ ] Internet connectivity
- [ ] SSH access configured (if remote)

---

## Step 1: Update System & Install Dependencies

```bash
sudo apt-get update
sudo apt-get upgrade -y

# Install Docker (all-in-one)
sudo apt-get install -y docker.io docker-compose-plugin

# Install build tools and utilities
sudo apt-get install -y \
  git \
  curl \
  wget \
  make \
  python3 \
  python3-venv \
  jq

# Verify Docker installation
docker --version
docker compose version
```

### Add Current User to Docker Group (avoid sudo)

```bash
sudo usermod -aG docker $USER
newgrp docker

# Test without sudo
docker ps
```

---

## Step 2: Clone the Repository

```bash
# From home directory or preferred location
cd ~
git clone https://github.com/<your-username>/devops-sandbox.git
cd devops-sandbox

# Verify structure
ls -la
```

Expected output:
```
.gitignore
.env.example
Makefile
README.md
docker-compose.yml
platform/
nginx/
monitor/
demo-app/
logs/
envs/
```

---

## Step 3: Configure Environment

```bash
# Copy example to .env
cp .env.example .env

# Edit .env for your environment (optional)
nano .env
```

### Available Environment Variables

```bash
SANDBOX_HOST=localhost          # Hostname/IP for env URLs
NGINX_HTTP_PORT=8080            # HTTP port for Nginx gateway (customize for production)
DEFAULT_TTL_MINUTES=30          # Default environment TTL
API_PORT=5000                   # Control API port
```

**Example for remote server:**

```bash
# If deploying on server with IP 192.168.1.100:
SANDBOX_HOST=192.168.1.100
NGINX_HTTP_PORT=8080
API_PORT=5000
```

---

## Step 4: Start the Platform

```bash
# Allocate ports and firewall rules first (if needed)
# sudo ufw allow 8080/tcp              # HTTP gateway
# sudo ufw allow 5000/tcp              # API port

# Start platform (builds images, launches containers + daemons)
make up

# Expected output:
# [+] Building ...
# [+] Running containers...
# Platform started: nginx + api + health poller + cleanup daemon
```

### Verify Startup

```bash
# Check if Nginx container is running
docker ps | grep sandbox-nginx

# Check background process PIDs
cat envs/api.pid envs/health_poller.pid envs/cleanup_daemon.pid

# Check API is responding
curl http://localhost:5000/envs

# Check Nginx is responding
curl http://localhost:8080/
```

---

## Step 5: Quick Validation

### Create First Environment

```bash
make create

# When prompted:
# Env name: test-app
# TTL minutes [30]: 5

# Expected output:
# ENV_ID=env-abc123
# URL=http://localhost:8080/env/env-abc123/
# TTL_MINUTES=5
# Environment created successfully
```

### Test Environment via Browser or curl

```bash
# If you created env-abc123:
curl http://localhost:8080/env/env-abc123/

# Expected response:
# {"message":"sandbox app is running"}
```

### Check Health Status

```bash
make health

# Expected output:
# env-abc123 status=running ttl_remaining=280s
```

### View Logs

```bash
# Show app logs for the environment
make logs ENV=env-abc123

# Query API health endpoint
curl http://localhost:5000/envs/env-abc123/health
```

### Simulate Outage & Recover

```bash
# Crash the container
make simulate ENV=env-abc123 MODE=crash

# Check health status (should show degraded after 90 seconds)
sleep 5
make health

# Recover
make simulate ENV=env-abc123 MODE=recover

# Verify running again
make health
```

---

## Step 6: Production Configuration (Optional)

### Run Platform as Systemd Service

Create `/etc/systemd/system/devops-sandbox.service`:

```ini
[Unit]
Description=DevOps Sandbox Platform
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/home/username/devops-sandbox
ExecStart=/usr/bin/make up
ExecStop=/usr/bin/make down
Restart=always
RestartSec=10
User=username

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable devops-sandbox.service
sudo systemctl start devops-sandbox.service
sudo systemctl status devops-sandbox.service
```

### Reverse Proxy (Nginx/HAProxy)

If you want to expose via port 80:

```nginx
# /etc/nginx/sites-available/sandbox
server {
    listen 80;
    server_name sandbox.example.com;

    # API gateway
    location /api {
        proxy_pass http://localhost:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Environment gateway (redirect to internal Nginx)
    location /env {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

Enable:

```bash
sudo ln -s /etc/nginx/sites-available/sandbox /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### Firewall Configuration

```bash
# UFW (Ubuntu default)
sudo ufw allow 22/tcp                    # SSH
sudo ufw allow 80/tcp                    # HTTP (if using reverse proxy)
sudo ufw allow 8080/tcp                  # Nginx gateway (direct access)
sudo ufw allow 5000/tcp                  # API (if exposed)
sudo ufw enable
sudo ufw status
```

---

## Step 7: Monitoring & Maintenance

### Watch Cleanup Daemon Logs

```bash
tail -f logs/cleanup.log

# Example output:
# [2026-05-10T10:15:30Z] cleanup daemon started
# [2026-05-10T10:20:30Z] destroying expired env=env-abc123 expires_at=1778390130
# [2026-05-10T10:20:31Z] destroyed env=env-abc123
```

### Monitor Health Poller

```bash
tail -f logs/health_poller.log
```

### Monitor API

```bash
tail -f logs/api.log
```

### Inspect Docker Logs

```bash
# Nginx gateway logs
docker logs sandbox-nginx

# App container logs (for specific env)
docker logs app-env-abc123
```

### Clean Up State (if needed)

```bash
# Stop all environments and clean
make down
make clean

# Full reset (removes all state, logs, archives)
rm -rf envs/* logs/* nginx/conf.d/*.conf

# Start fresh
make up
```

---

## Troubleshooting

### Issue: `make up` fails with network errors

**Cause:** Docker daemon not running or Docker not installed.

**Fix:**

```bash
# Start Docker daemon
sudo systemctl start docker

# Verify installation
docker run hello-world
```

### Issue: Port already in use (8080 or 5000)

**Cause:** Another service using the port.

**Fix:**

```bash
# Find process using port 8080
sudo lsof -i :8080
sudo kill -9 <PID>

# Or change in .env:
NGINX_HTTP_PORT=8081
API_PORT=5001
```

### Issue: `make create` returns Error 141

**Cause:** SIGPIPE in random suffix generation (fixed in latest version).

**Fix:**

```bash
# Update to latest version
git pull origin main

# Retry
make create
```

### Issue: Health checks show status=0 latency=8000ms

**Cause:** App container crashed or network unreachable.

**Fix:**

```bash
# Check if container is running
docker ps | grep app-

# Check app logs
docker logs app-env-abc123

# Check network connectivity
docker exec app-env-abc123 curl http://app-env-abc123:8000/health
```

### Issue: Nginx reload fails

**Cause:** Invalid env route config or Nginx container stopped.

**Fix:**

```bash
# Check Nginx container
docker ps | grep sandbox-nginx

# Restart Nginx
docker restart sandbox-nginx

# Validate Nginx config
docker exec sandbox-nginx nginx -t
```

---

## Advanced: Multi-Environment Setup

### Scale to Multiple Concurrent Environments

```bash
# Create 3 environments
for i in {1..3}; do make create; done

# Check all active environments
make health

# Simulate outage on first env
ENV_ID=$(ls envs/env-*.json | head -1 | xargs basename -s .json)
make simulate ENV=$ENV_ID MODE=crash

# Monitor cleanup daemon auto-expire them
tail -f logs/cleanup.log
```

---

## API Usage Examples

### Via curl

```bash
# List all environments
curl http://localhost:5000/envs

# Create new environment
curl -X POST http://localhost:5000/envs \
  -H "Content-Type: application/json" \
  -d '{"name":"my-app","ttl_minutes":60}'

# Get environment logs
curl http://localhost:5000/envs/env-abc123/logs

# Get environment health
curl http://localhost:5000/envs/env-abc123/health

# Simulate outage
curl -X POST http://localhost:5000/envs/env-abc123/outage \
  -H "Content-Type: application/json" \
  -d '{"mode":"crash"}'

# Destroy environment
curl -X DELETE http://localhost:5000/envs/env-abc123
```

---

## Backup & Restore

### Backup Archived Logs

```bash
# Create tar.gz of all archived logs
tar -czf sandbox-logs-$(date +%Y%m%d).tar.gz logs/archived/

# Upload to remote storage
scp sandbox-logs-*.tar.gz backup-server:/backups/
```

### Restore from Backup

```bash
# Extract to logs directory
tar -xzf sandbox-logs-backup.tar.gz -C logs/
```

---

## Uninstall

```bash
# Stop platform
make down

# Remove repository
cd ~
rm -rf devops-sandbox

# Optional: Remove Docker (if not needed for other projects)
# sudo apt-get remove --purge docker.io docker-compose-plugin
```

---

## Support & Debugging

### Enable Verbose Logging

```bash
# Add debug output to scripts
export DEBUG=1
make create
```

### Check System Resources

```bash
# Monitor CPU/Memory
docker stats

# Check disk usage
df -h

# Monitor open ports
netstat -tulpn | grep LISTEN
```

### Collect Diagnostics

```bash
# Create debug bundle
mkdir debug-bundle
docker ps -a > debug-bundle/containers.txt
docker images > debug-bundle/images.txt
cat envs/*.json > debug-bundle/env-state.txt
tail -100 logs/*.log > debug-bundle/recent-logs.txt
tar -czf debug-bundle.tar.gz debug-bundle/
```

---

## Next Steps

1. **Read [README.md](README.md)** for architecture and feature details
2. **Review [Makefile](Makefile)** for available commands
3. **Explore API** endpoints documented in README
4. **Customize** demo app in `demo-app/` for your use case
5. **Integrate** with CI/CD pipelines using API endpoints
