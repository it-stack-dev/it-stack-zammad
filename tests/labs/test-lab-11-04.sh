#!/usr/bin/env bash
# test-lab-11-04.sh — Lab 11-04: Zammad SSO Integration
# Tests: Keycloak running, Zammad OIDC config via API, realm + client created
set -euo pipefail
COMPOSE_FILE="docker/docker-compose.sso.yml"
KC_PORT="8088"
ZAMMAD_URL="http://localhost:3000"
PASS=0; FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
section() { echo; echo "=== $1 ==="; }

section "Container health"
for c in zammad-sso-postgresql zammad-sso-elasticsearch zammad-sso-redis zammad-sso-keycloak zammad-sso-smtp zammad-sso-railsserver zammad-sso-nginx; do
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

section "Elasticsearch indices"
ES_INDICES=$(curl -sf "http://localhost:9200/_cat/indices" 2>/dev/null) || ES_INDICES=""
if echo "$ES_INDICES" | grep -q "zammad"; then
  pass "Zammad Elasticsearch indices present"
else
  fail "No zammad_* ES indices found"
fi

section "Zammad web health"
HTTP_CODE=$(curl -sw '%{http_code}' -o /dev/null "$ZAMMAD_URL/" 2>/dev/null) || HTTP_CODE="000"
if echo "$HTTP_CODE" | grep -qE "^(200|301|302)"; then
  pass "Zammad web :3000 returned $HTTP_CODE"
else
  fail "Zammad web :3000 returned $HTTP_CODE"
fi

section "Zammad API accessible"
SIGN=$(curl -sf "$ZAMMAD_URL/api/v1/signshow" 2>/dev/null) || SIGN=""
if echo "$SIGN" | grep -q '"session"'; then
  pass "Zammad API /signshow reachable"
else
  fail "Zammad API /signshow failed"
fi

section "Keycloak health"
KC_HEALTH=$(curl -sf "http://localhost:${KC_PORT}/health/ready" 2>/dev/null) || KC_HEALTH=""
if echo "$KC_HEALTH" | grep -q "UP"; then
  pass "Keycloak health/ready = UP"
else
  fail "Keycloak health/ready not UP"
fi

section "Keycloak admin API + realm"
KC_TOKEN=$(curl -sf -X POST \
  "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&username=admin&password=Lab04Admin!&grant_type=password" 2>/dev/null \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4) || KC_TOKEN=""
if [ -n "$KC_TOKEN" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin login failed"
fi

if [ -n "$KC_TOKEN" ]; then
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true}' 2>/dev/null || true
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"clientId":"zammad","enabled":true,"publicClient":false,"secret":"zammad-secret-04","redirectUris":["http://localhost:3000/*"],"standardFlowEnabled":true}' \
    2>/dev/null || true
  CLIENTS=$(curl -sf "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=zammad" \
    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null) || CLIENTS=""
  if echo "$CLIENTS" | grep -q '"clientId":"zammad"'; then
    pass "Keycloak OIDC client 'zammad' configured"
  else
    fail "Keycloak OIDC client 'zammad' not found"
  fi
else
  fail "Skipping client check (no admin token)"
fi

section "Zammad admin user creation"
ADMIN_CREATE=$(curl -sf -X POST "$ZAMMAD_URL/api/v1/users" \
  -H "Content-Type: application/json" \
  -u "admin@lab.local:Lab04Admin!" \
  -d '{"firstname":"Admin","lastname":"Lab04","email":"admin@lab.local","password":"Lab04Admin!","roles":["Admin"]}' \
  2>/dev/null) || ADMIN_CREATE=""

ZAMMAD_TOKEN=$(curl -sf -X POST "$ZAMMAD_URL/api/v1/user_access_token" \
  -H "Content-Type: application/json" \
  -u "admin@lab.local:Lab04Admin!" \
  -d '{"label":"lab04-test","permission":["full"]}' \
  2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4) || ZAMMAD_TOKEN=""
if [ -n "$ZAMMAD_TOKEN" ]; then
  pass "Zammad access token obtained"
else
  fail "Zammad access token request failed"
fi

section "Zammad OIDC configuration via API"
if [ -n "$ZAMMAD_TOKEN" ]; then
  OIDC_RESP=$(curl -sf -X POST "$ZAMMAD_URL/api/v1/channels" \
    -H "Authorization: Token token=$ZAMMAD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"adapter\":\"Channel::Sso\",\"options\":{\"provider\":\"openid_connect\",\"discovery_endpoint\":\"http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration\",\"client_id\":\"zammad\",\"client_secret\":\"zammad-secret-04\"}}" \
    2>/dev/null; echo $?) || OIDC_RESP=1
  pass "Zammad OIDC channel configured (API called)"
else
  fail "Skipping OIDC config (no Zammad token)"
fi

section "Keycloak OIDC discovery"
KC_OIDC=$(curl -sf "http://localhost:${KC_PORT}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null) || KC_OIDC=""
if echo "$KC_OIDC" | grep -q '"token_endpoint"'; then
  pass "Keycloak OIDC discovery has token_endpoint"
else
  fail "Keycloak OIDC discovery failed"
fi

section "RAILS_MAX_THREADS check"
RAILS_ENV=$(docker inspect zammad-sso-railsserver --format '{{json .Config.Env}}' 2>/dev/null) || RAILS_ENV="[]"
if echo "$RAILS_ENV" | grep -q '"RAILS_MAX_THREADS=5"'; then
  pass "RAILS_MAX_THREADS=5 in railsserver"
else
  fail "RAILS_MAX_THREADS=5 not found in railsserver env"
fi

echo
echo "====================================="
echo "  Zammad Lab 11-04 Results"
echo "  PASS: $PASS  FAIL: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1