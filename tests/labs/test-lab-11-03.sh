#!/usr/bin/env bash
# test-lab-11-03.sh — Lab 11-03: Zammad Advanced Features
# Tests: ES indices, RAILS_MAX_THREADS, resource limits, WEB_CONCURRENCY
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }
ZMD_API="http://localhost:3000/api/v1"

section "Container health"
for c in zammad-adv-postgresql zammad-adv-elasticsearch zammad-adv-redis zammad-adv-smtp zammad-adv-railsserver zammad-adv-scheduler zammad-adv-websocket zammad-adv-nginx; do
  if docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    pass "Container $c is running"
  else
    fail "Container $c is not running"
  fi
done

section "PostgreSQL connectivity"
if docker compose -f "$COMPOSE_FILE" exec -T postgresql pg_isready -U zammad -d zammad_production 2>/dev/null | grep -q "accepting"; then
  pass "PostgreSQL accepting connections"
else
  fail "PostgreSQL not ready"
fi

section "Elasticsearch cluster health"
ES_HEALTH=$(curl -sf "http://localhost:9200/_cluster/health" 2>/dev/null) || ES_HEALTH=""
if echo "$ES_HEALTH" | grep -qE '"status":"(green|yellow)"'; then
  ES_STATUS=$(echo "$ES_HEALTH" | grep -oP '"status":"\K[^"]+')
  pass "Elasticsearch cluster status: $ES_STATUS"
else
  fail "Elasticsearch cluster health failed"
fi

section "Elasticsearch Zammad indices"
ES_INDICES=$(curl -sf "http://localhost:9200/_cat/indices" 2>/dev/null) || ES_INDICES=""
if echo "$ES_INDICES" | grep -q "zammad"; then
  pass "Zammad indices exist in Elasticsearch"
else
  fail "No zammad_* indices in Elasticsearch (may need more startup time)"
fi

section "Redis connectivity"
REDIS_PONG=$(docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli PING 2>/dev/null | tr -d '[:space:]') || REDIS_PONG=""
if [ "$REDIS_PONG" = "PONG" ]; then
  pass "Redis PING responded"
else
  fail "Redis PING failed"
fi

section "Zammad web endpoint"
ZMD_CODE=$(curl -sw '%{http_code}' -o /dev/null http://localhost:3000/ 2>/dev/null) || ZMD_CODE="000"
if echo "$ZMD_CODE" | grep -qE "^(200|301|302)"; then
  pass "Zammad web :3000 HTTP $ZMD_CODE"
else
  fail "Zammad web :3000 returned $ZMD_CODE"
fi

section "RAILS_MAX_THREADS in container env"
RS_ENV=$(docker inspect zammad-adv-railsserver --format '{{json .Config.Env}}' 2>/dev/null) || RS_ENV="[]"
if echo "$RS_ENV" | grep -q '"RAILS_MAX_THREADS=5"'; then
  pass "RAILS_MAX_THREADS=5 set in railsserver"
else
  fail "RAILS_MAX_THREADS=5 not found in railsserver env"
fi

section "WEB_CONCURRENCY in container env"
if echo "$RS_ENV" | grep -q '"WEB_CONCURRENCY=2"'; then
  pass "WEB_CONCURRENCY=2 set in railsserver"
else
  fail "WEB_CONCURRENCY=2 not found in railsserver env"
fi

section "REDIS_URL in container env"
if echo "$RS_ENV" | grep -q "REDIS_URL"; then
  pass "REDIS_URL configured in railsserver"
else
  fail "REDIS_URL not found in railsserver env"
fi

section "Resource limits check"
RS_MEM=$(docker inspect zammad-adv-railsserver --format '{{.HostConfig.Memory}}' 2>/dev/null) || RS_MEM="0"
if [ "$RS_MEM" = "2147483648" ]; then
  pass "zammad-adv-railsserver memory limit = 2G (2147483648 bytes)"
else
  fail "zammad-adv-railsserver memory limit: expected 2147483648, got $RS_MEM"
fi
ES_MEM=$(docker inspect zammad-adv-elasticsearch --format '{{.HostConfig.Memory}}' 2>/dev/null) || ES_MEM="0"
if [ "$ES_MEM" = "1073741824" ]; then
  pass "zammad-adv-elasticsearch memory limit = 1G"
else
  fail "zammad-adv-elasticsearch memory limit: expected 1073741824, got $ES_MEM"
fi

section "Mailhog SMTP relay"
if timeout 5 bash -c 'echo > /dev/tcp/localhost/8025' 2>/dev/null; then
  pass "Mailhog :8025 reachable"
else
  fail "Mailhog :8025 not reachable"
fi

section "Zammad admin setup"
SIGN=$(curl -sf "$ZMD_API/signshow" 2>/dev/null) || SIGN=""
if echo "$SIGN" | grep -qE '"setup_info":|"token":'; then
  pass "Zammad API /signshow reachable"
else
  fail "Zammad API /signshow failed: $SIGN"
fi

section "Scheduler container running"
SC_STATUS=$(docker inspect zammad-adv-scheduler --format '{{.State.Running}}' 2>/dev/null) || SC_STATUS="false"
if [ "$SC_STATUS" = "true" ]; then
  pass "zammad-adv-scheduler is running"
else
  fail "zammad-adv-scheduler is not running"
fi

echo
echo "====================================="
echo "  Zammad Lab 11-03 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1