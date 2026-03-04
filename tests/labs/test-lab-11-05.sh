#!/usr/bin/env bash
# test-lab-11-05.sh — Lab 11-05: Advanced Integration (INT-06 + INT-10)
# Module 11: Zammad Help Desk
# INT-06: Zammad↔Keycloak OIDC + LDAP seed + KC federation + OIDC token
# INT-10: Zammad↔FreePBX CTI phone tickets (WireMock mock + cti_generic_api channel)
# Services: PostgreSQL · Elasticsearch · Redis · OpenLDAP · Keycloak · SMTP(Mailhog) · WireMock
#           Zammad (init · railsserver · scheduler · websocket · nginx)
# Ports:    Zammad:3001  KC:8110  LDAP:3893  ES:9200  MH:8026  WM:8027
# INT-06:   LDAP seed (zammadadmin/zammaduser1/zammaduser2) · KC LDAP federation
#           Keycloak OIDC client · Zammad OIDC channel · OIDC token issuance
# INT-10:   WireMock FreePBX mock · FREEPBX_* env vars · Zammad CTI phone channel API
#
# Usage: bash tests/labs/test-lab-11-05.sh [--no-cleanup]
set -euo pipefail

LAB_ID="11-05"
LAB_NAME="Advanced Integration"
MODULE="zammad"
COMPOSE_FILE="docker/docker-compose.integration.yml"
KC_BASE="http://localhost:8110"
KC_REALM="it-stack"
ZAMMAD_PORT=3001
ES_URL="http://localhost:9200"
MAILHOG_PORT=8026
CLEANUP=true
PASS=0
FAIL=0

for arg in "$@"; do [ "$arg" = "--no-cleanup" ] && CLEANUP=false; done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [ "${CLEANUP}" = "true" ]; then
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Lab ${LAB_ID}: ${LAB_NAME} — ${MODULE}${NC}"
echo -e "${CYAN}  Zammad ↔ Keycloak OIDC (INT-06) + LDAP + ES + Email${NC}"
echo -e "${CYAN}  Zammad ↔ FreePBX CTI phone tickets via WireMock (INT-10)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for integration stack to initialize..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in zammad-int-ldap zammad-int-postgresql zammad-int-elasticsearch zammad-int-redis zammad-int-keycloak zammad-int-smtp zammad-int-railsserver zammad-int-nginx; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec zammad-int-postgresql pg_isready -U zammad 2>/dev/null; then
  pass "PostgreSQL accepting connections"
else
  fail "PostgreSQL not responding"
fi

if docker exec zammad-int-redis redis-cli -a Lab05Redis! ping 2>/dev/null | grep -q 'PONG'; then
  pass "Redis PONG"
else
  fail "Redis not responding"
fi

ES_STATUS=$(curl -sf "${ES_URL}/_cluster/health" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','red'))" 2>/dev/null || echo "red")
if [[ "${ES_STATUS}" == "green" || "${ES_STATUS}" == "yellow" ]]; then
  pass "Elasticsearch cluster health: ${ES_STATUS}"
else
  fail "Elasticsearch health: ${ES_STATUS} (expected green/yellow)"
fi

for i in $(seq 1 24); do
  if curl -sf "${KC_BASE}/health/ready" 2>/dev/null | grep -q 'UP'; then
    pass "Keycloak health/ready UP"
    break
  fi
  [[ $i -eq 24 ]] && fail "Keycloak not healthy after 240s"
  sleep 10
done

for i in $(seq 1 20); do
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "http://localhost:${ZAMMAD_PORT}/" 2>/dev/null || echo "000")
  if [[ "${HTTP}" =~ ^(200|302)$ ]]; then
    pass "Zammad nginx responds (HTTP ${HTTP})"
    break
  fi
  [[ $i -eq 20 ]] && fail "Zammad not ready after 200s (last HTTP ${HTTP})"
  sleep 10
done

