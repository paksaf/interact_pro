# Interact Pro OTP Email — SSH Triage Runbook

**Symptom:** users tap "Send code" in the app, see the success screen, but no 6-digit email arrives.

**Why this is hard to debug from outside:** the OTP route at `server/pro-api/index.js:96-142` always returns `200 OK` to the client, even when Resend rejects the send (this is by design — prevents attackers from probing which emails exist by triggering a different error). So the user sees "code sent" UI no matter what actually happened on the backend.

This runbook walks through identifying which of the four most likely causes is in play. Run each section in order; stop as soon as you find the culprit.

---

## Setup — connect to the VPS

```bash
# From your Mac
ssh root@178.105.73.238
```

If the SSH alias `interact` works for you (per `.env.local` `PRO_SSH_ALIAS=interact`):

```bash
ssh interact
```

You should land in `~` as root. Everything below runs from that shell.

---

## Step 1 — Confirm the API key is loaded by the running process

The most common cause: `RESEND_API_KEY` is set in your local `.env.local` but never made it to the production env file the systemd service reads.

```bash
# Find the env file the service reads
systemctl cat interact-pro-api.service | grep -E "EnvironmentFile|Environment="

# If EnvironmentFile= points to a path (typical: /srv/interact-pro-api/.env), read just the Resend keys:
grep -E "^RESEND_API_KEY|^OTP_MAIL_FROM|^OTP_MAIL_REPLY_TO" /srv/interact-pro-api/.env
```

**Expected:**
```
RESEND_API_KEY=re_...........................
```
(plus optionally `OTP_MAIL_FROM` and `OTP_MAIL_REPLY_TO`)

**If `RESEND_API_KEY` is missing or empty:**
```bash
# Append it (replace the placeholder with the actual key — copy from your local .env.local):
echo 'RESEND_API_KEY=re_REPLACE_ME' >> /srv/interact-pro-api/.env

systemctl restart interact-pro-api.service
systemctl status interact-pro-api.service --no-pager | head -20
```
Then jump to **Step 4** to test end-to-end.

**If `RESEND_API_KEY` IS present**, continue to Step 2.

---

## Step 2 — Watch logs while you trigger an OTP

Open two terminal panes (tmux split or two SSH sessions).

**Pane A** — tail the service log, filtered to OTP/email/Resend events:
```bash
journalctl -u interact-pro-api.service -f --since "1 minute ago" | grep --line-buffered -iE "otp|resend|email"
```

**Pane B** — on your phone, open Interact Pro, type a real email address, tap "Send code".

You'll see one of four patterns appear in Pane A within ~3 seconds:

### Pattern A — silent (no log line at all)
The handler isn't being reached. Most likely the request is hitting the wrong host, or the rate-limiter (`otpLimiter`) blocked it. Test directly:

```bash
curl -i -X POST https://pro.interactpak.com/api/auth/otp/request \
  -H 'Content-Type: application/json' \
  -d '{"email":"YOUR_REAL_EMAIL@gmail.com"}'
# Expect: 200 with body { "sentTo": "email", "expiresInSec": 600 }
```

If you get 200 but still no log, the journalctl filter is wrong — drop `| grep` and re-run to see everything. If you get a non-200, that response code tells you what's wrong (429 = rate-limited, 500 = server crash, 502/504 = Caddy not reaching the service).

### Pattern B — `OTP delivery failed for ali@x.com: Resend 401: ...`
The API key is rejected. Most likely it's stale (rotated in the Resend dashboard) or has a trailing whitespace from a copy-paste. Re-paste it into `/srv/interact-pro-api/.env` and `systemctl restart interact-pro-api.service`.

### Pattern C — `OTP delivery failed for ali@x.com: Resend 422: from_address ...`
The `from:` domain isn't verified on Resend. Default in `email.js` is `Interact Pro <noreply@send.interactpak.com>`. Verify at <https://resend.com/domains> that `send.interactpak.com` shows status **Verified** (not "Pending" or "Failed"). If it's "Failed", DNS records are wrong — re-check against `_shared/scripts/verify-email-dns.sh` from your Mac.

### Pattern D — silent success (no error, no failure line)
Resend accepted the send. The email is somewhere — probably spam folder, possibly bounced. Continue to Step 3.

---

## Step 3 — Verify in the Resend dashboard, then check the recipient inbox

The Resend Logs view shows every send with its actual delivery state. From any browser:

1. Go to <https://resend.com/emails>
2. Filter by recipient email
3. The most recent row's status column will show one of:
   - **Delivered** — Resend handed the message to the recipient's mail server. If user still doesn't see it, it's in spam (Step 3a) or a bad reply-to mismatch (Step 3b).
   - **Bounced** — recipient address doesn't exist, or the inbox is full. Tell user to check spelling.
   - **Complained** — recipient flagged a previous send as spam; Resend now suppresses sends to that address. You can clear in dashboard but the user's inbox will still distrust you.
   - **Queued / Sending** — wait 30 seconds and refresh.
   - **(no row at all)** — the API call never reached Resend. Re-run Step 2; the response Pane A should have shown the network error.

### Step 3a — Spam folder check (likely if status is Delivered)

Tell the user to check **Spam** / **Junk** / **Promotions** folder. If the email is there:

