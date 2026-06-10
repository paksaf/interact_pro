// /api/notify/ios-waitlist
//
// Captures iOS waitlist signups from pro.interactpak.com/ios.html. The
// landing page POSTs a JSON body of {name, email, device, userAgent, ts}
// and we persist it to ios_waitlist (migration 006).
//
// Open route — no auth gate. Rate-limited by IP via express-rate-limit
// (instantiated in index.js and exported as `waitlistLimiter`).
//
// Idempotent on (lower(email), app) — re-submitting the same email
// returns 200 + already=true. The form is built to be re-submittable so
// users can update their device.

import { query } from './db.js';
import crypto from 'node:crypto';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function handleIosWaitlist(req, res) {
  try {
    const body = req.body ?? {};
    const email = String(body.email ?? '').trim().toLowerCase();
    if (!email || !EMAIL_RE.test(email) || email.length > 254) {
      return res.status(400).json({ ok: false, error: 'invalid_email' });
    }
    const name      = String(body.name      ?? '').trim().slice(0, 120) || null;
    const device    = String(body.device    ?? '').trim().slice(0, 120) || null;
    const userAgent = String(body.userAgent ?? req.headers['user-agent'] ?? '').slice(0, 500) || null;
    const referrer  = String(req.headers.referer ?? '').slice(0, 500) || null;
    const app       = String(body.app       ?? 'interact-pro').slice(0, 32);
    const platform  = String(body.platform  ?? 'ios').slice(0, 16);

    // Hash the IP rather than store it raw — gives us rate-limit/abuse
    // signal without retaining PII.
    const remote = req.ip ?? req.connection?.remoteAddress ?? '';
    const ipHash = remote
      ? crypto.createHash('sha256').update(remote).digest('hex')
      : null;

    // UPSERT: if a row already exists for (lower(email), app) the
    // unique index causes a constraint violation; the ON CONFLICT DO
    // UPDATE refreshes device / userAgent so users can re-submit with
    // a new phone. We return `already` so the form can render a
    // softer "we have you" message.
    //
    // xmax::text::bigint discriminates insert vs. update:
    //   - 0 (or `'0'`) means a fresh INSERT
    //   - non-zero means ON CONFLICT DO UPDATE fired
    // Using bigint (not int) because xid8 on Postgres 14+ doesn't
    // fit in int4.
    const result = await query(
      `INSERT INTO ios_waitlist (name, email, device, user_agent, referrer, ip_hash, app, platform)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (lower(email), app) DO UPDATE
         SET name       = COALESCE(EXCLUDED.name,       ios_waitlist.name),
             device     = COALESCE(EXCLUDED.device,     ios_waitlist.device),
             user_agent = COALESCE(EXCLUDED.user_agent, ios_waitlist.user_agent)
       RETURNING id, (xmax::text::bigint <> 0) AS already`,
      [name, email, device, userAgent, referrer, ipHash, app, platform],
    );

    const row = result.rows[0];
    return res.status(200).json({
      ok: true,
      already: row.already === true,
      id: Number(row.id),
    });
  } catch (e) {
    // Log with stack so the actual SQL or coercion failure is visible
    // in journalctl. Don't leak details to the client.
    console.error('[ios-waitlist] error:', e.message, e.stack);
    return res.status(500).json({ ok: false, error: 'server_error' });
  }
}

/**
 * Admin endpoint to list pending invitees for a TestFlight blast.
 * Auth: requireAdmin (provided by caller's auth middleware).
 */
export async function listIosWaitlist(req, res) {
  try {
    const onlyUninvited = req.query.uninvited === '1' || req.query.uninvited === 'true';
    const where = onlyUninvited ? 'WHERE invited_at IS NULL' : '';
    const r = await query(
      `SELECT id, name, email, device, app, platform, created_at, invited_at
         FROM ios_waitlist
         ${where}
        ORDER BY created_at DESC
        LIMIT 500`,
    );
    return res.status(200).json({ ok: true, count: r.rows.length, rows: r.rows });
  } catch (e) {
    console.error('[ios-waitlist:list] error:', e.message);
    return res.status(500).json({ ok: false, error: 'server_error' });
  }
}

/**
 * Admin endpoint to mark a batch as invited. Body: `{ ids: [number, ...] }`.
 * Stamps invited_at = now() so the next list?uninvited=1 query skips them.
 */
export async function markIosWaitlistInvited(req, res) {
  try {
    const ids = Array.isArray(req.body?.ids) ? req.body.ids.filter((n) => Number.isInteger(n)) : [];
    if (ids.length === 0) {
      return res.status(400).json({ ok: false, error: 'no_ids' });
    }
    const r = await query(
      `UPDATE ios_waitlist SET invited_at = now()
        WHERE id = ANY($1::bigint[])
          AND invited_at IS NULL
        RETURNING id`,
      [ids],
    );
    return res.status(200).json({ ok: true, marked: r.rows.length });
  } catch (e) {
    console.error('[ios-waitlist:mark] error:', e.message);
    return res.status(500).json({ ok: false, error: 'server_error' });
  }
}
