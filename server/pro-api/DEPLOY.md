# Deploying pro.interactpak.com/api

End-to-end runbook for installing the pro-api server on the VPS at
178.105.73.238 (SSH alias `interact` per `~/.ssh/config`). The server
provides the auth (email/phone OTP) + admin + version endpoints the
Flutter client expects under `https://pro.interactpak.com/api/*`.

## One-time host setup

```bash
ssh interact <<'EOF'
set -e

# 1. Postgres (skip if already installed for other apps).
which psql >/dev/null || (apt-get update && apt-get install -y postgresql)

# 2. Database + role.
sudo -u postgres psql -c "CREATE USER interactpro WITH PASSWORD 'CHANGEME';"
sudo -u postgres psql -c "CREATE DATABASE interactpro OWNER interactpro;"

# 3. Service user (skip if `interact` already exists from the translate proxy).
id -u interact >/dev/null 2>&1 || \
  useradd --system --home /opt/interact --shell /usr/sbin/nologin interact

# 4. App + log directories.
mkdir -p /opt/interact/pro-api /var/log/interact
chown -R interact:interact /opt/interact /var/log/interact
mkdir -p /etc/interact
chmod 750 /etc/interact

# 5. Node 20 (skip if already on the box from the translate proxy).
which node >/dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs)
EOF
```

## Deploy the code

From your Mac, in the project root:

```bash
rsync -av --delete \
  server/pro-api/ \
  interact:/opt/interact/pro-api/ \
  --exclude node_modules

ssh interact 'cd /opt/interact/pro-api && npm ci --omit=dev && chown -R interact:interact /opt/interact/pro-api'
```

## Apply the schema

```bash
# Apply every migration in order. Each one is idempotent (CREATE TABLE
# IF NOT EXISTS / CREATE INDEX IF NOT EXISTS / etc.) so a re-run is safe.
ssh interact 'for m in /opt/interact/pro-api/migrations/*.sql; do
  echo "→ $m"
  sudo -u postgres psql -d interactpro -f "$m"
done'
```

## Wire up secrets

```bash
# Edit on the VPS — never commit a filled-in env file.
ssh interact <<'EOF'
cp /opt/interact/pro-api/env.example /etc/interact/pro-api.env
chmod 640 /etc/interact/pro-api.env
chown root:interact /etc/interact/pro-api.env
${EDITOR:-vi} /etc/interact/pro-api.env
EOF
```

Fill in:

- `DATABASE_URL` — change `CHANGEME` to the password you used in step 2 above.
- `JWT_SECRET` — generate with `openssl rand -base64 48` and paste it.
- `RESEND_API_KEY` — the `re_...` key already saved in your password manager.
- `DEXATEL_API_KEY` — same key Qurbani Sahulat / Movento use. Leave blank in dev.

## Provision the /api/sync storage dirs (task #158)

The `/api/sync/*` endpoints write PDF blobs to `/var/www/pro/storage/<user_id>/`.
The systemd unit lists these paths under `ReadWritePaths=` so the
hardened service can write there. Run once:

```bash
ssh interact <<'EOF'
# Both dirs on the SAME filesystem (same volume = atomic rename from
# tmp into storage). Do NOT put the tmp dir under /var/tmp — the
# systemd unit's PrivateTmp=true conflicts with /var/tmp ReadWritePath
# and crashes the unit with status=226/NAMESPACE.
mkdir -p /var/www/pro/storage /var/www/pro/sync-tmp
chown -R interact:interact /var/www/pro
chmod 750 /var/www/pro/storage /var/www/pro/sync-tmp
EOF
```

## Install + start the service

```bash
ssh interact <<'EOF'
cp /opt/interact/pro-api/interact-pro-api.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now interact-pro-api
systemctl status interact-pro-api --no-pager
EOF
```

Confirm it's listening on loopback:

```bash
ssh interact 'ss -tlnp | grep 3050'
ssh interact 'journalctl -u interact-pro-api -n 30 --no-pager'
```

## Wire Caddy

```bash
# Back up the current Caddyfile, then replace the existing
# `pro.interactpak.com {...}` block with the one in Caddyfile.snippet.
ssh interact <<'EOF'
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%s)
# Manual step: paste server/pro-api/Caddyfile.snippet into /etc/caddy/Caddyfile
# replacing the existing pro.interactpak.com block.
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
EOF
```

(The reason this isn't fully automated is that other unrelated Caddy
blocks live in the same file and string-edit splicing is risky. If you
want a one-shot, the marker-block approach in `scripts/install-pro-caddy.sh`
can be re-purposed — it inserts between `# BEGIN INTERACT PRO API BLOCK`
markers idempotently.)

## Smoke test

```bash
curl -i https://pro.interactpak.com/api/healthz
# → HTTP/2 200, {"ok":true}

curl -i -X POST https://pro.interactpak.com/api/auth/otp/request \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@yourdomain.com"}'
# → HTTP/2 200, {"sentTo":"email","expiresInSec":600}
# → check your inbox for the code

curl -i https://pro.interactpak.com/api/version
# → HTTP/2 200, {"latest":"2.0.1+2","url":"...","notes":"..."}
```

## Bootstrapping your admin user

After the first sign-in, your row exists in `users` with role='user'.
Promote yourself to admin:

```bash
ssh interact 'sudo -u postgres psql -d interactpro -c "UPDATE users SET role=\\'admin\\' WHERE email=\\'YOUR@EMAIL\\';"'
```

The next `/api/auth/me` call (or app cold-start) picks up the new role
and the in-app admin panel becomes visible.

## Updating

After every code change in `server/pro-api/`:

```bash
rsync -av --delete server/pro-api/ interact:/opt/interact/pro-api/ --exclude node_modules
ssh interact 'cd /opt/interact/pro-api && npm ci --omit=dev && systemctl restart interact-pro-api'
```

## What this server does NOT do (yet)

- **Cloud sync** — `/api/sync/*` returns 503. The schema (`documents`
  table) is in place; the upload/download/manifest handlers are next
  session's work.
- **Stripe payments** — Pro is currently flipped via the admin panel
  only. A `/api/stripe/webhook` route + checkout-session creator goes
  here when you want self-serve subscriptions.
- **Token-epoch sign-out-everywhere** — admin endpoint records the
  intent in audit_log but doesn't actually invalidate every device's
  token until a `users.token_epoch` column lands. Not blocking v1.
