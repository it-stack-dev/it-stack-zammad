#!/usr/bin/env bash
# test-lab-11-06.sh — Zammad Lab 06: Production Deployment
# Module 11 | Lab 06 | Tests: resource limits, restart=always, volumes, Elasticsearch, metrics
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.production.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

KC_PORT=8210
NGINX_PORT=3002
MAILHOG_PORT=8028
LDAP_PORT=3898
KC_ADMIN_PASS="Prod06Admin!"
LDAP_ADMIN_PASS="LdapProd06!"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 06 Production Deployment"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize (Elasticsearch + Zammad may take 2-3 min)..."

section "Infrastructure Health Checks"
for i in $(seq 1 60); do
  status=$(docker inspect zammad-prod-keycloak --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect zammad-prod-keycloak --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Keycloak healthy" || fail "Keycloak not healthy"

for i in $(seq 1 30); do
  status=$(docker inspect zammad-prod-ldap --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 3
done
[[ "$(docker inspect zammad-prod-ldap --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "LDAP healthy" || fail "LDAP not healthy"

for i in $(seq 1 60); do
  status=$(docker inspect zammad-prod-elasticsearch --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect zammad-prod-elasticsearch --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Elasticsearch healthy" || fail "Elasticsearch not healthy"

for i in $(seq 1 90); do
  status=$(docker inspect zammad-prod-railsserver --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 6
done
[[ "$(docker inspect zammad-prod-railsserver --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Zammad RailsServer healthy" || fail "Zammad RailsServer not healthy"

section "Production Configuration Checks"
for ctr in zammad-prod-railsserver zammad-prod-keycloak zammad-prod-ldap zammad-prod-postgresql; do
  rp=$(docker inspect "$ctr" --format '{{.HostConfig.RestartPolicy.Name}}')
  [[ "$rp" == "always" ]] && pass "$ctr restart=always" || fail "$ctr restart policy is '$rp'"
done

for ctr in zammad-prod-railsserver zammad-prod-elasticsearch zammad-prod-keycloak; do
  mem=$(docker inspect "$ctr" --format '{{.HostConfig.Memory}}')
  [[ "$mem" -gt 0 ]] && pass "$ctr memory limit set ($mem bytes)" || fail "$ctr memory limit not set"
done

for vol in zammad-prod-ldap-data zammad-prod-ldap-config zammad-prod-postgresql-data zammad-prod-elasticsearch-data zammad-prod-redis-data zammad-prod-data; do
  docker volume ls | grep -q "$vol" && pass "Volume $vol exists" || fail "Volume $vol missing"
done

section "LDAP Verification"
ldap_bind=$(docker exec zammad-prod-ldap ldapsearch -x -H ldap://localhost -b "dc=lab,dc=local" -D "cn=admin,dc=lab,dc=local" -w "$LDAP_ADMIN_PASS" "(objectClass=organizationalUnit)" dn 2>&1)
echo "$ldap_bind" | grep -q "dn:" && pass "LDAP bind and search OK" || fail "LDAP bind failed"

section "Redis Persistence"
redis_cfg=$(docker exec zammad-prod-redis redis-cli -a "Prod06Redis!" CONFIG GET save 2>/dev/null | tr '\n' ' ')
echo "$redis_cfg" | grep -q "900" && pass "Redis persistence (save 900 1) configured" || fail "Redis save configuration missing"

section "Elasticsearch Check"
curl -sf "http://localhost:9200/_cluster/health" 2>/dev/null | grep -qE '"status":"(green|yellow)"' && pass "Elasticsearch cluster healthy" || {
  # Elasticsearch is not directly port-exposed; check via container
  docker exec zammad-prod-elasticsearch curl -sf http://localhost:9200/_cluster/health | grep -qE '"status":"(green|yellow)"' && pass "Elasticsearch cluster healthy (via container)" || fail "Elasticsearch not healthy"
}

section "Keycloak API & Metrics"
TOKEN=$(curl -sf -X POST "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=${KC_ADMIN_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$TOKEN" ]] && pass "Keycloak admin token obtained" || fail "Keycloak admin token failed"

REALM_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms" | grep -o '"realm":"it-stack"' | wc -l || echo 0)
if [[ "$REALM_EXISTS" -gt 0 ]]; then
  pass "Realm it-stack exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Production"}'
  pass "Realm it-stack created"
fi

CLIENT_EXISTS=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://localhost:${KC_PORT}/admin/realms/it-stack/clients?clientId=zammad-client" | grep -o '"clientId":"zammad-client"' | wc -l || echo 0)
if [[ "$CLIENT_EXISTS" -gt 0 ]]; then
  pass "OIDC client zammad-client exists"
else
  curl -sf -X POST "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"clientId":"zammad-client","enabled":true,"protocol":"openid-connect","secret":"zammad-prod-06","redirectUris":["http://localhost:'"${NGINX_PORT}"'/*"]}'
  pass "OIDC client zammad-client created"
fi

curl -sf "http://localhost:${KC_PORT}/metrics" | grep -q "keycloak" && pass "Keycloak /metrics endpoint returns data" || fail "Keycloak /metrics not responding"

section "Zammad API"
curl -sf "http://localhost:${NGINX_PORT}/api/v1/signshow" | grep -qi "maintenance\|authenticity\|users" && pass "Zammad API signshow responding" || {
  curl -sf "http://localhost:${NGINX_PORT}/" | grep -qi "zammad\|loading" && pass "Zammad web UI accessible" || fail "Zammad not reachable on port ${NGINX_PORT}"
}

section "Mailhog SMTP Relay"
curl -sf "http://localhost:${MAILHOG_PORT}/" | grep -qi "mailhog\|swaggerui" && pass "Mailhog UI responding" || fail "Mailhog UI not reachable"

section "Log Rotation Configuration"
log_driver=$(docker inspect zammad-prod-railsserver --format '{{.HostConfig.LogConfig.Type}}')
[[ "$log_driver" == "json-file" ]] && pass "Log driver is json-file" || fail "Log driver is '$log_driver'"

echo ""
echo "================================================"
echo "Lab 06 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1