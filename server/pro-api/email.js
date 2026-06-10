// Email OTP delivery via Resend's HTTP API.
//
// Mirrors the pattern already used by server/translate-proxy/usage-report.js
// for the weekly DeepSeek usage email. Hetzner blocks outbound SMTP, so
// this is the only practical email path on the VPS.

const RESEND_API_KEY = process.env.RESEND_API_KEY;
const MAIL_FROM =
  process.env.OTP_MAIL_FROM ?? 'Interact Pro <noreply@send.interactpak.com>';
const MAIL_REPLY_TO =
  process.env.OTP_MAIL_REPLY_TO ?? 'interact@paksaf.com';

if (!RESEND_API_KEY) {
  console.warn(
    'WARN: RESEND_API_KEY not set. Email OTPs will be logged to stdout '
    + 'instead of sent. Acceptable for dev; NEVER for prod.',
  );
}

/**
 * Send a one-time code email. Returns `{ ok: true }` or
 * `{ ok: false, error }`. Caller decides what to do with failure (we
 * don't surface the failure to the user — telling someone "we couldn't
 * send your code" leaks signup attempts; we log + return success-shaped
 * response anyway and let them retry if no email arrived).
 */
export async function sendOtpEmail({ to, code }) {
  const subject = `Your Interact Pro code: ${code}`;
  const text = renderText(code);
  const html = renderHtml(code);

  // Dev fallback: no Resend key, log to stdout. The OTP is still in
  // Postgres so the verify endpoint accepts it.
  if (!RESEND_API_KEY) {
    console.log(`[dev-otp-email] to=${to} code=${code}`);
    return { ok: true, dev: true };
  }

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: MAIL_FROM,
        to: [to],
        reply_to: MAIL_REPLY_TO,
        subject,
        text,
        html,
      }),
      // Resend usually responds in < 500ms; cap at 15s.
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      console.error(`Resend ${res.status}: ${body.slice(0, 300)}`);
      return { ok: false, error: `Resend ${res.status}` };
    }
    return { ok: true };
  } catch (err) {
    console.error(`Resend send failed: ${err.message}`);
    return { ok: false, error: err.message };
  }
}

/**
 * Notify the user that their trial-renewal request was approved.
 * Same Resend transport as the OTP path — best-effort, returns
 * {ok:true} | {ok:false,error}. Caller logs failures but doesn't
 * fail the admin's UI action.
 */
export async function sendRenewalApprovedEmail({ to, name, extendDays }) {
  const subject = 'Your Interact Pro trial has been extended';
  const greeting = name ? `Hi ${name},` : 'Hi,';
  const text = `${greeting}

Good news — your Interact Pro trial request was approved. We've
extended your access by ${extendDays} day${extendDays === 1 ? '' : 's'}.

Open the app to keep using your library, OCR, and TTS features.

— Interact Pro
https://interactpak.com
`;
  const html = `<!doctype html>
<html><body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f6f8fa; padding: 24px; margin: 0;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width: 480px; margin: 0 auto;">
    <tr><td style="background: white; border-radius: 12px; padding: 32px 28px; box-shadow: 0 1px 3px rgba(0,0,0,0.06);">
      <h1 style="margin: 0 0 8px; font-size: 20px; color: #0a2a40;">Trial extended</h1>
      <p style="margin: 0 0 12px; color: #2a3a48; font-size: 15px;">${greeting}</p>
      <p style="margin: 0 0 20px; color: #5a6a78; font-size: 14px;">
        Your Interact Pro trial request was approved. We've added
        <strong>${extendDays} day${extendDays === 1 ? '' : 's'}</strong>
        of access to your account.
      </p>
      <p style="margin: 0; color: #7c8896; font-size: 12px;">
        Open the app to keep using your library, OCR, and TTS features.
      </p>
    </td></tr>
    <tr><td style="text-align: center; padding: 16px; color: #9ba8b6; font-size: 11px;">
      Interact Pro · interactpak.com
    </td></tr>
  </table>
</body></html>`;

  if (!RESEND_API_KEY) {
    console.log(`[dev-email] renewal approved to=${to} days=${extendDays}`);
    return { ok: true, dev: true };
  }

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: MAIL_FROM,
        to: [to],
        reply_to: MAIL_REPLY_TO,
        subject,
        text,
        html,
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      console.error(`Resend ${res.status}: ${body.slice(0, 300)}`);
      return { ok: false, error: `Resend ${res.status}` };
    }
    return { ok: true };
  } catch (err) {
    console.error(`Resend renewal email failed: ${err.message}`);
    return { ok: false, error: err.message };
  }
}

function renderText(code) {
  return `Your Interact Pro sign-in code is: ${code}

This code expires in 10 minutes. If you didn't ask for it, ignore this
email — no account was created.

— Interact Pro
https://interactpak.com
`;
}

function renderHtml(code) {
  // Inline-styled, table-based HTML for maximum email-client
  // compatibility. No external assets so privacy-mode mail clients
  // don't break the layout.
  return `<!doctype html>
<html><body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f6f8fa; padding: 24px; margin: 0;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width: 480px; margin: 0 auto;">
    <tr><td style="background: white; border-radius: 12px; padding: 32px 28px; box-shadow: 0 1px 3px rgba(0,0,0,0.06);">
      <h1 style="margin: 0 0 8px; font-size: 20px; color: #0a2a40;">Your Interact Pro code</h1>
      <p style="margin: 0 0 20px; color: #5a6a78; font-size: 14px;">Enter this code in the app to sign in.</p>
      <div style="background: #f0f4f8; border-radius: 8px; padding: 18px 20px; text-align: center;">
        <div style="font-family: 'SF Mono', Menlo, Consolas, monospace; font-size: 32px; letter-spacing: 12px; color: #0a2a40; font-weight: 600;">${code}</div>
      </div>
      <p style="margin: 20px 0 0; color: #7c8896; font-size: 12px;">
        This code expires in 10 minutes. If you didn't ask for it, ignore this email — no account was created.
      </p>
    </td></tr>
    <tr><td style="text-align: center; padding: 16px; color: #9ba8b6; font-size: 11px;">
      Interact Pro · interactpak.com
    </td></tr>
  </table>
</body></html>`;
}
