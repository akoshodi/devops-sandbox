SHELL := /bin/bash
ROOT := $(shell pwd)

ifneq (,$(wildcard .env))
include .env
export
endif

API_PORT ?= 5000
DEFAULT_TTL_MINUTES ?= 30

.PHONY: up down create destroy logs health simulate clean

up:
	@mkdir -p logs/nginx logs/archived envs
	@cp -n .env.example .env >/dev/null 2>&1 || true
	@docker compose up -d nginx
	@docker build -t sandbox-demo-app:latest demo-app >/dev/null
	@python3 -m venv .venv
	@.venv/bin/pip install --quiet -r requirements.txt
	@-if [ -f envs/api.pid ]; then kill $$(cat envs/api.pid) >/dev/null 2>&1 || true; fi
	@-if [ -f envs/health_poller.pid ]; then kill $$(cat envs/health_poller.pid) >/dev/null 2>&1 || true; fi
	@-if [ -f envs/cleanup_daemon.pid ]; then kill $$(cat envs/cleanup_daemon.pid) >/dev/null 2>&1 || true; fi
	@nohup .venv/bin/python platform/api.py >> logs/api.log 2>&1 & echo $$! > envs/api.pid
	@nohup .venv/bin/python monitor/health_poller.py >> logs/health_poller.log 2>&1 & echo $$! > envs/health_poller.pid
	@nohup bash platform/cleanup_daemon.sh >> logs/cleanup_daemon.log 2>&1 & echo $$! > envs/cleanup_daemon.pid
	@echo "Platform started: nginx + api + health poller + cleanup daemon"

down:
	@shopt -s nullglob; for f in envs/env-*.json; do env_id=$${f##*/}; env_id=$${env_id%.json}; bash platform/destroy_env.sh $$env_id >/dev/null || true; done
	@-if [ -f envs/api.pid ]; then kill $$(cat envs/api.pid) >/dev/null 2>&1 || true; rm -f envs/api.pid; fi
	@-if [ -f envs/health_poller.pid ]; then kill $$(cat envs/health_poller.pid) >/dev/null 2>&1 || true; rm -f envs/health_poller.pid; fi
	@-if [ -f envs/cleanup_daemon.pid ]; then kill $$(cat envs/cleanup_daemon.pid) >/dev/null 2>&1 || true; rm -f envs/cleanup_daemon.pid; fi
	@docker compose down
	@echo "Platform stopped"

create:
	@read -rp "Env name: " name; \
	read -rp "TTL minutes [$(DEFAULT_TTL_MINUTES)]: " ttl; \
	if [ -z "$$ttl" ]; then ttl=$(DEFAULT_TTL_MINUTES); fi; \
	bash platform/create_env.sh "$$name" "$$ttl"

destroy:
	@if [ -z "$(ENV)" ]; then echo "Usage: make destroy ENV=env-abc123"; exit 1; fi
	@bash platform/destroy_env.sh "$(ENV)"

logs:
	@if [ -z "$(ENV)" ]; then echo "Usage: make logs ENV=env-abc123"; exit 1; fi
	@tail -n 100 "logs/$(ENV)/app.log"

health:
	@python3 -c 'import glob, json, time; files=sorted(glob.glob("envs/env-*.json"));\
[print(f"{s['"'"'id'"'"']} status={s['"'"'status'"'"']} ttl_remaining={max(0, s['"'"'created_at_epoch'"'"']+s['"'"'ttl_seconds'"'"']-int(time.time()))}s") for s in [json.load(open(p, "r", encoding="utf-8")) for p in files]]'

simulate:
	@if [ -z "$(ENV)" ] || [ -z "$(MODE)" ]; then echo "Usage: make simulate ENV=env-abc123 MODE=crash"; exit 1; fi
	@bash platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean: down
	@find logs -mindepth 1 -not -name .gitkeep -not -path "logs/archived/.gitkeep" -exec rm -rf {} +
	@find envs -mindepth 1 -not -name .gitkeep -exec rm -rf {} +
	@echo "State and logs cleaned"
