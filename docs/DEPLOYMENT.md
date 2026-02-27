# Deployment Guide — IT-Stack ZAMMAD

## Prerequisites

- Ubuntu 24.04 Server on lab-comm1 (10.0.50.*)
- Docker 24+ and Docker Compose v2
- Phase 1 complete: FreeIPA, Keycloak, PostgreSQL, Redis, Traefik running
- DNS entry: zammad.it-stack.lab → lab-comm1

## Deployment Steps

### 1. Create Database (PostgreSQL on lab-db1)

```sql
CREATE USER zammad_user WITH PASSWORD 'CHANGE_ME';
CREATE DATABASE zammad_db OWNER zammad_user;
```

### 2. Configure Keycloak Client

Create OIDC client $Module in realm it-stack:
- Client ID: $Module
- Valid redirect URI: https://zammad.it-stack.lab/*
- Web origins: https://zammad.it-stack.lab

### 3. Configure Traefik

Add to Traefik dynamic config:
```yaml
http:
  routers:
    zammad:
      rule: Host(\$Module.it-stack.lab\)
      service: zammad
      tls: {}
  services:
    zammad:
      loadBalancer:
        servers:
          - url: http://lab-comm1:3000
```

### 4. Deploy

```bash
# Copy production compose to server
scp docker/docker-compose.production.yml admin@lab-comm1:~/

# Deploy
ssh admin@lab-comm1 'docker compose -f docker-compose.production.yml up -d'
```

### 5. Verify

```bash
curl -I https://zammad.it-stack.lab/health
```

## Environment Variables

| Variable | Description | Default |
|---------|-------------|---------|
| DB_HOST | PostgreSQL host | lab-db1 |
| DB_PORT | PostgreSQL port | 5432 |
| REDIS_HOST | Redis host | lab-db1 |
| KEYCLOAK_URL | Keycloak base URL | https://lab-id1:8443 |
| KEYCLOAK_REALM | Keycloak realm | it-stack |
