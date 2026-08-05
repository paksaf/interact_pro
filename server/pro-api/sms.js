// Phone-OTP delivery via the INTERACT Comms Hub.
//
// 2026-06-11 REWRITE: Dexatel (and Twilio direct) accounts are CLOSED —
// the whole portfolio routes outbound SMS/WhatsApp through the single
// Comms Hub number and email through Resend, all behind
// POST connect.interactpak.com/api/comms/send (X-Hub-Token auth).
// See _shared/services/comms-client + _shared/docs/COMMS_HUB.md. This
// file is the plain-JS port of that client's hubSendSms for pro-api
// (no TS build step here).
//
// Env:
//   INTERACT_HUB_TOKEN  — required in production; without it we refuse
//                         silently-broken sends and log the code instead.
//   INTERACT_HUB_URL    — optional override (default connect.interactpak.com).
//   OTP_SMS_CHANNEL     — 'sms' (default) or 'whatsapp'. The hub number is
//                         reachable on both, so WhatsApp delivery is a
//                         config flip, not a code change.

const HUB_URL =
  (process.env.INTERACT_HUB_URL ?? 'https://connect.interactpak.com')
    .replace(/\/+$/, '');
const HUB_TOKEN = process.env.INTERACT_HUB_TOKEN?.trim() || null;
const OTP_CHANNEL =
  process.env.OTP_SMS_CHANNEL === 'whatsapp' ? 'whatsapp' : 'sms';

if (!HUB_TOKEN) {
  console.warn(
    'WARN: INTERACT_HUB_TOKEN not set. OTP codes will be logged to stdout '
    + 'instead of sent via the Comms Hub. Acceptable for dev; NEVER for prod.',
  );
}

/**
 * Send a one-time code via the Comms Hub. Same return-shape as email.js
 * so the caller can treat the two paths uniformly.
 *
 * Phone format: caller passes whatever the user typed; we normalise
 * to E.164 before sending (digits + leading +).
 */
export async function sendOtpSms({ to, code }) {
  const normalised = normaliseE164(to);
  const text = `Interact Pro: ${code} — your sign-in code (expires in 10 min). Do not share.`;

  if (!HUB_TOKEN) {
    console.log(`[dev-otp-sms] to=${normalised} code=${code}`);
    return { ok: true, dev: true };
  }

  try {
    const res = await fetch(`${HUB_URL}/api/comms/send`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Hub-Token': HUB_TOKEN,
      },
      body: JSON.stringify({
        channel: OTP_CHANNEL,
        to: normalised,
        text,
        app: 'interact-pro-api',
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      console.error(`Comms Hub ${res.status}: ${body.slice(0, 300)}`);
      return { ok: false, error: `hub-${res.status}` };
    }
    const j = await res.json().catch(() => ({}));
    if (j.ok === false) {
      console.error(`Comms Hub send rejected: ${j.error ?? 'unknown'}`);
      return { ok: false, error: j.error ?? 'hub-rejected' };
    }
    return { ok: true, sid: j.sid ?? j.id };
  } catch (err) {
    console.error(`Comms Hub send failed: ${err.message}`);
    return { ok: false, error: err.message };
  }
}

/**
 * Strip everything except digits + a single leading + sign. Doesn't
 * try to be smart about country codes — if the user typed a 10-digit
 * Pakistani number without a country code, the hub will reject it and
 * the user sees a helpful "Try with country code" message in the
 * verify-OTP error path.
 */
function normaliseE164(raw) {
  if (typeof raw !== 'string') return '';
  const trimmed = raw.trim();
  const digits = trimmed.replace(/[^\d]/g, '');
  return trimmed.startsWith('+') ? `+${digits}` : digits;
}