# ── PHASE 3: LDAP Seed Verification ──────────────────────────────────────────
section "Phase 3: LDAP Seed Verification (INT-06)"

SEED_EXIT=$(docker inspect zammad-int-ldap-seed --format '{{.State.ExitCode}}' 2>/dev/null || echo "99")
if [ "${SEED_EXIT}" = "0" ]; then
  pass "zammad-int-ldap-seed exited 0 (seed successful)"
else
  fail "zammad-int-ldap-seed exit code: ${SEED_EXIT} (expected 0)"
fi

USER_COUNT=$(ldapsearch -x -H ldap://localhost:3893 \
  -b "cn=users,cn=accounts,dc=lab,dc=local" \
  -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
  "(objectClass=inetOrgPerson)" uid 2>/dev/null \
  | grep -c "^uid:" || echo "0")
if [ "${USER_COUNT}" -ge 3 ]; then
  pass "LDAP seed: ${USER_COUNT} users in cn=users,cn=accounts (expected ≥3)"
else
  fail "LDAP seed: only ${USER_COUNT} users found (expected ≥3)"
fi

GROUP_COUNT=$(ldapsearch -x -H ldap://localhost:3893 \
  -b "cn=groups,cn=accounts,dc=lab,dc=local" \
  -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
  "(objectClass=groupOfNames)" cn 2>/dev/null \
  | grep -c "^cn:" || echo "0")
if [ "${GROUP_COUNT}" -ge 2 ]; then
  pass "LDAP seed: ${GROUP_COUNT} groups in cn=groups,cn=accounts (expected ≥2)"
else
  fail "LDAP seed: only ${GROUP_COUNT} groups found (expected ≥2)"
fi

if ldapsearch -x -H ldap://localhost:3893 \
    -b "cn=users,cn=accounts,dc=lab,dc=local" \
    -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
    "(uid=zammadadmin)" uid 2>/dev/null | grep -q "uid: zammadadmin"; then
  pass "LDAP seed: readonly bind OK, uid=zammadadmin found"
else
  fail "LDAP seed: uid=zammadadmin not found or readonly bind failed"
fi

# ── PHASE 4: Keycloak LDAP Federation (INT-06) ────────────────────────────────
section "Phase 4: Keycloak LDAP Federation (INT-06)"

info "Authenticating to Keycloak admin..."
KC_TOKEN=$(curl -sf -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=Lab05Admin!" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token acquired"
else
  fail "Keycloak admin token not acquired — subsequent KC tests will fail"
fi

HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_BASE}/admin/realms/${KC_REALM}" \
  -H "Authorization: Bearer ${KC_TOKEN}" || echo "000")
if [ "${HTTP_STATUS}" = "200" ]; then
  pass "Keycloak realm '${KC_REALM}' already exists"
else
  info "Creating Keycloak realm '${KC_REALM}'..."
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"realm\":\"${KC_REALM}\",\"enabled\":true,\"displayName\":\"IT-Stack Lab\"}" \
    || echo "000")
  if [ "${HTTP_STATUS}" = "201" ]; then
    pass "Keycloak realm '${KC_REALM}' created"
  else
    fail "Keycloak realm creation failed (status: ${HTTP_STATUS})"
  fi
fi

info "Registering LDAP federation component in Keycloak..."
EXISTING_LDAP=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; comps=json.load(sys.stdin); print(next((c['id'] for c in comps if c.get('name')=='zammad-lab-ldap'),''))" \
  2>/dev/null || echo "")
if [ -n "${EXISTING_LDAP}" ]; then
  pass "Keycloak LDAP federation 'zammad-lab-ldap' already registered (ID: ${EXISTING_LDAP})"
