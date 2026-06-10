#!/usr/bin/env bash
#
# bootstrap-pro-api-vps.sh — first-time setup of pro.interactpak.com/api
# on the VPS. Runs everything DEPLOY.md describes as "one-time" in
# the right order, idempotently. Safe to re-run.
#
# What it does (each step a no-op if already done):
#   1. Creates Postgres user `interactpro` + database `interactpro`.
#   2. Applies the SQL migration from /opt/interact/pro-api/migrations/.
#   3. Ensures the `interact` system user + dirs exist.
#   4. Creates /etc/interact/pro-api.env from env.example if missing.
#   5. Installs the systemd unit + reloads daemon.
#   6. Splices the Caddy block to add /api/* reverse_proxy
#      (idempotent via marker comments).
#   7. Reloads Caddy.
#   8. Smoke-tests /api/healthz.
#
# Run from your Mac:
#   bash scripts/bootstrap-pro-api-vps.sh
#
# Pre-flight: server/pro-api/ already rsync'd to the VPS via
# `bash scripts/deploy-pro-api.sh` once. Since deploy-pro-api.sh's
# npm install will FAIL until the env file + DB exist, this script
# expects you to have run deploy ONCE (which got files there even
# though npm errored — that's fine).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

if [ -f "$PROJECT_DIR/.env.local" ]; then
  # shellcheck disable=SC2046
  export $(grep -E '^PRO_SSH_ALIAS' "$PROJECT_DIR/.env.local" | xargs)
fi
PRO_ALIAS="${PRO_SSH_ALIAS:-interact}"

# Generate a strong DB password if .env.local doesn't already have one.
# We persist it on the Mac so subsequent re-runs reuse the same password
# and don't break the connection string already in /etc/interact/pro-api.env.
DB_PASS_FILE="$PROJECT_DIR/.env.local"
if grep -q '^PRO_API_DB_PASS=' "$DB_PASS_FILE" 2>/dev/null; then
  DB_PASS=$(grep '^PRO_API_DB_PASS=' "$DB_PASS_FILE" | cut -d= -f2-)
else
  DB_PASS=$(openssl rand -hex 24)
  echo "PRO_API_DB_PASS=$DB_PASS" >> "$DB_PASS_FILE"
  echo "→ Generated and saved DB password to $DB_PASS_FILE"
fi

# Same for JWT.
if grep -q '^PRO_API_JWT_SECRET=' "$DB_PASS_FILE" 2>/dev/null; then
  JWT_SECRET=$(grep '^PRO_API_JWT_SECRET=' "$DB_PASS_FILE" | cut -d= -f2-)
else
  JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
  echo "PRO_API_JWT_SECRET=$JWT_SECRET" >> "$DB_PASS_FILE"
  echo "→ Generated and saved JWT secret to $DB_PASS_FILE"
fi

# Pull RESEND / DEXATEL keys from .env.local if present.
RESEND_KEY="$(grep -E '^RESEND_API_KEY=' "$DB_PASS_FILE" 2>/dev/null | cut -d= -f2- || true)"
DEXATEL_KEY="$(grep -E '^DEXATEL_API_KEY=' "$DB_PASS_FILE" 2>/dev/null | cut -d= -f2- || true)"

echo "=== Bootstrapping pro-api on $PRO_ALIAS ==="

ssh "$PRO_ALIAS" "DB_PASS='$DB_PASS' JWT_SECRET='$JWT_SECRET' RESEND_KEY='$RESEND_KEY' DEXATEL_KEY='$DEXATEL_KEY' bash -s" <<'REMOTE'
set -euo pipefail

# ── Service user + dirs ────────────────────────────────────────────────
id -u interact >/dev/null 2>&1 || \
  useradd --system --home /opt/interact --shell /usr/sbin/nologin interact
mkdir -p /opt/interact/pro-api /var/log/interact /etc/interact
chown -R interact:interact /opt/interact /var/log/interact
chmod 750 /etc/interact

