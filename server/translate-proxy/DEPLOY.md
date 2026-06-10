# Deploying the DeepSeek translate proxy on Hetzner

The Flutter app already routes through `DEEPSEEK_PROXY_URL` when the
build-time define is set. This service is what answers that URL.

## What the app sends

```
POST https://api.interactpak.com/translate
Content-Type: application/json
X-App-Token: <APP_TRANSLATE_TOKEN>     ; only if you enabled auth

{
  "model": "deepseek-chat",
  "messages": [
    {"role": "system", "content": "You are a professional translator..."},
    {"role": "user",   "content": "Hello world"}
  ],
  "temperature": 0.2,
  "stream": false
}
```

It expects an OpenAI-compatible response with
`choices[0].message.content`. The proxy forwards DeepSeek's body through
unchanged — same shape DeepSeek already returns, so no client-side
parsing change.

## One-time host setup

```bash
# As root on the Hetzner box:
sudo useradd --system --home /opt/interact --shell /usr/sbin/nologin interact
sudo mkdir -p /opt/interact /etc/interact /var/log/interact
sudo chown -R interact:interact /opt/interact /var/log/interact
sudo chmod 750 /etc/interact

# Node 20 LTS via NodeSource (skip if you already have it):
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt-get install -y nodejs
```

## Deploy

From your dev box:

```bash
# Sync the proxy folder up to the server.
rsync -av --delete \
  server/translate-proxy/ \
  hetzner:/opt/interact/translate-proxy/

ssh hetzner '
  cd /opt/interact/translate-proxy && \
  npm ci --omit=dev
'
```

On the server, fill in the env file and start:

```bash
sudo cp /opt/interact/translate-proxy/env.example /etc/interact/translate.env
sudo $EDITOR /etc/interact/translate.env       # paste DEEPSEEK_API_KEY etc.
sudo chmod 640 /etc/interact/translate.env
sudo chown root:interact /etc/interact/translate.env

sudo cp /opt/interact/translate-proxy/interact-translate.service \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now interact-translate

# Confirm it's listening on loopback:
ss -tlnp | grep 8081
journalctl -u interact-translate -f
```

## Wire Caddy (or nginx)

Drop `Caddyfile.snippet` into your Caddy config (or merge with your
existing host block) and reload:

```bash
sudo cp Caddyfile.snippet /etc/caddy/sites/translate.conf
sudo systemctl reload caddy
```

Caddy will provision a Let's Encrypt cert for `api.interactpak.com` on
first hit. Smoke-test from your laptop:

```bash
curl -i https://api.interactpak.com/healthz
# → HTTP/2 200, {"ok":true}

curl -i https://api.interactpak.com/translate \
  -H 'Content-Type: application/json' \
  -H 'X-App-Token: <APP_SHARED_SECRET>' \
  -d '{
    "model":"deepseek-chat",
    "messages":[
      {"role":"system","content":"Translate to French. Output ONLY the translation."},
      {"role":"user","content":"Hello world"}
    ]
  }'
```

If the response includes `"content": "Bonjour le monde"`, the loop is
healthy.

## Point the app at it

Edit `dart_defines.json` at the project root:

```json
{
  "DEEPSEEK_PROXY_URL": "https://api.interactpak.com/translate",
  "DEEPSEEK_API_KEY": "",
  "APP_TRANSLATE_TOKEN": "<same value as APP_SHARED_SECRET on the server>",
  "GOOGLE_WEB_CLIENT_ID": "REPLACE_ME.apps.googleusercontent.com"
}
```

Build / run:

```bash
flutter run --dart-define-from-file=dart_defines.json
# Release build for App Store / TestFlight:
flutter build ipa --dart-define-from-file=dart_defines.json
```

If `APP_SHARED_SECRET` is set on the server, follow the optional client
header step below — without it, the server will return 401.

### App token gate (recommended)

The Flutter client now sends `X-App-Token` automatically when
`APP_TRANSLATE_TOKEN` is baked into the build. To turn the gate on:

1. **Get the live token value** from
   `server/translate-proxy/secrets.local.md` (gitignored — back this file
   up to a password manager). Or rotate to a new one with `openssl rand
   -hex 32`.

2. **Set it on the server** in `/etc/interact/translate.env`:

   ```bash
   ssh root@leathx-vps
   nano /etc/interact/translate.env
   # APP_SHARED_SECRET=<the value from secrets.local.md>
   systemctl restart interact-translate
   ```

3. **Set the same value in the app's `dart_defines.json`** (also
   gitignored):

   ```json
   {
     "DEEPSEEK_PROXY_URL": "https://api.interactpak.com/translate",
     "APP_TRANSLATE_TOKEN": "<the value from secrets.local.md>",
     ...
   }
   ```

