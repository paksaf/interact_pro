// Phone-OTP delivery via Dexatel.
//
// Dexatel is the SMS provider already used elsewhere in the INTERACT
// portfolio (Qurbani Sahulat, Movento USSD rewards, etc. per CLAUDE.md),
// so the API key is reusable.
//
// Endpoint: POST https://api.dexatel.com/v1/messages
//   Bearer auth via DEXATEL_API_KEY.
//   Body: { from, to: ['+92...'], text }
//   Response: 201 with { id, status: 'queued' }.

const DEXATEL_API_KEY = process.env.DEXATEL_API_KEY;
const DEXATEL_SENDER =
  process.env.DEXATEL_SENDER ?? 'InteractPro';
const DEXATEL_BASE_URL =
  process.env.DEXATEL_BASE_URL ?? 'https://api.dexatel.com/v1/messages';

if (!DEXATEL_API_KEY) {
  console.warn(
    'WARN: DEXATEL_API_KEY not set. SMS OTPs will be logged to stdout '
    + 'instead of sent. Acceptable for dev; NEVER for prod.',
  );
}

/**
 * Send a one-time code via SMS. Same return-shape as email.js so the
 * caller can treat the two paths uniformly.
 *
 * Phone format: caller passes whatever the user typed; we normalise
 * to E.164 before sending (digits + leading +).
 */
export async function sendOtpSms({ to, code }) {
  const normalised = normaliseE164(to);
  const text = `Interact Pro: ${code} — your sign-in code (expires in 10 min). Do not share.`;

  if (!DEXATEL_API_KEY) {
    console.log(`[dev-otp-sms] to=${normalised} code=${code}`);
    return { ok: true, dev: true };
  }

  try {
    const res = await fetch(DEXATEL_BASE_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${DEXATEL_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: DEXATEL_SENDER,
        to: [normalised],
        text,
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      console.error(`Dexatel ${res.status}: ${body.slice(0, 300)}`);
      return { ok: false, error: `Dexatel ${res.status}` };
    }
    return { ok: true };
  } catch (err) {
    console.error(`Dexatel send failed: ${err.message}`);
    return { ok: false, error: err.message };
  }
}

/**
 * Strip everything except digits + a single leading + sign. Doesn't
 * try to be smart about country codes — if the user typed a 10-digit
 * Pakistani number without a country code, the SMS provider will
 * reject it and the user will see a helpful "Try with country code"
 * message in the verify-OTP error path.
 */
function normaliseE164(raw) {
  if (typeof raw !== 'string') return '';
  const trimmed = raw.trim();
  const digits = trimmed.replace(/[^\d]/g, '');
  return trimmed.startsWith('+') ? `+${digits}` : digits;
}