In Gmail: open the message → "Show original" (top-right three-dot menu). Look for these three lines near the top:
```
SPF:    PASS
DKIM:   PASS
DMARC:  ???   ← this is the one to investigate
```

If **DMARC** says FAIL or NEUTRAL, that's the deliverability hit. Two fixes:

1. **Publish a DMARC record** for `interactpak.com` (most likely missing). From your Mac:
   ```bash
   dig +short TXT _dmarc.interactpak.com @1.1.1.1
   ```
   If empty, log into Hetzner Cloud DNS, zone `interactpak.com`, add:
   - Type: TXT
   - Name: `_dmarc`
   - Value: `v=DMARC1; p=quarantine; rua=mailto:postmaster@interactpak.com`
   
   Wait 10 min, send a fresh test, "Show original" again — DMARC should now say PASS.

### Step 3b — Reply-To/From domain mismatch (likely contributing)

The current `email.js` uses:
- `from: noreply@send.interactpak.com`
- `reply_to: interact@paksaf.com`

Different second-level domains in From vs Reply-To is a classic spam-pattern signal. Either change the reply-to to the same domain as From, or accept the slight risk.

To change without touching code, just set the env var:
```bash
echo 'OTP_MAIL_REPLY_TO=support@interactpak.com' >> /srv/interact-pro-api/.env
systemctl restart interact-pro-api.service
```

To make the change permanent in code (cleaner), edit `server/pro-api/email.js` line 11 in your local copy and redeploy:
```js
// Before:
process.env.OTP_MAIL_REPLY_TO ?? 'interact@paksaf.com';
// After:
process.env.OTP_MAIL_REPLY_TO ?? 'support@interactpak.com';
```

---

## Step 4 — Direct probe (bypass the app entirely)

After applying any fix above, this is the fastest way to confirm the whole chain works without involving the mobile app or the rate limiter:

```bash
# On the VPS — uses the actual key the service is using
source /srv/interact-pro-api/.env
curl -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "from": "Interact Pro <noreply@send.interactpak.com>",
    "to": ["YOUR_REAL_EMAIL@gmail.com"],
    "subject": "VPS direct probe",
    "text": "If this arrives in your inbox (not spam), Resend works. If not, check the Resend dashboard: https://resend.com/emails"
  }'
```

**Interpret:**
- Response `{ "id": "re_..." }` and email arrives in inbox → everything works. The app issue is something specific to the app code path; re-test from the phone.
- Response `{ "id": "re_..." }` but no email → check spam folder; if not there, check Resend Logs (Step 3).
- Response `{ "name": "validation_error", ... }` → fix the `from:` (domain not verified) or the API key.
- Connection error (no JSON response) → Hetzner blocked the outbound HTTPS to api.resend.com, which would be unusual; check `curl -v https://api.resend.com` for TLS/network issues.

---

## Step 5 — End-to-end app re-test (only after Step 4 succeeds)

```bash
# Optionally clear the rate-limit by waiting 60 seconds, OR purge in Postgres:
psql "$DATABASE_URL" -c "DELETE FROM otp_codes WHERE contact = 'YOUR_REAL_EMAIL@gmail.com';"
```

On your phone:
1. Force-stop Interact Pro (Settings → Apps → Interact Pro → Force Stop)
2. Reopen → enter your real email → Send code
3. Within 30 seconds the code should arrive in inbox

If it still doesn't, jump to **Pane A** in Step 2 and re-watch the logs — there's a fifth-cause-not-anticipated brewing, and the log line will name it.

---

## Bonus — surface delivery failures to the user

The current handler hides failures from the client. For a paid B2B app like Interact Pro, the security argument is weak compared to UX cost (users tap "Send code" three times, get nothing, give up). To surface a non-blocking notice:

```js
// server/pro-api/index.js around line 132
if (!send.ok) {
  console.error(`OTP delivery failed for ${contact}: ${send.error}`);
  // NEW: tell the client we couldn't send, so they can fall back to phone OTP.
  return res.status(502).json({
    error: 'We could not send your code. Please try the phone option instead.',
    sentTo: contactType,
  });
}

res.json({
  sentTo: contactType === 'email' ? 'email' : 'sms',
  expiresInSec: OTP_TTL_MIN * 60,
});
```

This still doesn't leak account-existence info (the error is the same whether the email exists or not), but it does tell legitimate users their attempt failed.

---

## Reference — files involved

| File | Purpose |
|---|---|
| `server/pro-api/index.js:94-142` | OTP request handler |
| `server/pro-api/email.js` | Resend HTTPS send + retry |
| `/srv/interact-pro-api/.env` | Production env vars on VPS |
| `/srv/interact-pro-api/` | Service working directory |
| `interact-pro-api.service` | systemd unit |
| `journalctl -u interact-pro-api.service` | Live logs |
| <https://resend.com/emails> | Authoritative deliverability dashboard |

## Reference — the four cause patterns

| Pattern in logs | Cause | Fix |
|---|---|---|
| (silent — no log line) | Request not reaching handler | Test endpoint with curl; check rate limiter |
| `Resend 401:` | Bad API key | Re-paste in `.env`, restart service |
| `Resend 422: from_address` | Sender domain not verified | Verify in Resend dashboard, fix DNS |
| (silent success, but no email) | Spam folder / DMARC fail / address bad | Resend dashboard → Logs |