else
  LDAP_PAYLOAD=$(cat <<'LDAP_PAYLOAD_EOF'
{
  "name": "zammad-lab-ldap",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "vendor":               ["rhds"],
    "connectionUrl":        ["ldap://zammad-int-ldap:389"],
    "bindDn":               ["cn=readonly,dc=lab,dc=local"],
    "bindCredential":       ["ReadOnly05!"],
    "usersDn":              ["cn=users,cn=accounts,dc=lab,dc=local"],
    "userObjectClasses":    ["inetOrgPerson"],
    "usernameLDAPAttribute":["uid"],
    "uuidLDAPAttribute":    ["uid"],
    "rdnLDAPAttribute":     ["uid"],
    "searchScope":          ["1"],
    "authType":             ["simple"],
    "enabled":              ["true"],
    "trustEmail":           ["true"],
    "syncRegistrations":    ["true"],
    "fullSyncPeriod":       ["-1"],
    "changedSyncPeriod":    ["-1"],
    "importEnabled":        ["true"],
    "batchSizeForSync":     ["1000"]
  }
}
LDAP_PAYLOAD_EOF
)
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KC_REALM}/components" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${LDAP_PAYLOAD}" || echo "000")
  if [ "${HTTP_STATUS}" = "201" ]; then
    pass "Keycloak LDAP federation 'zammad-lab-ldap' created"
    EXISTING_LDAP=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      | python3 -c "import sys,json; comps=json.load(sys.stdin); print(next((c['id'] for c in comps if c.get('name')=='zammad-lab-ldap'),''))" \
      2>/dev/null || echo "")
  else
    fail "Keycloak LDAP federation creation failed (status: ${HTTP_STATUS})"
  fi
fi

if [ -n "${EXISTING_LDAP}" ]; then
  info "Triggering full LDAP sync in Keycloak..."
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KC_REALM}/user-storage/${EXISTING_LDAP}/sync?action=triggerFullSync" \
    -H "Authorization: Bearer ${KC_TOKEN}" || echo "000")
  if [ "${HTTP_STATUS}" = "200" ]; then
    pass "Keycloak LDAP full sync triggered"
  else
    fail "Keycloak LDAP full sync failed (status: ${HTTP_STATUS})"
  fi
fi

sleep 5
KC_USER_COUNT=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/users?max=100" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [ "${KC_USER_COUNT}" -ge 3 ]; then
  pass "Keycloak: ${KC_USER_COUNT} users synced from LDAP (expected ≥3)"
else
  fail "Keycloak: only ${KC_USER_COUNT} users synced from LDAP (expected ≥3)"
fi

ZAMMAD_ADMIN_IN_KC=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/users?username=zammadadmin&exact=true" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['username'] if users else '')" \
  2>/dev/null || echo "")
if [ "${ZAMMAD_ADMIN_IN_KC}" = "zammadadmin" ]; then
  pass "Keycloak: zammadadmin present after LDAP sync"
else
  fail "Keycloak: zammadadmin not found after LDAP sync"
fi

# ── PHASE 5: Keycloak OIDC Client + Zammad API (INT-06) ──────────────────────
section "Phase 5: Keycloak OIDC Client + Zammad API (INT-06)"

KC_DISC_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_BASE}/realms/${KC_REALM}/.well-known/openid-configuration" || echo "000")
if [ "${KC_DISC_STATUS}" = "200" ]; then
  pass "Keycloak OIDC discovery URL responds HTTP 200"
else
  fail "Keycloak OIDC discovery URL not accessible (status: ${KC_DISC_STATUS})"
fi

EXISTING_CLIENT=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/clients?clientId=zammad" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" \
  2>/dev/null || echo "")
if [ -n "${EXISTING_CLIENT}" ]; then
  pass "Keycloak OIDC client 'zammad' already registered"
else
  info "Registering Keycloak OIDC client 'zammad'..."
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KC_REALM}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"zammad\",
      \"enabled\": true,
      \"protocol\": \"openid-connect\",
      \"publicClient\": false,
      \"redirectUris\": [\"http://localhost:${ZAMMAD_PORT}/*\"],
      \"webOrigins\": [\"http://localhost:${ZAMMAD_PORT}\"],
      \"secret\": \"zammad-secret-05\",
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": true
    }" || echo "000")
  if [ "${HTTP_STATUS}" = "201" ]; then
    pass "Keycloak OIDC client 'zammad' created"
  else
    fail "Keycloak OIDC client 'zammad' creation failed (status: ${HTTP_STATUS})"
  fi