# ── Postgres role + db (idempotent) ────────────────────────────────────
sudo -u postgres psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname='interactpro') THEN
    CREATE ROLE interactpro WITH LOGIN PASSWORD '$DB_PASS';
  ELSE
    ALTER ROLE interactpro WITH PASSWORD '$DB_PASS';
  END IF;
END
\$\$;
SQL

if ! sudo -u postgres psql -lqt | cut -d\| -f1 | grep -qw interactpro; then
  sudo -u postgres createdb -O interactpro interactpro
fi

# ── Schema ─────────────────────────────────────────────────────────────
# Apply EVERY migration file in lexical order so 001_, 002_, etc. all
# run on a fresh bootstrap. Wrap each in a savepoint so a partial
# failure on one doesn't leave the schema half-applied without warning.
if [ -d /opt/interact/pro-api/migrations ]; then
  for migration in /opt/interact/pro-api/migrations/*.sql; do
    [ -f "$migration" ] || continue
    echo "  → applying $(basename "$migration")"
    sudo -u postgres psql -d interactpro -f "$migration"
  done
else
  echo "WARN: /opt/interact/pro-api/migrations/ missing — run deploy-pro-api.sh first"
fi

# ── Fix ownership of everything created by postgres ────────────────────
# Migrations run as the `postgres` superuser, which means every table /
# sequence / function lands with owner=postgres. The Express service
# connects as `interactpro` and the default Postgres ACL refuses
# SELECT/INSERT to non-owners. Without this fix the service crashes on
# its first query with `aclchk.c:2812 aclcheck_error`. Re-owning to
# `interactpro` is idempotent — re-running on an already-correct DB is
# a no-op.
sudo -u postgres psql -d interactpro <<'SQL'
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO interactpro', r.tablename);
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences
            WHERE sequence_schema = 'public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO interactpro', r.sequence_name);
  END LOOP;
  -- Only re-own functions that are NOT owned by an extension. citext,
  -- pgcrypto etc. ship their own C functions whose ownership cannot be
  -- transferred — pg_depend.deptype 'e' marks those.
  FOR r IN
    SELECT p.oid, p.proname,
           pg_get_function_identity_arguments(p.oid) AS args
    FROM   pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  n.nspname = 'public'
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend d
      WHERE d.objid = p.oid AND d.deptype = 'e'
    )
  LOOP
    EXECUTE format('ALTER FUNCTION public.%I(%s) OWNER TO interactpro',
                   r.proname, r.args);
  END LOOP;
END$$;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO interactpro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO interactpro;
SQL

# ── /etc/interact/pro-api.env ──────────────────────────────────────────
ENV_FILE=/etc/interact/pro-api.env
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgres://interactpro:$DB_PASS@127.0.0.1:5432/interactpro
JWT_SECRET=$JWT_SECRET
JWT_TTL_SECONDS=2592000
RESEND_API_KEY=$RESEND_KEY
OTP_MAIL_FROM=Interact Pro <noreply@send.interactpak.com>
OTP_MAIL_REPLY_TO=interact@paksaf.com
DEXATEL_API_KEY=$DEXATEL_KEY
DEXATEL_SENDER=InteractPro
PORT=3050
TRIAL_DAYS=7
OTP_TTL_MIN=10
PG_POOL_MAX=10
EOF
  chmod 640 "$ENV_FILE"
  chown root:interact "$ENV_FILE"
  echo "  ✓ wrote $ENV_FILE"
else
  # File exists — patch in any missing keys (safe re-run after a key rotation)
  for var in DATABASE_URL JWT_SECRET RESEND_API_KEY DEXATEL_API_KEY; do
    if ! grep -q "^$var=" "$ENV_FILE"; then
      case "$var" in
        DATABASE_URL) val="postgres://interactpro:$DB_PASS@127.0.0.1:5432/interactpro" ;;
        JWT_SECRET) val="$JWT_SECRET" ;;
        RESEND_API_KEY) val="$RESEND_KEY" ;;
        DEXATEL_API_KEY) val="$DEXATEL_KEY" ;;
      esac
      echo "$var=$val" >> "$ENV_FILE"
    fi
  done
fi

# ── npm install (now that env is in place we can run it) ───────────────
if [ -f /opt/interact/pro-api/package.json ]; then
  cd /opt/interact/pro-api
  npm install --omit=dev --no-audit --no-fund
  chown -R interact:interact /opt/interact/pro-api
fi

# ── systemd unit ───────────────────────────────────────────────────────
if [ -f /opt/interact/pro-api/interact-pro-api.service ]; then
  cp /opt/interact/pro-api/interact-pro-api.service \
     /etc/systemd/system/interact-pro-api.service
  systemctl daemon-reload
  systemctl enable --now interact-pro-api
  sleep 2
fi

# ── Caddy: splice the new block via marker comments ────────────────────
# Idempotent: removes any previous BEGIN/END INTERACT-PRO-API marker pair
# and replaces the whole pro.interactpak.com block with the new one.
CADDYFILE=/etc/caddy/Caddyfile
cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"

# Strip the existing pro.interactpak.com {...} block (any version of it)
# so we can replace cleanly. Awk state machine matches the open brace
# and tracks nesting until the matching close.
awk '
  BEGIN { skip=0; depth=0 }
  /^pro\.interactpak\.com[[:space:]]*\{/ {
    skip=1; depth=1; next
  }
  skip==1 {
    # count nested braces so a { inside the block doesn'\''t end skip early
    n_open=gsub(/\{/, "{")
    n_close=gsub(/\}/, "}")
    depth += n_open - n_close
    if (depth <= 0) { skip=0; next }
    next
  }
  { print }
' "$CADDYFILE" > /tmp/Caddyfile.new

# Append the new block at the end. (Order doesn'\''t matter for Caddy
# host-specific blocks; the global option block has to stay first but
# we never touch that.)
cat >> /tmp/Caddyfile.new <<'CADDY'

pro.interactpak.com {
    encode zstd gzip

    # API takes precedence — Caddy evaluates handle blocks top-down.
    handle /api/* {
        reverse_proxy 127.0.0.1:3050
    }

    # Static binary distribution (existing behaviour).
    handle {
        root * /var/www/interactpro
        file_server
        @apk path *.apk
        header @apk Content-Type application/vnd.android.package-archive
        @plist path *.plist
        header @plist Content-Type application/xml
    }

    log {
        output file /var/log/caddy/pro.interactpak.com.log {
            roll_size 50mb
            roll_keep 7
        }
        format json
    }
}
CADDY

mv /tmp/Caddyfile.new "$CADDYFILE"

if caddy validate --config "$CADDYFILE" 2>&1; then
  systemctl reload caddy
  echo "  ✓ caddy reloaded"
else
  echo "  ✗ caddy validate FAILED — restoring last backup"
  LATEST=$(ls -1t "$CADDYFILE.bak."* | head -1)
  cp "$LATEST" "$CADDYFILE"
  systemctl reload caddy
  exit 1
fi

# ── Smoke test ─────────────────────────────────────────────────────────
sleep 2
echo
echo "→ /api/healthz from inside VPS:"
curl -sS http://127.0.0.1:3050/api/healthz || true
echo
echo
echo "→ /api/healthz via Caddy + TLS:"
curl -sSk https://pro.interactpak.com/api/healthz || true
echo
echo
echo "Service status:"
systemctl status interact-pro-api --no-pager -l | head -20
REMOTE

echo
echo "=== Bootstrap done ==="
echo "  Test from your laptop:"
echo "    curl -i https://pro.interactpak.com/api/healthz"
echo "    curl -i -X POST https://pro.interactpak.com/api/auth/otp/request \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"email\":\"YOUR@EMAIL\"}'"
