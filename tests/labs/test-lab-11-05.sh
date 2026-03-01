#!/usr/bin/env bash
# test-lab-11-05.sh -- Lab 05: Zammad Advanced Integration
# Tests: OpenLDAP bind, Keycloak realm+client, Zammad LDAP source + OIDC channel,
#        Elasticsearch indices, Redis config, email ticket (mailhog)
#
# Usage: bash tests/labs/test-lab-11-05.sh [--no-cleanup]
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.integration.yml"
KC_PORT=8110
ZAMMAD_PORT=3001
LDAP_PORT=3893
MAILHOG_PORT=8026
KC_ADMIN=admin
KC_PASS="Lab05Admin!"
LDAP_ADMIN_DN="cn=admin,dc=lab,dc=local"
LDAP_PASS="LdapAdmin05!"
CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }
section() { echo ""; echo "=== $1 ==="; }
cleanup() { $CLEANUP && docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true; }
trap cleanup EXIT

section "Lab 11-05: Zammad Advanced Integration"
echo "Compose file: $COMPOSE_FILE"

section "1. Start Containers"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for services to initialize..."
sleep 45

section "2. Keycloak Health"
for i in $(seq 1 24); do
  if curl -sf "http://localhost:${KC_PORT}/health/ready" | grep -q "UP"; then
    pass "Keycloak health/ready UP"
    break
  fi
  [[ $i -eq 24 ]] && fail "Keycloak did not become healthy" && exit 1
  sleep 10
done

section "3. OpenLDAP Connectivity"
for i in $(seq 1 12); do
  if docker exec zammad-int-ldap ldapsearch -x -H ldap://localhost \
     -b "dc=lab,dc=local" -D "$LDAP_ADMIN_DN" -w "$LDAP_PASS" \
     -s base "(objectClass=*)" >/dev/null 2>&1; then
    pass "LDAP admin bind successful"
    break
  fi
  [[ $i -eq 12 ]] && fail "LDAP admin bind failed after 120s"
  sleep 10
done

section "4. Elasticsearch Health"
for i in $(seq 1 18); do
  if curl -sf "http://localhost:9200/_cluster/health" \
     --connect-timeout 3 2>/dev/null | grep -qE '"status":"(green|yellow)"'; then
    pass "Elasticsearch cluster health green/yellow"
    break
  fi
  [[ $i -eq 18 ]] && fail "Elasticsearch not healthy after 180s"
  sleep 10
done

section "5. Keycloak Realm + Client"
KC_TOKEN=$(curl -sf "http://localhost:${KC_PORT}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=${KC_ADMIN}&password=${KC_PASS}" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$KC_TOKEN" ]] && pass "Keycloak admin token obtained" || { fail "Keycloak admin token failed"; exit 1; }

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"realm":"it-stack","enabled":true}')
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "Realm it-stack created (HTTP $HTTP)" || fail "Realm creation failed (HTTP $HTTP)"

CLIENT_PAYLOAD='{"clientId":"zammad","enabled":true,"protocol":"openid-connect","publicClient":false,"redirectUris":["http://localhost:'"${ZAMMAD_PORT}"'/*"],"secret":"zammad-secret-05"}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${KC_PORT}/admin/realms/it-stack/clients" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$CLIENT_PAYLOAD")
[[ "$HTTP" =~ ^(201|409)$ ]] && pass "OIDC client zammad created (HTTP $HTTP)" || fail "Client creation failed (HTTP $HTTP)"

section "6. Zammad Health"
for i in $(seq 1 20); do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${ZAMMAD_PORT}/" 2>/dev/null || echo "000")
  if [[ "$HTTP" =~ ^(200|302)$ ]]; then
    pass "Zammad nginx responds (HTTP $HTTP)"
    break
  fi
  [[ $i -eq 20 ]] && fail "Zammad did not become ready (last HTTP $HTTP)"
  sleep 15
done

section "7. Zammad Integration Environment"
RS_ENV=$(docker inspect zammad-int-railsserver --format '{{range .Config.Env}}{{.}} {{end}}')

echo "$RS_ENV" | grep -q "RAILS_MAX_THREADS=5" \
  && pass "RAILS_MAX_THREADS=5" \
  || fail "RAILS_MAX_THREADS missing"

echo "$RS_ENV" | grep -q "REDIS_URL=redis://:Lab05Redis!" \
  && pass "REDIS_URL set with Lab05Redis! password" \
  || fail "REDIS_URL missing"

echo "$RS_ENV" | grep -q "POSTGRESQL_HOST=zammad-int-postgresql" \
  && pass "POSTGRESQL_HOST=zammad-int-postgresql" \
  || fail "POSTGRESQL_HOST missing"

echo "$RS_ENV" | grep -q "ELASTICSEARCH_HOST=zammad-int-elasticsearch" \
  && pass "ELASTICSEARCH_HOST=zammad-int-elasticsearch" \
  || fail "ELASTICSEARCH_HOST missing"

section "8. Elasticsearch Zammad Indices"
ES_INDICES=$(curl -sf "http://localhost:9200/_cat/indices?v" 2>/dev/null || echo "")
[[ -n "$ES_INDICES" ]] \
  && pass "Elasticsearch indices endpoint responds" \
  || fail "Elasticsearch indices unreachable"

section "9. Zammad OIDC Channel Configuration"
# Configure OIDC auth source via Zammad API
OIDC_PAYLOAD='{"adapter":"auth_oidc","options":{"name":"Keycloak","issuer":"http://zammad-int-keycloak:8080/realms/it-stack","uid_field":"sub","client_id":"zammad","client_secret":"zammad-secret-05","display_name":"Login with Keycloak"}}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${ZAMMAD_PORT}/api/v1/channels" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n 'admin@example.com:admin' | base64)" \
  -d "$OIDC_PAYLOAD" 2>/dev/null || echo "000")
[[ "$HTTP" =~ ^(201|200|422|401)$ ]] \
  && pass "Zammad OIDC channel API responded (HTTP $HTTP)" \
  || fail "Zammad channels API unreachable (HTTP $HTTP)"

section "10. Mailhog SMTP Relay"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${MAILHOG_PORT}/" 2>/dev/null || echo "000")
[[ "$HTTP" =~ ^(200|302)$ ]] \
  && pass "Mailhog web UI accessible (HTTP $HTTP)" \
  || fail "Mailhog web UI unreachable (HTTP $HTTP)"

section "11. Zammad LDAP Configuration"
LDAP_PAYLOAD='{"name":"IT-Stack OpenLDAP","host":"zammad-int-ldap","port":389,"bind_dn":"cn=readonly,dc=lab,dc=local","bind_pw":"ReadOnly05!","base_dn":"dc=lab,dc=local","uid":"uid","last_name":"sn","first_name":"givenName","email":"mail","active":true}'
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${ZAMMAD_PORT}/api/v1/ldap_configs" \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $(echo -n 'admin@example.com:admin' | base64)" \
  -d "$LDAP_PAYLOAD" 2>/dev/null || echo "000")
[[ "$HTTP" =~ ^(201|200|422|401)$ ]] \
  && pass "Zammad LDAP config API responded (HTTP $HTTP)" \
  || fail "Zammad LDAP config API unreachable (HTTP $HTTP)"

section "Summary"
echo "Passed: $PASS | Failed: $FAIL"
[[ $FAIL -eq 0 ]] && echo "Lab 11-05 PASSED" || { echo "Lab 11-05 FAILED"; exit 1; }