fi

info "Configuring Zammad LDAP source and OIDC channel via API..."
ZAMMAD_AUTH_HDR="Authorization: Basic $(echo -n 'admin@example.com:admin' | base64)"

ZAMMAD_LDAP_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "http://localhost:${ZAMMAD_PORT}/api/v1/ldap_configs" \
  -H "Content-Type: application/json" \
  -H "${ZAMMAD_AUTH_HDR}" \
  -d "{\"name\":\"IT-Stack OpenLDAP\",\"host\":\"zammad-int-ldap\",\"port\":389,\"bind_dn\":\"cn=readonly,dc=lab,dc=local\",\"bind_pw\":\"ReadOnly05!\",\"base_dn\":\"cn=users,cn=accounts,dc=lab,dc=local\",\"uid\":\"uid\",\"last_name\":\"sn\",\"first_name\":\"givenName\",\"email\":\"mail\",\"active\":true}" \
  2>/dev/null || echo "000")
if [[ "${ZAMMAD_LDAP_HTTP}" =~ ^(200|201|422|401)$ ]]; then
  pass "Zammad LDAP config API responded (HTTP ${ZAMMAD_LDAP_HTTP})"
else
  fail "Zammad LDAP config API unreachable (HTTP ${ZAMMAD_LDAP_HTTP})"
fi

ZAMMAD_OIDC_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "http://localhost:${ZAMMAD_PORT}/api/v1/channels" \
  -H "Content-Type: application/json" \
  -H "${ZAMMAD_AUTH_HDR}" \
  -d "{\"adapter\":\"auth_oidc\",\"options\":{\"name\":\"Keycloak\",\"issuer\":\"http://zammad-int-keycloak:8080/realms/it-stack\",\"uid_field\":\"sub\",\"client_id\":\"zammad\",\"client_secret\":\"zammad-secret-05\",\"display_name\":\"Login with Keycloak\"}}" \
  2>/dev/null || echo "000")
if [[ "${ZAMMAD_OIDC_HTTP}" =~ ^(200|201|422|401)$ ]]; then
  pass "Zammad OIDC channel API responded (HTTP ${ZAMMAD_OIDC_HTTP})"
else
  fail "Zammad OIDC channel API unreachable (HTTP ${ZAMMAD_OIDC_HTTP})"
fi

# ── PHASE 6: OIDC Token Issuance (INT-06) ────────────────────────────────────
section "Phase 6: OIDC Token Issuance (INT-06)"

info "Requesting OIDC token from Keycloak for zammadadmin..."
OIDC_RESP=$(curl -sf \
  -X POST "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/token" \
  -d "client_id=zammad" \
  -d "client_secret=zammad-secret-05" \
  -d "grant_type=password" \
  -d "username=zammadadmin" \
  -d "password=Lab05Password!" \
  -d "scope=openid profile email" \
  2>/dev/null || echo "")
OIDC_ACCESS=$(echo "${OIDC_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")

if [ -n "${OIDC_ACCESS}" ]; then
  pass "OIDC access token obtained for zammadadmin"
else
  fail "OIDC token not obtained for zammadadmin — KC LDAP sync or client config issue"
fi

