#!/usr/bin/env bash
# scripts/docker-install.sh
# Fleetbase Docker installer (production-only)
# --------------------------------------------
set -euo pipefail

###############################################################################
# 1. Set fixed values
###############################################################################
HOST="0.0.0.0"
ENVIRONMENT="production"
echo "➜  Using host: $HOST"
echo "➜  Environment: $ENVIRONMENT"

USE_HTTPS=true
APP_DEBUG=false
SC_SECURE=true

###############################################################################
# 2. Determine project root no matter where script is called from
###############################################################################
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$PROJECT_ROOT"

###############################################################################
# 3. Generate a fresh Laravel APP_KEY
###############################################################################
if ! command -v openssl >/dev/null 2>&1; then
  echo "✖ openssl is required but not found. Install it and retry." >&2
  exit 1
fi
APP_KEY="base64:$(openssl rand -base64 32 | tr -d '\n')"
echo "✔  Generated APP_KEY"

###############################################################################
# 4. Ensure docker-compose.override.yml is present & updated
###############################################################################
OVERRIDE_FILE="docker-compose.override.yml"

# url helpers
SCHEME_API="https"
SCHEME_CONSOLE="https"

update_override_with_yq() {
  yq -i "
    .services.application.environment.APP_KEY         = \"$APP_KEY\" |
    .services.application.environment.CONSOLE_HOST    = \"$SCHEME_CONSOLE://$HOST:4200\" |
    .services.application.environment.ENVIRONMENT     = \"$ENVIRONMENT\" |
    .services.application.environment.APP_DEBUG       = \"$APP_DEBUG\"
  " "$OVERRIDE_FILE"
  echo "✔  $OVERRIDE_FILE updated (yq)"
}

create_override() {
  cat > "$OVERRIDE_FILE" <<YML
services:
  application:
    environment:
      APP_KEY: "$APP_KEY"
      CONSOLE_HOST: "$SCHEME_CONSOLE://$HOST:4200"
      ENVIRONMENT: "$ENVIRONMENT"
      APP_DEBUG: "$APP_DEBUG"
YML
  echo "✔  $OVERRIDE_FILE written"
}

if [[ -f "$OVERRIDE_FILE" ]]; then
  if command -v yq >/dev/null 2>&1; then
    update_override_with_yq
  else
    cp "$OVERRIDE_FILE" "${OVERRIDE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo "ℹ︎  Existing $OVERRIDE_FILE backed up (no yq found — recreating)"
    create_override
  fi
else
  create_override
fi

###############################################################################
# 5. Write console/fleetbase.config.json atomically
###############################################################################
CONFIG_DIR="console"
CONFIG_PATH="$CONFIG_DIR/fleetbase.config.json"
mkdir -p "$CONFIG_DIR"

cat > "${CONFIG_PATH}.tmp" <<JSON
{
  "API_HOST": "$SCHEME_API://$HOST:8000",
  "SOCKETCLUSTER_HOST": "$HOST",
  "SOCKETCLUSTER_PORT": "38000",
  "SOCKETCLUSTER_SECURE": "$SC_SECURE"
}
JSON
mv -f "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
echo "✔  $CONFIG_PATH updated"

###############################################################################
# 6. Start stack, wait for DB, then run deploy
###############################################################################
echo "⏳  Starting Fleetbase containers..."
docker-compose up -d

###############################################################################
# 6a. Wait for the database container to be ready
###############################################################################
DB_SERVICE="database"
DB_WAIT_TIMEOUT=60

echo "⏳  Waiting for "$DB_SERVICE" to become ready (timeout: ${DB_WAIT_TIMEOUT}s)…"
DB_CONTAINER=$(docker compose ps -q "$DB_SERVICE")

if [ -z "$DB_CONTAINER" ]; then
  echo "✖  Cannot find a running container for service \"$DB_SERVICE\". Check docker-compose.yml."
  exit 1
fi

# If the service defines a HEALTHCHECK we can rely on it…
if docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" &>/dev/null; then
  SECONDS=0
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER")" = "healthy" ]; do
    if [ "$SECONDS" -ge "$DB_WAIT_TIMEOUT" ]; then
      echo "✖  Timed out waiting for the database to become healthy."
      exit 1
    fi
    sleep 2
  done
  sleep 12
else
  # Fallback: use mysqladmin ping (works for MySQL / MariaDB)
  SECONDS=0
  until docker compose exec "$DB_SERVICE" sh -c "mysqladmin --silent --wait=1 -uroot -h127.0.0.1 ping" &>/dev/null; do
    if [ "$SECONDS" -ge "$DB_WAIT_TIMEOUT" ]; then
      echo "✖  Timed out waiting for the database to accept connections."
      exit 1
    fi
    sleep 2
  done
fi
echo "✔  Database is ready."

###############################################################################
# 6b. Run the deploy script inside the application container
###############################################################################
echo "⏳  Running deploy script inside the application container..."
docker compose exec application bash -c "./deploy.sh"
docker-compose up -d

echo
echo "🏁  Fleetbase is up!"
printf "    API     → %s://%s:8000\n"    "$SCHEME_API"     "$HOST"
printf "    Console → %s://%s:4200\n\n" "$SCHEME_CONSOLE" "$HOST"
