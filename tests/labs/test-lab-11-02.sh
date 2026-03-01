#!/usr/bin/env bash
# test-lab-11-02.sh — Lab 11-02: External Dependencies
# Module 11: Zammad — external PG, Elasticsearch, Redis (replaces memcached), mailhog SMTP
set -euo pipefail

LAB_ID="11-02"
LAB_NAME="External Dependencies"
MODULE="zammad"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting for PostgreSQL..."
timeout 60 bash -c 'until docker compose -f docker/docker-compose.lan.yml exec -T postgresql pg_isready -U zammad -d zammad_production 2>/dev/null; do sleep 3; done'
info "Waiting for Elasticsearch..."
timeout 120 bash -c 'until curl -sf http://localhost:9200/_cluster/health | grep -qE "\"status\":\"(green|yellow)\""; do sleep 5; done'
info "Waiting for Redis..."
timeout 30 bash -c 'until docker compose -f docker/docker-compose.lan.yml exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; do sleep 2; done'
info "Waiting for Zammad web (rails boot ~3 min)..."
timeout 360 bash -c 'until curl -sf http://localhost:3000/ | grep -qi zammad; do sleep 10; done'

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

for c in zammad-lan-postgresql zammad-lan-elasticsearch zammad-lan-redis zammad-lan-smtp zammad-lan-railsserver zammad-lan-scheduler; do
  if docker ps --filter "name=^/${c}$" --filter "status=running" --format '{{.Names}}' | grep -q "${c}"; then
    pass "Container ${c} is running"
  else
    fail "Container ${c} is not running"
  fi
done

if docker compose -f "${COMPOSE_FILE}" exec -T postgresql pg_isready -U zammad -d zammad_production 2>/dev/null; then
  pass "PostgreSQL: pg_isready OK"
else
  fail "PostgreSQL: pg_isready failed"
fi

ES_HEALTH=$(curl -sf http://localhost:9200/_cluster/health 2>/dev/null || echo "")
ES_STATUS=$(echo "${ES_HEALTH}" | grep -o '"status":"[^"]*"' | head -1 || echo "")
if echo "${ES_STATUS}" | grep -qE 'green|yellow'; then
  ES_VER=$(curl -sf http://localhost:9200/ 2>/dev/null | grep -o '"number":"[^"]*"' | head -1 || echo "")
  pass "Elasticsearch: ${ES_STATUS} ${ES_VER}"
else
  fail "Elasticsearch: cluster not healthy"
fi

# Key Lab 02 test: Redis replaces memcached from Lab 01
if docker compose -f "${COMPOSE_FILE}" exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis: PING → PONG (replaces memcached from Lab 01)"
else
  fail "Redis: no PONG response"
fi

if curl -sf http://localhost:8025/api/v2/messages > /dev/null 2>&1; then
  pass "Mailhog web UI: reachable (:8025) — new in Lab 02"
else
  fail "Mailhog web UI: not reachable"
fi

HTTP_CODE=$(curl -sf http://localhost:3000/ -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
if echo "${HTTP_CODE}" | grep -qE '^(200|301|302)$'; then
  pass "Zammad web: HTTP :3000 → ${HTTP_CODE}"
else
  fail "Zammad web: HTTP :3000 returned ${HTTP_CODE}"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 02 — External Dependencies)"

# Key Lab 02 test: REDIS_URL configured (not memcached)
REDIS_URL=$(docker inspect zammad-lan-railsserver \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep 'REDIS_URL' | head -1 || echo "")
if echo "${REDIS_URL}" | grep -q 'REDIS_URL=redis://'; then
  pass "REDIS_URL configured: ${REDIS_URL}"
else
  fail "REDIS_URL not found in railsserver env"
fi

if curl -sf http://localhost:3000/ | grep -qi 'zammad\|login'; then
  pass "Zammad: login page content OK"
else
  fail "Zammad: login page missing expected content"
fi

AUTH_INFO=$(curl -sf http://localhost:3000/api/v1/signshow 2>/dev/null | head -c 200 || echo "")
if [ -n "${AUTH_INFO}" ]; then
  pass "Zammad API: /api/v1/signshow responds"
else
  fail "Zammad API: /api/v1/signshow not reachable"
fi

ADMIN=$(curl -sf -X POST http://localhost:3000/api/v1/users \
  -H 'Content-Type: application/json' \
  -d '{"firstname":"Admin","lastname":"Lab02","email":"admin@lab.local","password":"Lab02Admin!","roles":["Administrator"]}' \
  2>/dev/null || echo "")
if echo "${ADMIN}" | grep -q '"email":"admin@lab.local"'; then
  pass "Zammad admin user created"
else
  warn "Admin user: may already exist or requires authentication"
fi

RAILS_LOG=$(docker logs zammad-lan-railsserver 2>&1 | tail -5 || echo "")
if echo "${RAILS_LOG}" | grep -qi 'puma\|rails\|started'; then
  pass "Rails server: started (log evidence)"
else
  warn "Rails server: check logs manually"
fi

if docker ps --filter name=zammad-lan-scheduler --filter status=running --format '{{.Names}}' | grep -q scheduler; then
  pass "Zammad scheduler: running"
else
  fail "Zammad scheduler: not running"
fi

if docker compose -f "${COMPOSE_FILE}" exec -T zammad-railsserver \
    sh -c 'nc -z smtp 1025 2>/dev/null && echo OK' 2>/dev/null | grep -q OK; then
  pass "Zammad → Mailhog SMTP: port 1025 reachable"
else
  warn "Zammad → Mailhog: nc not available in container"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi