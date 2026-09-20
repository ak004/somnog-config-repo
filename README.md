# somnog-config-repo

Deploy-time config for SomNOG. This repo does not build anything - it just
says which images to run and how. It's what gets cloned onto the server.

- `docker-compose.yml` - infra (postgres, rabbitmq, redis, mailhog), the app
  services pulled from GHCR, and the nginx that fronts them all.
- `nginx/` - the reverse proxy config. One domain, two upstreams: `/api` to
  the gateway, everything else to the frontend.
- `init/01-schemas.sql` - creates the `auth`, `events` and `notify` schemas the
  first time the postgres volume is created.
- `images.env` - which image tag each pipeline last published. Bumped
  automatically by the backend and frontend CI - don't hand-edit it, the next
  push just overwrites it.
- `.env.example` - secrets and per-service config. Copy to `.env` on the
  server and fill it in; `.env` is gitignored and never committed.
- `scripts/deploy-poll.sh` - run on a schedule on the server. If this repo's
  `main` has moved, it pulls, then `docker compose pull` + `up -d`.

## What listens where

Only port 80 is published to the world. Everything else is either internal to
the compose network or bound to `127.0.0.1`, reachable over an ssh tunnel.

| | |
| --- | --- |
| `http://<domain>/` | frontend (Next.js) |
| `http://<domain>/api` | gateway (NestJS), Swagger at `/api/docs` |
| `127.0.0.1:3000` | gateway, direct - for `curl` on the box |
| `127.0.0.1:4200` | frontend, direct |
| `127.0.0.1:8025` | MailHog inbox - **no authentication**, keep it local |

## First-time server setup

```bash
git clone git@github.com:ak004/somnog-config-repo.git /opt/somnog
cd /opt/somnog
cp .env.example .env   # fill in real secrets, set APP_WEB_URL to the domain
chmod +x scripts/deploy-poll.sh
docker compose --env-file .env --env-file images.env up -d
```

The `migrate` service runs first and to completion: it applies every service's
Prisma migrations, then (while `SEED_DEMO_DATA=true`) the demo seed. Watch it
with `docker compose logs migrate`. Nothing else starts until it exits 0, so a
failure there is a stack that doesn't come up - which is the intended
behaviour, not a broken deploy.

Then add the poll script to cron so new images roll out automatically:

```bash
sudo crontab -e
```

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root
*/2 * * * * /opt/somnog/scripts/deploy-poll.sh >> /var/log/somnog-deploy.log 2>&1
```

Whichever user's crontab this goes in has to be able to run `docker` and to
`git pull` this repo unattended - so a deploy key with no passphrase, or an
https clone with a token in the remote url. Test it once by hand as that user
before trusting the schedule:

```bash
sudo -u root /opt/somnog/scripts/deploy-poll.sh
```

Overlapping runs are already handled: the script takes an flock and exits if a
previous deploy is still pulling.

Keep the log from growing forever:

```bash
sudo tee /etc/logrotate.d/somnog-deploy <<'CONF'
/var/log/somnog-deploy.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
}
CONF
```

### systemd timer instead of cron

Equivalent, with `journalctl -u somnog-deploy` instead of a log file and no
PATH/HOME surprises:

```ini
# /etc/systemd/system/somnog-deploy.service
[Unit]
Description=Pull somnog config repo and roll out new images
[Service]
Type=oneshot
WorkingDirectory=/opt/somnog
ExecStart=/opt/somnog/scripts/deploy-poll.sh
```

```ini
# /etc/systemd/system/somnog-deploy.timer
[Unit]
Description=Check for new somnog deploys every 2 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now somnog-deploy.timer
```

## How a deploy happens

1. Someone pushes to `main` on the backend or frontend repo.
2. Its CI builds an image (five, for the backend: the four services plus the
   `migrate` one-shot) and pushes them to GHCR.
3. The last CI job checks out this repo and bumps `BACKEND_IMAGE_TAG` or
   `FRONTEND_IMAGE_TAG` in `images.env`, then commits and pushes.
4. Within 2 minutes, `deploy-poll.sh` on the server notices `main` moved,
   pulls the new images, runs `migrate` to completion, and restarts the
   affected containers.

No SSH from CI to the server, no server pushing to anything - the server only
ever pulls.

nginx follows the restarts on its own: it resolves `gateway` and `frontend`
through Docker's DNS on every request rather than once at startup, so a
recreated container's new ip is picked up without a reload.

## Migrations and demo data

`migrate` is a one-shot container built from the backend repo
(`docker/Dockerfile.migrate`), tagged with the same commit sha as the services
so the schema always matches the code. It runs on every `up -d`, which is safe:
`prisma migrate deploy` applies only what is missing, and every row the seeds
write is an upsert.

Demo data is controlled by `SEED_DEMO_DATA` in `.env`. Turn it off before this
database holds anything real - the seeded accounts have published passwords:

| Role | Email | Password |
| --- | --- | --- |
| ADMIN | admin@somnog.so | Admin12345 |
| ORGANIZER | organizer@somnog.so | Organizer12345 |
| SPEAKER | speaker@somnog.so | Speaker12345 |
| ATTENDEE | attendee@somnog.so | Attendee12345 |

```bash
docker compose --env-file .env --env-file images.env run --rm migrate   # re-run by hand
```

## Adding TLS

The domain points at port 80 today. Once that resolves, get a certificate -
the http-01 challenge path is already served by nginx from the `certbot_www`
volume:

```bash
# plain `docker run` - certbot is not a compose service, it just borrows the
# two volumes nginx already mounts (the compose project is named `somnog`, so
# they are somnog_certbot_www / somnog_certbot_conf).
docker run --rm \
  -v somnog_certbot_www:/var/www/certbot \
  -v somnog_certbot_conf:/etc/letsencrypt \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  -d somnog.example.com --email you@example.com --agree-tos --no-eff-email
```

Then, in `nginx/conf.d/somnog.conf`, turn the `server` block into a redirect to
https and add a second block on 443 with:

```nginx
    listen 443 ssl;
    http2 on;
    ssl_certificate     /etc/letsencrypt/live/somnog.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/somnog.example.com/privkey.pem;
```

(keeping the same two `location` blocks), uncomment `- '443:443'` in
`docker-compose.yml`, set `APP_WEB_URL=https://somnog.example.com` in `.env`,
and `docker compose up -d nginx gateway`.

Renewal is a second cron line: the same `docker run` with `renew` in place of
`certonly ...`, then `docker compose exec nginx nginx -s reload`.

Note the `/.well-known/acme-challenge/` location has to stay on the port-80
block after the redirect - certbot renews over http.

## The frontend calls /api on this same origin

`NEXT_PUBLIC_API_URL` is inlined into the frontend's JS bundle at `next build`
time - it is not a runtime setting, and putting it in `.env` here does nothing.
It is deliberately left **unset** on the frontend repo's CI: with nginx
fronting both apps, the browser calls `/api/...` on the same origin it loaded
the page from, so nothing about the domain is baked into the bundle and there
is no CORS preflight.

Set it (`somnog-ems-frontend` -> Settings -> Secrets and variables -> Actions
-> Variables) only if the gateway ever moves to its own origin - and then
`APP_WEB_URL` here has to allow that origin, since the gateway's CORS uses it.
