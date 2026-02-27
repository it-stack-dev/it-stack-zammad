#!/bin/bash
# entrypoint.sh — IT-Stack zammad container entrypoint
set -euo pipefail

echo "Starting IT-Stack ZAMMAD (Module 11)..."

# Source any environment overrides
if [ -f /opt/it-stack/zammad/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/zammad/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
