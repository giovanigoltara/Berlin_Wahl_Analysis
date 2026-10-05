# Pipeline entry point. Run `make help` for targets.
# Targets for later phases fail loudly until implemented, so `make all` never reports false success.

SHELL := /bin/bash
.DEFAULT_GOAL := help

-include .env
export

PSQL := docker compose exec -T db psql -v ON_ERROR_STOP=1 -U $${POSTGRES_USER:-hgv} -d $${POSTGRES_DB:-hgv}
PY   := uv run python

define todo
	@echo "Not implemented yet: $(1)" >&2; exit 1
endef

.PHONY: help setup env db-up db-check db-down db-reset download inspect load allocation dasymetric osm gee analysis maps all clean

help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env")

setup: env ## Install the pinned Python environment
	uv sync --locked

db-up: env ## Start PostGIS and wait until healthy
	docker compose up -d --wait db

db-check: db-up ## Verify PostgreSQL and PostGIS versions
	$(PSQL) -c "SELECT version();" \
	        -c "SELECT extname, extversion FROM pg_extension WHERE extname LIKE 'postgis%' ORDER BY 1;" \
	        -c "SELECT postgis_full_version();"

db-down: ## Stop PostGIS (data volume kept)
	docker compose down

db-reset: ## Stop PostGIS and delete its data volume
	docker compose down -v

download: ## Phase 1: fetch institutional sources into data/raw with a manifest
	$(PY) src/download.py

inspect: download ## Phase 1: inspect raw sources, write docs/validation_report.md
	$(PY) src/inspect_raw.py

load: db-up inspect ## Phase 2: load sources into PostGIS, build clean tables, run checks
	$(PY) src/load_postgis.py

allocation: load ## Phase 2: allocate postal votes to station districts (methods A, B, C)
	$(PY) src/run_sql.py allocation

dasymetric: load ## Phase 2: residential population and land per station district
	$(PY) src/run_sql.py dasymetric

osm: db-up download ## Phase 2: extract OSM amenities into PostGIS
	$(PY) src/osm_extract.py

gee: dasymetric ## Phase 3: Earth Engine composites and zonal statistics
	$(call todo,Phase 3 src/gee_extract.py)

analysis: allocation dasymetric osm gee ## Phase 4: indicator table and statistics
	$(call todo,Phase 4 sql/50_indicators.sql and src/analysis.py)

maps: analysis ## Phase 5: publication figures
	$(call todo,Phase 5 src/maps.py)

all: maps ## Run the full pipeline

clean: ## Remove regenerated data (raw and interim)
	find data/raw data/interim -mindepth 1 ! -name .gitkeep -delete
