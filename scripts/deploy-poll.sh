#!/usr/bin/env bash
# Run on the server on a schedule (see README for the cron line). Pulls this
# repo; if main moved, pulls the new images and restarts anything changed.
set -euo pipefail
cd "$(dirname "$0")/.."

git fetch origin main -q

if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then
  exit 0
fi

git pull --ff-only origin main

docker compose --env-file .env --env-file images.env pull
docker compose --env-file .env --env-file images.env up -d --remove-orphans
docker image prune -f