4. **Rebuild the app** — old builds will start returning 401 until they're
   replaced. Coordinate with a release.

Once enabled, anything hitting `/translate` without the matching header
is rejected at the proxy with `401 Unauthorized` before any DeepSeek call
is made.

## Operational notes

- **Logs:** `journalctl -u interact-translate -f` — includes morgan's
  request log + any stderr from the upstream call.
- **Rotate the DeepSeek key:** edit `/etc/interact/translate.env` then
  `sudo systemctl restart interact-translate`. Rolling restart, no
  client change.
- **Bump rate limit:** edit `RATE_LIMIT_PER_MIN` in the env file and
  restart. Each Caddy-fronted client looks like a unique IP via
  `X-Forwarded-For`, so the limiter is genuinely per-user.
- **Block a runaway client:** until you have user-level auth, the
  fastest knob is a `iptables -I INPUT -s <ip> -j DROP` or Caddy's
  `@blocked remote_ip <ip> { abort }`.
- **Cost guardrail:** the `MAX_INPUT_CHARS=8000` cap covers ~2k tokens
  of input. The translation cache on the client (`translation_cache.dart`)
  also dedupes identical requests, so costs scale with unique text, not
  with reads.

## Weekly usage email

The proxy appends one NDJSON line per successful request to
`/var/log/interact/translate-usage.ndjson`. A sibling `usage-report.js`
script aggregates the last 7 days, formats a plain-text + HTML summary,
and emails it via SMTP. Wire it on a `systemd` timer:

```bash
# 1. Pre-create the log dir + give the service user write access.
sudo mkdir -p /var/log/interact
sudo chown interact:interact /var/log/interact

# 2. Add SMTP creds to /etc/interact/translate.env. Pick whichever
#    relay you have credentials for — Hetzner Mailbox, Gmail App
#    Password, Resend, Postmark, etc.
sudo nano /etc/interact/translate.env
```

Append (replace placeholders with real values):

```
SMTP_HOST=smtp.your-relay.com
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=interact-proxy@interactpak.com
SMTP_PASS=<app-password>
USAGE_FROM=interact-proxy@interactpak.com
USAGE_TO=interact@paksaf.com
USAGE_SUBJECT_PREFIX=[Interact Pro] Translate proxy usage
USAGE_LOG_PATH=/var/log/interact/translate-usage.ndjson
```

```bash
# 3. Restart the proxy so it picks up USAGE_LOG_PATH (logging is gated
#    on this var being set).
sudo systemctl restart interact-translate

# 4. Install the report timer + service.
sudo cp /opt/interact/translate-proxy/interact-usage-report.service \
        /etc/systemd/system/
sudo cp /opt/interact/translate-proxy/interact-usage-report.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload

# 5. Smoke-test once before scheduling — fires the report immediately.
sudo systemctl start interact-usage-report.service
sudo journalctl -u interact-usage-report -n 30 --no-pager
# Should end with: "usage-report sent: <message-id> ..."

# 6. Enable the weekly timer.
sudo systemctl enable --now interact-usage-report.timer
sudo systemctl list-timers interact-usage-report
```

The default schedule is **Mondays at 09:00** server time
(`OnCalendar=Mon *-*-* 09:00:00` in the `.timer` unit). Edit that line
and `systemctl daemon-reload && systemctl restart interact-usage-report.timer`
if you want a different cadence — e.g. `daily`, or
`*-*-01 09:00:00` for the first of each month.

### What the email looks like

Subject: `[Interact Pro] Translate proxy usage · 142 requests / 7d`

Body (plain-text equivalent of the HTML version):

```
Interact Pro — Translate proxy usage
Window: last 7 days
Host: leathx-vps

Requests:        142 (140 ok)
Unique IPs:      27
Input chars:     61,234
Prompt tokens:   18,902
Completion:      9,477
Total tokens:    28,379
Cache hits:      4,210 prompt-tokens

By model:
  deepseek-chat            142 req ·     28,379 tokens

Bill estimate: visit https://platform.deepseek.com to see actual spend.
Source log:    /var/log/interact/translate-usage.ndjson
```

### Trim or rotate the log

The NDJSON log grows ~150 bytes per request — roughly 1MB per ~7000
calls. If volumes grow, add a logrotate config:

```bash
sudo tee /etc/logrotate.d/interact-translate <<'EOF'
/var/log/interact/translate-usage.ndjson {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    copytruncate
}
EOF
```

This keeps 12 weeks of compressed history (`.1.gz`, `.2.gz`, …) and
truncates the live file in place so the proxy doesn't need a restart.
