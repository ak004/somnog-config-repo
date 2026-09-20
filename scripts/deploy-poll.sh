#!/usr/bin/env bash
# Run on the server on a schedule (see README for the cron line). Pulls this
# repo; if main moved, pulls the new images and restarts anything changed.
set -euo pipefail

# cron gives a near-empty environment. git needs HOME to find its config and
# any ssh key; docker compose needs a sane PATH.
export HOME="${HOME:-/root}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

cd "$(dirname "$0")/.."

# A pull that is still running when the next tick fires must not be joined by a
# second one - image pulls can easily outrun a 2-minute interval.
exec 9>/tmp/somnog-deploy.lock
flock -n 9 || { echo "$(date -Is) another deploy is still running - skipping"; exit 0; }

git fetch origin main -q

if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then
  exit 0
fi

echo "$(date -Is) main moved $(git rev-parse --short HEAD) -> $(git rev-parse --short origin/main), deploying"

git pull --ff-only origin main

docker compose --env-file .env --env-file images.env pull
# The one-shot `migrate` service runs to completion here, before any service
# that depends on it starts - so a deploy that changes the schema applies it
# before the new code touches the database.
docker compose --env-file .env --env-file images.env up -d --remove-orphans
docker image prune -f

echo "$(date -Is) deployed $(git rev-parse --short HEAD)"
