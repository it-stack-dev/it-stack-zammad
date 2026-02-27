# Architecture — IT-Stack ZAMMAD

## Overview

Zammad is the customer service platform providing ticket management, live chat, and knowledge base, integrated with Keycloak OIDC.

## Role in IT-Stack

- **Category:** communications
- **Phase:** 2
- **Server:** lab-comm1 (10.0.50.14)
- **Ports:** 3000 (HTTP)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → zammad → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
