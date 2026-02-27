# Dockerfile — IT-Stack ZAMMAD wrapper
# Module 11 | Category: communications | Phase: 2
# Base image: zammad/zammad-docker-compose:latest

FROM zammad/zammad-docker-compose:latest

# Labels
LABEL org.opencontainers.image.title="it-stack-zammad" \
      org.opencontainers.image.description="Zammad help desk and ticketing" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-zammad"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/zammad/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