if [ -n "${OIDC_ACCESS}" ]; then
  KC_SUB=$(curl -sf \
    "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/userinfo" \
    -H "Authorization: Bearer ${OIDC_ACCESS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sub',''))" 2>/dev/null || echo "")
  if [ -n "${KC_SUB}" ]; then
    pass "KC userinfo: sub claim present (${KC_SUB})"
  else
    fail "KC userinfo: sub claim missing"
  fi

  KC_USERNAME=$(curl -sf \
    "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/userinfo" \
    -H "Authorization: Bearer ${OIDC_ACCESS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('preferred_username',''))" 2>/dev/null || echo "")
  if [ "${KC_USERNAME}" = "zammadadmin" ]; then
    pass "KC userinfo: preferred_username=zammadadmin confirmed"
  else
    fail "KC userinfo: preferred_username='${KC_USERNAME}' (expected zammadadmin)"
  fi
fi

if [ -n "${OIDC_ACCESS}" ]; then
  ACTIVE=$(curl -sf \
    -X POST "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/token/introspect" \
    -d "client_id=zammad" \
    -d "client_secret=zammad-secret-05" \
    -d "token=${OIDC_ACCESS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',''))" 2>/dev/null || echo "")
  if [ "${ACTIVE}" = "True" ] || [ "${ACTIVE}" = "true" ]; then
    pass "OIDC token introspection: active=true"
  else
    fail "OIDC token introspection: active='${ACTIVE}' (expected true)"
  fi
fi

# ── PHASE 7: Zammad Integration Checks ───────────────────────────────────────
section "Phase 7: Zammad Integration Environment"

RS_ENV=$(docker inspect zammad-int-railsserver --format '{{range .Config.Env}}{{.}} {{end}}' 2>/dev/null || echo "")

echo "${RS_ENV}" | grep -q "RAILS_MAX_THREADS=5" \
  && pass "RAILS_MAX_THREADS=5" \
  || fail "RAILS_MAX_THREADS not set"

echo "${RS_ENV}" | grep -q "REDIS_URL=redis://:Lab05Redis!" \
  && pass "REDIS_URL set with Lab05Redis! password" \
  || fail "REDIS_URL not set correctly"

echo "${RS_ENV}" | grep -q "POSTGRESQL_HOST=zammad-int-postgresql" \
  && pass "POSTGRESQL_HOST=zammad-int-postgresql" \
  || fail "POSTGRESQL_HOST not set"

echo "${RS_ENV}" | grep -q "ELASTICSEARCH_HOST=zammad-int-elasticsearch" \
  && pass "ELASTICSEARCH_HOST=zammad-int-elasticsearch" \
  || fail "ELASTICSEARCH_HOST not set"

echo "${RS_ENV}" | grep -q "KEYCLOAK_URL=http://zammad-int-keycloak:8080" \
  && pass "KEYCLOAK_URL set (INT-06 env var present)" \
  || warn "KEYCLOAK_URL not in container env (configured at app level)"

echo "${RS_ENV}" | grep -q "KEYCLOAK_CLIENT_ID=zammad" \
  && pass "KEYCLOAK_CLIENT_ID=zammad (INT-06 env var present)" \
  || warn "KEYCLOAK_CLIENT_ID not in container env (configured at app level)"

ES_INDICES=$(curl -sf "${ES_URL}/_cat/indices?v" 2>/dev/null || echo "")
if [ -n "${ES_INDICES}" ]; then
  pass "Elasticsearch indices endpoint responds"
else
  fail "Elasticsearch indices unreachable"
fi

HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "http://localhost:${MAILHOG_PORT}/" 2>/dev/null || echo "000")
if [[ "${HTTP}" =~ ^(200|302)$ ]]; then
  pass "Mailhog web UI accessible (HTTP ${HTTP})"
else
  fail "Mailhog web UI unreachable (HTTP ${HTTP})"
fi

# ── PHASE 8: FreePBX CTI WireMock Stubs (INT-10) ──────────────────────────
section "Phase 8: FreePBX CTI WireMock Stubs (INT-10)"
FREEPBX_MOCK_URL="http://localhost:8027"

if curl -sf "${FREEPBX_MOCK_URL}/__admin/health" > /dev/null 2>&1; then
  pass "WireMock (FreePBX mock) health endpoint accessible (:8027)"
else
  fail "WireMock not accessible at ${FREEPBX_MOCK_URL}"
fi

info "Registering WireMock stubs for FreePBX REST API..."

# FreePBX REST originate stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${FREEPBX_MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/api/rest.php"},
    "response": {"status": 200,
                 "body": "{\"name\":\"Originate\",\"success\":true,\"channel\":\"SIP/101\"}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
[ "${HTTP_STATUS}" = "201" ] \
  && pass "WireMock stub: FreePBX /api/rest.php originate registered" \
  || fail "WireMock stub: FreePBX /api/rest.php failed (HTTP $HTTP_STATUS)"

# FreePBX admin config stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${FREEPBX_MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "url": "/admin/config.php"},
    "response": {"status": 200, "body": "<html><title>FreePBX Admin</title></html>"}
  }' || echo "000")
[ "${HTTP_STATUS}" = "201" ] \
  && pass "WireMock stub: FreePBX /admin/config.php registered" \
  || fail "WireMock stub: FreePBX /admin/config.php failed (HTTP $HTTP_STATUS)"

# Verify originate mock responds
if curl -sf -X POST "${FREEPBX_MOCK_URL}/api/rest.php" \
     -H "Content-Type: application/json" \
     -d '{"action":"Originate","Channel":"SIP/pbxuser1","Exten":"pbxadmin","Context":"zammad-cti"}' \
     | grep -q 'success'; then
  pass "WireMock FreePBX originate returns success"
else
  fail "WireMock FreePBX originate not responding correctly"
fi

# Assert FREEPBX_* env vars in railsserver
for envpair in "FREEPBX_URL=http://zammad-int-mock" "FREEPBX_AMI_HOST=zammad-int-mock" "FREEPBX_AMI_PORT=5038" "FREEPBX_AMI_USER=admin"; do
  KEY="${envpair%%=*}"
  VAL="${envpair#*=}"
  RS_VAL=$(docker inspect zammad-int-railsserver --format '{{range .Config.Env}}{{.}} {{end}}' 2>/dev/null \
    | grep -o "${KEY}=[^ ]*" | head -1 || echo "")
  if echo "${RS_VAL}" | grep -q "${VAL}"; then
    pass "Env: ${KEY} set correctly in railsserver"
  else
    fail "Env: ${KEY} not set or wrong in railsserver (got: '${RS_VAL}')"
  fi
done

# Zammad railsserver → WireMock (FreePBX mock) reachable
if docker exec zammad-int-railsserver curl -sf \
     "http://zammad-int-mock:8080/admin/config.php" > /dev/null 2>&1; then
  pass "Zammad railsserver → WireMock (FreePBX mock) reachable"
else
  fail "Zammad railsserver cannot reach WireMock (FreePBX mock)"
fi

# Register Zammad CTI phone channel (INT-10) via Zammad API
ZAMMAD_AUTH_HDR="Authorization: Basic $(echo -n 'admin@example.com:admin' | base64)"
CTI_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "http://localhost:${ZAMMAD_PORT}/api/v1/channels" \
  -H "Content-Type: application/json" \
  -H "${ZAMMAD_AUTH_HDR}" \
  -d '{"adapter":"cti_generic_api","options":{"name":"FreePBX CTI","inbound":{"adapter":"http","options":{"host":"zammad-int-mock","port":5038}},"outbound":{"adapter":"http","options":{"url":"http://zammad-int-mock:8080/api/rest.php","user":"admin","password":"Admin05!"}}}}' \
  2>/dev/null || echo "000")
[[ "${CTI_HTTP}" =~ ^(200|201|422|401)$ ]] \
  && pass "Zammad CTI phone channel API responded (HTTP ${CTI_HTTP})" \
  || fail "Zammad CTI phone channel API unreachable (HTTP ${CTI_HTTP})"

# ── Results (INT-06 + INT-10) ──────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete — INT-06: Zammad↔Keycloak OIDC + INT-10: Zammad↔FreePBX CTI"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
