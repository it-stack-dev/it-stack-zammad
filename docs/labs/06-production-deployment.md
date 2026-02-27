# Lab 11-06 — Production Deployment

**Module:** 11 — Zammad help desk and ticketing  
**Duration:** See [lab manual](https://github.com/it-stack-dev/it-stack-docs)  
**Test Script:** 	ests/labs/test-lab-11-06.sh  
**Compose File:** docker/docker-compose.production.yml

## Objective

Deploy zammad in production with HA, monitoring, backup, and DR.

## Prerequisites

- Labs 11-01 through 11-05 pass
- Prerequisite services running

## Steps

### 1. Prepare Environment

```bash
cd it-stack-zammad
cp .env.example .env  # edit as needed
```

### 2. Start Services

```bash
make test-lab-06
```

Or manually:

```bash
docker compose -f docker/docker-compose.production.yml up -d
```

### 3. Verify

```bash
docker compose ps
curl -sf http://localhost:3000/health
```

### 4. Run Test Suite

```bash
bash tests/labs/test-lab-11-06.sh
```

## Expected Results

All tests pass with FAIL: 0.

## Cleanup

```bash
docker compose -f docker/docker-compose.production.yml down -v
```

## Troubleshooting

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for common issues.
