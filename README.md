# somnog-config-repo

Deploy-time config for SomNOG. This repo does not build anything - it just
says which images to run and how. It's what gets cloned onto the server.

- `docker-compose.yml` - infra (postgres, rabbitmq, redis, mailhog) plus the
  app services, pulled from GHCR.
- `images.env` - which image tag each pipeline last published. Bumped
  automatically by the backend (and later frontend) CI - don't hand-edit it,
  the next push just overwrites it.
- `.env.example` - secrets and per-service config. Copy to `.env` on the
  server and fill it in; `.env` is gitignored and never committed.
- `scripts/deploy-poll.sh` - run on a schedule on the server. If this repo's
  `main` has moved, it pulls, then `docker compose pull` + `up -d`.

## First-time server setup

```bash
git clone git@github.com:ak004/somnog-config-repo.git /opt/somnog
cd /opt/somnog
cp .env.example .env   # fill in real secrets
docker compose --env-file .env --env-file images.env up -d
```

Then add the poll script to cron so new images roll out automatically:

```
*/2 * * * * /opt/somnog/scripts/deploy-poll.sh >> /var/log/somnog-deploy.log 2>&1
```

## How a deploy happens

1. Someone pushes to `main` on the backend (or, later, frontend) repo.
2. Its CI builds an image per service and pushes it to GHCR.
3. The last CI job checks out this repo and bumps `BACKEND_IMAGE_TAG` (or
   `FRONTEND_IMAGE_TAG`) in `images.env`, then commits and pushes.
4. Within 2 minutes, `deploy-poll.sh` on the server notices `main` moved,
   pulls the new image, and restarts the affected containers.

No SSH from CI to the server, no server pushing to anything - the server only
ever pulls.
