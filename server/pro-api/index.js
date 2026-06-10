// Interact Pro — pro.interactpak.com/api server.
//
// One file, one Express app. Endpoints:
//
//   POST /api/auth/otp/request    body { email | phone }
//   POST /api/auth/otp/verify     body { email | phone, otp }
//   GET  /api/auth/me             auth required
//   POST /api/auth/sign-out       auth required
//
//   POST /api/auth/renewal/request          auth required, body { note? }
//   GET  /api/auth/renewal/pending          admin only
//   POST /api/auth/renewal/:id/approve      admin only, body { extendDays? }
//   POST /api/auth/renewal/:id/decline      admin only, body { reason? }
//
//   GET  /api/admin/users         admin auth, ?query=...
//   POST /api/admin/users/:id/grant-pro       admin auth, body { months }
//   POST /api/admin/users/:id/revoke-pro      admin auth
//   POST /api/admin/users/:id/extend-trial    admin auth, body { days }
//   POST /api/admin/users/:id/role            admin auth, body { role }
//   POST /api/admin/users/:id/sign-out-everywhere   admin auth
//
//   GET  /api/version             public
//   GET  /api/healthz             public
//
//   GET    /api/sync/manifest      auth required
//   POST   /api/sync/upload        auth required, multipart pdf + meta
//   GET    /api/sync/download/:id  auth required → application/pdf stream
//   DELETE /api/sync/:id           auth required
//   GET    /api/sync/quota         auth required
//
// Run:
//   DATABASE_URL=postgres://... \
//   JWT_SECRET=... \
//   RESEND_API_KEY=... \
//   DEXATEL_API_KEY=... \
//   PORT=3050 \
//   node index.js

import express from 'express';
import rateLimit from 'express-rate-limit';
import morgan from 'morgan';
import multer from 'multer';
import { createHash, randomInt, randomUUID } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import { mkdir, rename, stat, unlink } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';

import { ping, query, queryOne, shutdown } from './db.js';
import { signToken, requireAuth, requireAdmin, denyToken, userToJson } from './auth.js';
import { sendOtpEmail, sendRenewalApprovedEmail } from './email.js';
import { sendOtpSms } from './sms.js';
import { draftAiReply, SLA_MESSAGE } from './chat-ai.js';
import { verifyApple, verifyGoogle } from './iap-verify.js';
import { convertToPdfRoute } from './convert.js';
import { handleIosWaitlist, listIosWaitlist, markIosWaitlistInvited } from './ios-waitlist.js';

// In-memory multer for the convert route — payloads are ≤ 50 MB
// (matches LibreOffice's practical limit for headless conversion on
// the VPS's 4 GB box) and we hash + stream them through to the
// libreoffice subprocess without touching disk in the request path.
const convertUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 50 * 1024 * 1024 },
});

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = Number.parseInt(process.env.PORT ?? '3050', 10);
const TRIAL_DAYS = Number.parseInt(process.env.TRIAL_DAYS ?? '7', 10);
const OTP_TTL_MIN = Number.parseInt(process.env.OTP_TTL_MIN ?? '10', 10);
const MAX_OTP_ATTEMPTS = 5;

await ping();

const app = express();
app.set('trust proxy', 1); // we're behind Caddy → respect X-Forwarded-For
app.use(express.json({ limit: '32kb' }));
app.use(morgan('combined'));

// Per-IP rate limit on OTP request — prevents enumeration / spam.
// Generous (10 req / 15 min) so a flaky network retry isn't fatal.
const otpLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
});

// Per-IP rate limit on the open iOS waitlist endpoint. Lower than OTP
// because there's no second-factor — pure spam vector. 20 / hour is
// plenty for a real human re-submitting after fixing a typo.
const waitlistLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
});

// ── iOS waitlist (public — for pro.interactpak.com/ios.html) ────────────
//
// See ios-waitlist.js + migration 006. Open route, rate-limited.

app.post('/api/notify/ios-waitlist',                 waitlistLimiter, handleIosWaitlist);
app.get ('/api/admin/notify/ios-waitlist',           requireAdmin,    listIosWaitlist);
app.post('/api/admin/notify/ios-waitlist/mark-invited', requireAdmin, markIosWaitlistInvited);

// ── Public health + version ─────────────────────────────────────────────

app.get('/api/healthz', async (_req, res) => {
  try {
    await query('SELECT 1');
    res.json({ ok: true });
  } catch (err) {
    res.status(503).json({ ok: false, error: err.message });
  }
});

// Version manifest. Served by reading a `version.json` file at the
// project root; deployment writes the file. Falls back to a sensible
// 200 with empty data if the file's missing so cold boots don't 500.
app.get('/api/version', (_req, res) => {
  let manifest = {};
  try {
    manifest = JSON.parse(
      readFileSync(join(__dirname, 'version.json'), 'utf8'),
    );
  } catch {
    // No version file yet — return empty so the client treats this as
    // "no update" rather than crashing.
    manifest = { latest: null };
  }
  res.json(manifest);
});

// ── Auth: /api/auth/otp/request ─────────────────────────────────────────

app.post('/api/auth/otp/request', otpLimiter, async (req, res) => {
  const { email, phone } = req.body ?? {};
  const cleanEmail = typeof email === 'string' ? email.trim().toLowerCase() : null;
  const cleanPhone = typeof phone === 'string' ? phone.trim() : null;

  if (!cleanEmail && !cleanPhone) {
    return res.status(400).json({ error: 'Provide an email or phone number.' });
  }
  if (cleanEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) {
    return res.status(400).json({ error: 'Invalid email address.' });
  }
  if (cleanPhone && cleanPhone.replace(/\D/g, '').length < 7) {
    return res.status(400).json({ error: 'Invalid phone number.' });
  }

  const contact = cleanEmail ?? cleanPhone;
  const contactType = cleanEmail ? 'email' : 'phone';
  const code = randomInt(100_000, 1_000_000).toString();
  const expiresAt = new Date(Date.now() + OTP_TTL_MIN * 60 * 1000);

  // Invalidate any older still-pending codes for this contact so the
  // user can't accumulate a bag of codes.
  await query(
    'UPDATE otp_codes SET consumed = true WHERE contact = $1 AND NOT consumed',
    [contact],
  );
  await query(
    `INSERT INTO otp_codes (contact, contact_type, code, expires_at)
     VALUES ($1, $2, $3, $4)`,
    [contact, contactType, code, expiresAt],
  );

  const send = contactType === 'email'
    ? await sendOtpEmail({ to: cleanEmail, code })
    : await sendOtpSms({ to: cleanPhone, code });

  if (!send.ok) {
    // Surface a generic 502 so the client can show "couldn't send,
    // retry" UI. We don't echo the provider error (that leaks signup
    // attempts and Resend-internal detail); we DO tell the user the
    // delivery failed so they're not left staring at a code-entry
    // screen when no email is coming. The OTP row is still in
    // Postgres — if the email *does* eventually land, verify still
    // accepts it.
    console.error(`OTP delivery failed for ${contact}: ${send.error}`);
    return res.status(502).json({
      error: contactType === 'email'
        ? 'We couldn\'t send the email. Check the address and try again.'
        : 'We couldn\'t send the SMS. Check the number and try again.',
      sentTo: contactType,
      delivered: false,
    });
  }

  res.json({
    sentTo: contactType === 'email' ? 'email' : 'sms',
    expiresInSec: OTP_TTL_MIN * 60,
    delivered: true,
  });
});

// ── Auth: /api/auth/otp/verify ──────────────────────────────────────────

app.post('/api/auth/otp/verify', async (req, res) => {
  const { email, phone, otp } = req.body ?? {};
  const cleanEmail = typeof email === 'string' ? email.trim().toLowerCase() : null;
  const cleanPhone = typeof phone === 'string' ? phone.trim() : null;
  const cleanOtp = typeof otp === 'string' ? otp.trim() : null;

  if ((!cleanEmail && !cleanPhone) || !cleanOtp) {
    return res.status(400).json({ error: 'Missing parameters.' });
  }

  const contact = cleanEmail ?? cleanPhone;
  const contactType = cleanEmail ? 'email' : 'phone';

  // Find the freshest unconsumed, unexpired code for this contact.
  const row = await queryOne(
    `SELECT id, code, attempts FROM otp_codes
       WHERE contact = $1 AND NOT consumed AND expires_at > NOW()
       ORDER BY created_at DESC LIMIT 1`,
    [contact],
  );

  if (!row) {
    return res.status(401).json({ error: 'Code expired. Request a new one.' });
  }
  if (row.attempts >= MAX_OTP_ATTEMPTS) {
    // Burn the code so further guesses don't waste attempts.
    await query('UPDATE otp_codes SET consumed = true WHERE id = $1', [row.id]);
    return res.status(401).json({ error: 'Too many wrong attempts. Request a new code.' });
  }

  if (row.code !== cleanOtp) {
    await query(
      'UPDATE otp_codes SET attempts = attempts + 1 WHERE id = $1',
      [row.id],
    );
    return res.status(401).json({ error: 'Wrong code. Try again.' });
  }

  // Burn the code. We don't get to reuse it.
  await query('UPDATE otp_codes SET consumed = true WHERE id = $1', [row.id]);

  // Find or create the user. The CHECK constraint on `users` enforces
  // that we always set at least one of (email, phone).
  let user = await queryOne(
    contactType === 'email'
      ? 'SELECT * FROM users WHERE email = $1'
      : 'SELECT * FROM users WHERE phone = $1',
    [contact],
  );
  if (!user) {
    const trialEndsAt = new Date(Date.now() + TRIAL_DAYS * 24 * 60 * 60 * 1000);
    const created = await queryOne(
      `INSERT INTO users (${contactType}, display_name, trial_ends_at)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [contact, defaultDisplayName(contact, contactType), trialEndsAt],
    );
    user = created;
    await audit(user.id, 'user.created', user.id, { via: contactType });
  }

  // Pass the full user row so the JWT carries role/email/name claims —
  // SSO peers (app.interactpak.com) decode authorise without a DB hit.
  const { token, expiresInSec } = signToken(user);

  // Set the SSO cookie on the apex domain so every *.interactpak.com host
  // sees this session. The Flutter app keeps using the JSON-returned
  // Bearer token for its API calls; the cookie path is what makes the
  // staff portal "just work" without a second sign-in.
  res.cookie('interact-session', token, {
    domain: '.interactpak.com',
    httpOnly: true,
    secure: true,
    sameSite: 'lax',
    path: '/',
    maxAge: expiresInSec * 1000,
  });

  res.json({ token, user: userToJson(user) });
});

// ── Auth: /api/auth/me ──────────────────────────────────────────────────

app.get('/api/auth/me', requireAuth, (req, res) => {
  res.json({ user: userToJson(req.user) });
});

// ── Auth: /api/auth/sign-out ────────────────────────────────────────────

app.post('/api/auth/sign-out', requireAuth, async (req, res) => {
  await denyToken(req.jwtJti, req.jwtExpiresAt);
  // Also clear the SSO cookie so app.interactpak.com immediately
  // forgets the session.
  res.clearCookie('interact-session', {
    domain: '.interactpak.com',
    path: '/',
  });
  res.status(204).end();
});

// ── IAP: /api/iap/verify ────────────────────────────────────────────────
//
// The Flutter client used to grant Pro immediately on the in-app
// purchase plugin's `PurchaseStatus.purchased` callback. That's
// client-only trust — anyone can stub the IAP plugin and forge a
// successful purchase. This endpoint moves the trust boundary to
// the server: client sends the platform-specific receipt, server
// validates with Apple/Google, only THEN do we mark the user Pro.
//
// Body: { platform: 'ios'|'android', productId, transactionId,
//         serverVerificationData }
// Returns: { ok: true, pro: true } on success,
//          { ok: false, error } on failure (client must NOT grant).

app.post('/api/iap/verify', requireAuth, async (req, res) => {
  const { platform, productId, transactionId, serverVerificationData } =
    req.body ?? {};

  if (!platform || !productId || !transactionId || !serverVerificationData) {
    return res.status(400).json({
      ok: false,
      error: 'Missing platform / productId / transactionId / serverVerificationData.',
    });
  }
  if (platform !== 'ios' && platform !== 'android') {
    return res.status(400).json({ ok: false, error: 'platform must be ios or android' });
  }

  // 1. Record the receipt FIRST (audit trail). Even if validation
  //    later fails or refuses to run for lack of credentials, we
  //    have the payload for offline review / refund tracking.
  //    Upsert on (platform, transaction_id) so client retries don't
  //    duplicate rows.
  await query(
    `INSERT INTO iap_purchases
       (user_id, platform, product_id, transaction_id, receipt_payload)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (platform, transaction_id) DO NOTHING`,
    [req.user.id, platform, productId, transactionId, serverVerificationData],
  );

  // 2. Validate with the platform's server-side API.
  const result = platform === 'ios'
    ? await verifyApple({ productId, serverVerificationData })
    : await verifyGoogle({ productId, purchaseToken: serverVerificationData });

  // 3. Update the audit row with the outcome.
  await query(
    `UPDATE iap_purchases
        SET verified = $1,
            verifier = $2,
            verification_error = $3,
            verified_at = now()
      WHERE platform = $4 AND transaction_id = $5`,
    [result.ok, result.verifier, result.error ?? null, platform, transactionId],
  );

  if (!result.ok) {
    // Allow-list one exception: if validation was skipped because
    // credentials aren't configured AND the env explicitly opts in
    // (DEV_ALLOW_UNVERIFIED_IAP=1), grant anyway. Useful for staging
    // before the App Store / Play Console are fully wired up. Prod
    // must NEVER set this var.
    if (result.verifier === 'skipped' &&
        process.env.DEV_ALLOW_UNVERIFIED_IAP === '1') {
      await markProActive(req.user.id, productId);
      return res.json({
        ok: true,
        pro: true,
        warning: 'verifier-not-configured-dev-grant',
      });
    }
    return res.status(402).json({ ok: false, error: result.error });
  }

  // 4. Validation passed — flip the user's pro_active and stash the
  //    productId so admin can see which tier they bought.
  await markProActive(req.user.id, productId);
  res.json({ ok: true, pro: true, verifier: result.verifier });
});

async function markProActive(userId, productId) {
  await query(
    `UPDATE users
        SET pro_active = true,
            pro_product_id = $1,
            pro_granted_at = COALESCE(pro_granted_at, now())
      WHERE id = $2`,
    [productId, userId],
  );
}

// ── Admin endpoints ─────────────────────────────────────────────────────

app.get('/api/admin/users', requireAdmin, async (req, res) => {
  const search = (req.query.query ?? '').toString().trim();
  const limit = Number.parseInt((req.query.limit ?? '50').toString(), 10);

  let rows;
  if (search) {
    const pattern = `%${search}%`;
    rows = (await query(
      `SELECT id, email, phone, display_name, role, trial_ends_at,
              pro_active, created_at,
              CASE WHEN pro_active THEN 'Pro'
                   WHEN trial_ends_at IS NOT NULL AND trial_ends_at > NOW() THEN 'Trial'
                   ELSE 'Free' END AS plan_label
         FROM users
        WHERE id::text ILIKE $1 OR email ILIKE $1 OR phone ILIKE $1
        ORDER BY created_at DESC
        LIMIT $2`,
      [pattern, limit],
    )).rows;
  } else {
    rows = (await query(
      `SELECT id, email, phone, display_name, role, trial_ends_at,
              pro_active, created_at,
              CASE WHEN pro_active THEN 'Pro'
                   WHEN trial_ends_at IS NOT NULL AND trial_ends_at > NOW() THEN 'Trial'
                   ELSE 'Free' END AS plan_label
         FROM users
        ORDER BY created_at DESC
        LIMIT $1`,
      [limit],
    )).rows;
  }

  res.json({
    users: rows.map((r) => ({
      id: r.id,
      email: r.email,
      phone: r.phone,
      displayName: r.display_name,
      role: r.role,
      planLabel: r.plan_label,
      proActive: r.pro_active,
      trialEndsAt: r.trial_ends_at?.toISOString() ?? null,
      createdAt: r.created_at.toISOString(),
    })),
  });
});

app.post('/api/admin/users/:id/grant-pro', requireAdmin, async (req, res) => {
  const months = Number.parseInt(req.body?.months ?? '1', 10);
  if (!Number.isFinite(months) || months <= 0 || months > 60) {
    return res.status(400).json({ error: 'months must be 1..60' });
  }
  // Pro flag flip + clear any old trial. The "+months" term is for
  // future Stripe-driven flows that record the next renewal date in
  // a separate column; today we just flip the boolean.
  await query(
    `UPDATE users SET pro_active = true,
                      trial_ends_at = NULL
       WHERE id = $1`,
    [req.params.id],
  );
  await audit(req.user.id, 'admin.grant_pro', req.params.id, { months });
  res.json({ ok: true });
});

app.post('/api/admin/users/:id/revoke-pro', requireAdmin, async (req, res) => {
  await query('UPDATE users SET pro_active = false WHERE id = $1', [req.params.id]);
  await audit(req.user.id, 'admin.revoke_pro', req.params.id);
  res.json({ ok: true });
});

app.post('/api/admin/users/:id/extend-trial', requireAdmin, async (req, res) => {
  const days = Number.parseInt(req.body?.days ?? '7', 10);
  if (!Number.isFinite(days) || days <= 0 || days > 365) {
    return res.status(400).json({ error: 'days must be 1..365' });
  }
  await query(
    `UPDATE users
       SET trial_ends_at = GREATEST(COALESCE(trial_ends_at, NOW()), NOW())
                           + ($1::int || ' days')::interval
     WHERE id = $2`,
    [days, req.params.id],
  );
  await audit(req.user.id, 'admin.extend_trial', req.params.id, { days });
  res.json({ ok: true });
});

app.post('/api/admin/users/:id/role', requireAdmin, async (req, res) => {
  const role = req.body?.role;
  if (role !== 'user' && role !== 'admin') {
    return res.status(400).json({ error: "role must be 'user' or 'admin'" });
  }
  await query('UPDATE users SET role = $1 WHERE id = $2', [role, req.params.id]);
  await audit(req.user.id, 'admin.set_role', req.params.id, { role });
  res.json({ ok: true });
});

app.post('/api/admin/users/:id/sign-out-everywhere', requireAdmin, async (req, res) => {
  // We don't have access to the user's currently-issued JTIs; instead
  // we burn EVERY token whose sub matches by extending the denylist
  // with a sentinel that denies all of theirs. Because we don't track
  // outstanding jtis, the practical implementation is a `users.token_epoch`
  // column we bump and embed in new tokens. v2 work; for now this is a
  // marker action that audits the intent.
  await audit(req.user.id, 'admin.sign_out_everywhere', req.params.id);
  res.json({ ok: true, note: 'Recorded. Token-epoch enforcement lands in v2.' });
});

// ── Spike E: Office → PDF conversion ────────────────────────────────────
//
// POST /api/convert/to-pdf  (auth, multipart "file")
//   → 200 application/pdf  (Content-Length set, X-Cache: HIT|MISS)
//   → 415 unsupported MIME
//   → 500 LibreOffice failure
//
// Caches by sha256(input) at $CONVERT_CACHE_DIR. Re-opens of the same
// .docx return the cached PDF in single-digit ms.

app.post(
  '/api/convert/to-pdf',
  requireAuth,
  convertUpload.single('file'),
  convertToPdfRoute,
);

// ── Spike B: Admin document browser ─────────────────────────────────────
//
// Lets an admin see and download any user's synced PDFs — strictly
// gated by the user's own privacy toggle. Each access is audited
// with the admin's id + the file's name; users can request the audit
// trail for their account at any time.
//
// Privacy contract:
//   • `users.admin_doc_access_allowed` defaults to FALSE on every
//     account. Until the user explicitly opts in (Settings → Privacy
//     → "Allow INTERACT admins to access my cloud documents for
//     support"), these endpoints return 403.
//   • Opt-in is reversible at any time and the toggle change itself
//     is audit-logged.
//   • A 14-day TTL on the consent is enforced by `admin_doc_consent_at`
//     — after 14 days without re-consent, the toggle silently expires
//     and these endpoints start returning 403 again. Stops a one-time
//     opt-in from becoming a permanent privilege.
//   • All admin reads write `admin.doc_read` audit rows including
//     filename + size. The user can pull their own audit history
//     via /api/auth/me/admin-access-log.

app.get('/api/admin/users/:id/documents', requireAuth, requireAdmin, async (req, res) => {
  const target = await queryOne(
    `SELECT id, email, admin_doc_access_allowed,
            admin_doc_consent_at
       FROM users WHERE id = $1`,
    [req.params.id],
  );
  if (!target) return res.status(404).json({ error: 'No such user.' });
  if (!target.admin_doc_access_allowed) {
    return res.status(403).json({
      error: 'User has not opted in to admin document access.',
    });
  }
  if (target.admin_doc_consent_at) {
    const ageDays =
      (Date.now() - new Date(target.admin_doc_consent_at).getTime()) /
      86_400_000;
    if (ageDays > 14) {
      return res.status(403).json({
        error: 'User consent expired (>14 days). Ask them to re-opt-in.',
      });
    }
  }

  const rows = await query(
    `SELECT id, name, size_bytes, mtime, sha256
       FROM sync_documents
      WHERE user_id = $1
      ORDER BY mtime DESC NULLS LAST`,
    [req.params.id],
  );
  await audit(req.user.id, 'admin.doc_list', req.params.id, {
    count: rows.length,
  });
  res.json({ documents: rows });
});

app.get(
  '/api/admin/users/:id/documents/:docId/download',
  requireAuth,
  requireAdmin,
  async (req, res) => {
    const target = await queryOne(
      `SELECT id, admin_doc_access_allowed, admin_doc_consent_at
         FROM users WHERE id = $1`,
      [req.params.id],
    );
    if (!target) return res.status(404).end();
    if (!target.admin_doc_access_allowed) {
      return res.status(403).json({ error: 'User has not opted in.' });
    }
    if (target.admin_doc_consent_at) {
      const ageDays =
        (Date.now() - new Date(target.admin_doc_consent_at).getTime()) /
        86_400_000;
      if (ageDays > 14) {
        return res.status(403).json({ error: 'Consent expired.' });
      }
    }
    const doc = await queryOne(
      `SELECT id, name, size_bytes, storage_path
         FROM sync_documents
        WHERE user_id = $1 AND id = $2`,
      [req.params.id, req.params.docId],
    );
    if (!doc) return res.status(404).end();
    await audit(req.user.id, 'admin.doc_read', req.params.id, {
      doc_id: doc.id,
      name: doc.name,
      size: doc.size_bytes,
    });
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader(
      'Content-Disposition',
      `attachment; filename="${encodeURIComponent(doc.name)}"`,
    );
    createReadStream(doc.storage_path).pipe(res);
  },
);

// User-side: allow toggling consent + reading own audit trail.

app.post('/api/auth/me/admin-doc-consent', requireAuth, async (req, res) => {
  const allow = req.body?.allow === true;
  await query(
    `UPDATE users
        SET admin_doc_access_allowed = $1,
            admin_doc_consent_at = CASE WHEN $1 THEN now() ELSE NULL END
      WHERE id = $2`,
    [allow, req.user.id],
  );
  await audit(req.user.id, allow ? 'user.allow_admin_docs' : 'user.revoke_admin_docs', req.user.id);
  res.json({ ok: true, allow });
});

app.get('/api/auth/me/admin-access-log', requireAuth, async (req, res) => {
  // Maps to the existing audit_log shape (001_init): actor_id is the
  // admin who acted, target_id is the user whose docs they viewed,
  // body is the JSON payload (filename, size, count, etc.), and `at`
  // is the wall-clock. Aliased back to subject_id / payload / created_at
  // so the client doesn't have to know about the legacy column names.
  const rows = await query(
    `SELECT actor_id,
            action,
            target_id AS subject_id,
            body      AS payload,
            at        AS created_at
       FROM audit_log
      WHERE target_id = $1
        AND action IN ('admin.doc_list','admin.doc_read')
      ORDER BY at DESC
      LIMIT 100`,
    [req.user.id],
  );
  res.json({ accesses: rows });
});

// ── Trial renewal (admin-mediated) ──────────────────────────────────────
//
// User flow: paywall / trial banner → POST /api/auth/renewal/request
//   Body: { note?: string }
//   202: { requestId }
//   409: a pending request already exists for this user
//
// Admin flow:
//   GET  /api/auth/renewal/pending                 → { requests: [...] }
//   POST /api/auth/renewal/<id>/approve            Body: { extendDays?: 30 }
//   POST /api/auth/renewal/<id>/decline            Body: { reason?: string }
//
// The pending uniqueness invariant is enforced by a partial unique index
// (see migrations/003) so a concurrent double-tap can't insert two
// pending rows for one user.

app.post('/api/auth/renewal/request', requireAuth, async (req, res) => {
  const note = typeof req.body?.note === 'string'
    ? req.body.note.trim().slice(0, 500)
    : null;

  try {
    const row = await queryOne(
      `INSERT INTO renewal_requests (user_id, note)
       VALUES ($1, $2)
       RETURNING id`,
      [req.user.id, note || null],
    );
    await audit(req.user.id, 'renewal.requested', row.id, { note });
    res.status(202).json({ requestId: row.id });
  } catch (err) {
    // Partial unique index violation = already has a pending request.
    if (err.code === '23505') {
      return res.status(409).json({
        error: 'You already have a pending renewal request.',
      });
    }
    throw err;
  }
});

app.get('/api/auth/renewal/pending', requireAdmin, async (_req, res) => {
  const { rows } = await query(
    `SELECT r.id, r.user_id, r.note, r.requested_at,
            u.display_name, u.email, u.phone, u.trial_ends_at
       FROM renewal_requests r
       JOIN users u ON u.id = r.user_id
      WHERE r.status = 'pending'
      ORDER BY r.requested_at ASC
      LIMIT 200`,
  );
  res.json({
    requests: rows.map((r) => ({
      id: r.id,
      userId: r.user_id,
      displayName: r.display_name,
      email: r.email,
      phone: r.phone,
      trialEndsAt: r.trial_ends_at?.toISOString() ?? null,
      requestedAt: r.requested_at.toISOString(),
      note: r.note,
    })),
  });
});

app.post('/api/auth/renewal/:id/approve', requireAdmin, async (req, res) => {
  const extendDays = Number.parseInt(req.body?.extendDays ?? '30', 10);
  if (!Number.isFinite(extendDays) || extendDays <= 0 || extendDays > 365) {
    return res.status(400).json({ error: 'extendDays must be 1..365' });
  }

  const reqRow = await queryOne(
    `SELECT id, user_id, status FROM renewal_requests WHERE id = $1`,
    [req.params.id],
  );
  if (!reqRow) return res.status(404).json({ error: 'Request not found' });
  if (reqRow.status !== 'pending') {
    return res.status(409).json({
      error: `Request already ${reqRow.status}.`,
    });
  }

  // Extend the user's trial. Mirrors /api/admin/users/:id/extend-trial:
  // start from MAX(now, current trial_ends_at) so a lapsed trial gets
  // bumped from today rather than from the past expiry.
  await query(
    `UPDATE users
       SET trial_ends_at = GREATEST(COALESCE(trial_ends_at, NOW()), NOW())
                           + ($1::int || ' days')::interval
     WHERE id = $2`,
    [extendDays, reqRow.user_id],
  );
  await query(
    `UPDATE renewal_requests
       SET status = 'approved',
           responded_at = NOW(),
           responded_by = $1,
           extend_days = $2
     WHERE id = $3`,
    [req.user.id, extendDays, reqRow.id],
  );
  await audit(req.user.id, 'renewal.approved', reqRow.id, {
    userId: reqRow.user_id,
    extendDays,
  });

  // Notify the user. Best-effort — log failure but don't fail the
  // admin's action because Resend hiccupped.
  const target = await queryOne(
    `SELECT email, display_name FROM users WHERE id = $1`,
    [reqRow.user_id],
  );
  if (target?.email) {
    try {
      await sendRenewalApprovedEmail({
        to: target.email,
        name: target.display_name,
        extendDays,
      });
    } catch (err) {
      console.error('renewal approval email failed:', err.message);
    }
  }

  res.json({ ok: true, extendDays });
});

app.post('/api/auth/renewal/:id/decline', requireAdmin, async (req, res) => {
  const reason = typeof req.body?.reason === 'string'
    ? req.body.reason.trim().slice(0, 500)
    : null;

  const reqRow = await queryOne(
    `SELECT id, user_id, status FROM renewal_requests WHERE id = $1`,
    [req.params.id],
  );
  if (!reqRow) return res.status(404).json({ error: 'Request not found' });
  if (reqRow.status !== 'pending') {
    return res.status(409).json({
      error: `Request already ${reqRow.status}.`,
    });
  }

  await query(
    `UPDATE renewal_requests
       SET status = 'declined',
           responded_at = NOW(),
           responded_by = $1,
           reason = $2
     WHERE id = $3`,
    [req.user.id, reason || null, reqRow.id],
  );
  await audit(req.user.id, 'renewal.declined', reqRow.id, {
    userId: reqRow.user_id,
    reason,
  });
  res.json({ ok: true });
});

// ── Chat — user side ────────────────────────────────────────────────────

// Fetch the user's current open conversation (or create one).
app.get('/api/chat/conversation', requireAuth, async (req, res) => {
  let convo = await queryOne(
    `SELECT id, title, status, handoff_at, created_at, updated_at
       FROM conversations
      WHERE user_id = $1 AND status != 'closed'
      ORDER BY updated_at DESC
      LIMIT 1`,
    [req.user.id],
  );
  if (!convo) {
    convo = await queryOne(
      `INSERT INTO conversations (user_id) VALUES ($1)
       RETURNING id, title, status, handoff_at, created_at, updated_at`,
      [req.user.id],
    );
  }
  const { rows: messages } = await query(
    `SELECT id, role, body, created_at
       FROM messages
      WHERE conversation_id = $1
      ORDER BY created_at ASC`,
    [convo.id],
  );
  res.json({ conversation: convo, messages });
});

// Post a new user message. Triggers the AI auto-responder synchronously
// (200ms–10s typical). Response includes the user's message + the AI's
// reply (or the system "admin will reply" handoff message).
app.post('/api/chat/messages', requireAuth, async (req, res) => {
  const body = (req.body?.body ?? '').toString().trim();
  if (!body) return res.status(400).json({ error: 'Empty message' });
  if (body.length > 4000) {
    return res.status(400).json({ error: 'Message too long (max 4000 chars)' });
  }

  // Find or create the user's open conversation.
  let convo = await queryOne(
    `SELECT id, status FROM conversations
      WHERE user_id = $1 AND status != 'closed'
      ORDER BY updated_at DESC LIMIT 1`,
    [req.user.id],
  );
  if (!convo) {
    convo = await queryOne(
      `INSERT INTO conversations (user_id, title)
       VALUES ($1, $2) RETURNING id, status`,
      [req.user.id, body.slice(0, 60)],
    );
  } else if (!convo.title) {
    // Set title from first user message if not already set.
    await query(
      `UPDATE conversations SET title = $1 WHERE id = $2 AND title IS NULL`,
      [body.slice(0, 60), convo.id],
    );
  }

  // Insert the user message.
  const userMsg = await queryOne(
    `INSERT INTO messages (conversation_id, role, body)
     VALUES ($1, 'user', $2)
     RETURNING id, role, body, created_at`,
    [convo.id, body],
  );

  // If conversation is already in admin handoff, don't auto-respond —
  // the user is waiting on a human.
  if (convo.status === 'admin_handoff') {
    return res.json({ userMessage: userMsg, replies: [] });
  }

  // Pull recent history for the AI context.
  const { rows: history } = await query(
    `SELECT role, body FROM messages
      WHERE conversation_id = $1 ORDER BY created_at ASC`,
    [convo.id],
  );

  const ai = await draftAiReply({ history });

  let replies = [];
  if (ai.kind === 'reply') {
    const aiMsg = await queryOne(
      `INSERT INTO messages (conversation_id, role, body)
       VALUES ($1, 'ai', $2)
       RETURNING id, role, body, created_at`,
      [convo.id, ai.body],
    );
    replies.push(aiMsg);
  } else {
    // Hand off to admin. Mark the conversation, post a system note.
    await query(
      `UPDATE conversations
         SET status = 'admin_handoff', handoff_at = NOW()
       WHERE id = $1`,
      [convo.id],
    );
    const sysMsg = await queryOne(
      `INSERT INTO messages (conversation_id, role, body)
       VALUES ($1, 'system', $2)
       RETURNING id, role, body, created_at`,
      [convo.id, SLA_MESSAGE],
    );
    replies.push(sysMsg);
  }

  res.json({ userMessage: userMsg, replies });
});

// ── Chat — admin side ───────────────────────────────────────────────────

// List all conversations awaiting admin attention, plus recent activity
// elsewhere. ?status=admin_handoff filters; default returns the queue
// (handoff first, then open, sorted by oldest-pending so SLA is fair).
app.get('/api/admin/chat/conversations', requireAdmin, async (req, res) => {
  const status = (req.query.status ?? '').toString();
  let rows;
  if (status && ['open', 'admin_handoff', 'closed'].includes(status)) {
    rows = (await query(
      `SELECT c.id, c.user_id, c.title, c.status, c.handoff_at,
              c.last_user_message_at, c.last_admin_reply_at, c.updated_at,
              u.email AS user_email, u.phone AS user_phone,
              u.display_name AS user_name
         FROM conversations c
         JOIN users u ON u.id = c.user_id
        WHERE c.status = $1
        ORDER BY c.updated_at DESC LIMIT 100`,
      [status],
    )).rows;
  } else {
    rows = (await query(
      `SELECT c.id, c.user_id, c.title, c.status, c.handoff_at,
              c.last_user_message_at, c.last_admin_reply_at, c.updated_at,
              u.email AS user_email, u.phone AS user_phone,
              u.display_name AS user_name
         FROM conversations c
         JOIN users u ON u.id = c.user_id
        WHERE c.status != 'closed'
        ORDER BY
          CASE c.status WHEN 'admin_handoff' THEN 0 ELSE 1 END,
          c.handoff_at NULLS LAST,
          c.updated_at DESC
        LIMIT 100`,
    )).rows;
  }
  res.json({
    conversations: rows.map((r) => ({
      id: r.id,
      userId: r.user_id,
      userEmail: r.user_email,
      userPhone: r.user_phone,
      userName: r.user_name,
      title: r.title,
      status: r.status,
      handoffAt: r.handoff_at?.toISOString() ?? null,
      lastUserMessageAt: r.last_user_message_at?.toISOString() ?? null,
      lastAdminReplyAt: r.last_admin_reply_at?.toISOString() ?? null,
      updatedAt: r.updated_at.toISOString(),
    })),
  });
});

app.get('/api/admin/chat/conversations/:id/messages', requireAdmin, async (req, res) => {
  const { rows } = await query(
    `SELECT id, role, body, actor_id, created_at
       FROM messages
      WHERE conversation_id = $1
      ORDER BY created_at ASC`,
    [req.params.id],
  );
  res.json({ messages: rows });
});

// Admin posts a reply. Resets handoff state since the human responded.
app.post('/api/admin/chat/conversations/:id/messages', requireAdmin, async (req, res) => {
  const body = (req.body?.body ?? '').toString().trim();
  if (!body) return res.status(400).json({ error: 'Empty message' });
  const msg = await queryOne(
    `INSERT INTO messages (conversation_id, role, body, actor_id)
     VALUES ($1, 'admin', $2, $3)
     RETURNING id, role, body, created_at`,
    [req.params.id, body, req.user.id],
  );
  // Move from handoff back to open — user can chat freely; AI takes
  // over again on the next message unless admin re-flags.
  await query(
    `UPDATE conversations SET status = 'open' WHERE id = $1 AND status = 'admin_handoff'`,
    [req.params.id],
  );
  res.json({ message: msg });
});

// Broadcast — admin posts the same message into multiple users'
// conversations at once. For app-wide promo / update announcements.
// Body: { body: 'text', userIds: ['uuid', ...] }  OR  { body, all: true }
app.post('/api/admin/chat/broadcast', requireAdmin, async (req, res) => {
  const body = (req.body?.body ?? '').toString().trim();
  if (!body) return res.status(400).json({ error: 'Empty message' });
  const all = req.body?.all === true;
  const userIds = Array.isArray(req.body?.userIds) ? req.body.userIds : [];
  if (!all && userIds.length === 0) {
    return res.status(400).json({ error: 'Provide userIds[] or all:true' });
  }

  const targets = all
    ? (await query('SELECT id FROM users')).rows.map((r) => r.id)
    : userIds;

  let posted = 0;
  for (const uid of targets) {
    // Find or create an open conversation for the target user.
    let convo = await queryOne(
      `SELECT id FROM conversations WHERE user_id = $1 AND status != 'closed'
       ORDER BY updated_at DESC LIMIT 1`,
      [uid],
    );
    if (!convo) {
      convo = await queryOne(
        `INSERT INTO conversations (user_id, title)
         VALUES ($1, 'Update from Interact Pro') RETURNING id`,
        [uid],
      );
    }
    await query(
      `INSERT INTO messages (conversation_id, role, body, actor_id)
       VALUES ($1, 'admin', $2, $3)`,
      [convo.id, body, req.user.id],
    );
    posted++;
  }

  await query(
    'INSERT INTO audit_log (actor_id, action, body) VALUES ($1, $2, $3)',
    [req.user.id, 'admin.chat_broadcast',
     { posted, all, userIds: all ? null : userIds, preview: body.slice(0, 200) }],
  );

  res.json({ posted });
});

// ── Sync endpoints — per-user PDF library on VPS (#158) ─────────────────
//
// Client contract (mirrors lib/features/sync/data/sync_api_client.dart):
//   GET    /api/sync/manifest        → { documents: [{id,name,sizeBytes,
//                                          sha256,version,mtime}] }
//   POST   /api/sync/upload          multipart: pdf + meta (JSON)
//                                    optional If-Match: <version>
//                                    → RemoteDoc on success
//                                    409 on version conflict
//                                    413 over quota
//   GET    /api/sync/download/:id    → application/pdf stream
//   DELETE /api/sync/:id             → 204
//   GET    /api/sync/quota           → {usedBytes, totalBytes, planLabel}
//
// Blob storage: PRO_STORAGE_ROOT/<user_id>/<doc_id>.pdf. The systemd
// unit gives `interact` user write access; Caddy is configured to allow
// large request bodies on /api/sync/upload (see DEPLOY.md).

const STORAGE_ROOT = process.env.PRO_STORAGE_ROOT ?? '/var/www/pro/storage';
// Multer scratch dir. MUST be on the same filesystem as STORAGE_ROOT so
// the final `rename()` is atomic. MUST NOT be under /tmp or /var/tmp —
// the systemd unit sets PrivateTmp=true which auto-mounts those, and
// adding either as a ReadWritePath crashes the service with
// status=226/NAMESPACE.
const SYNC_TMP_DIR = process.env.PRO_SYNC_TMP ?? '/var/www/pro/sync-tmp';
const QUOTA_FREE_BYTES = 100 * 1024 * 1024;        // 100 MB
const QUOTA_PRO_BYTES = 10 * 1024 * 1024 * 1024;   // 10 GB
const MAX_SYNC_UPLOAD_BYTES = 100 * 1024 * 1024;   // per-file hard cap

// Multer to /var/tmp so a partial upload doesn't blow up /tmp on a
// busy node. Files stream to disk; we sha256 + move to final location
// in the handler.
const syncUpload = multer({
  dest: SYNC_TMP_DIR,
  limits: { fileSize: MAX_SYNC_UPLOAD_BYTES },
});

function quotaFor(user) {
  return user.pro_active ? QUOTA_PRO_BYTES : QUOTA_FREE_BYTES;
}

async function usedBytesFor(userId) {
  const row = await queryOne(
    'SELECT COALESCE(SUM(size_bytes), 0)::bigint AS used FROM documents WHERE user_id = $1',
    [userId],
  );
  return Number(row?.used ?? 0);
}

async function hashFile(path) {
  const h = createHash('sha256');
  await pipeline(createReadStream(path), h);
  return h.digest('hex');
}

app.get('/api/sync/manifest', requireAuth, async (req, res) => {
  const { rows } = await query(
    `SELECT id, name, size_bytes, sha256, version, mtime
       FROM documents WHERE user_id = $1
      ORDER BY mtime DESC`,
    [req.user.id],
  );
  res.json({
    documents: rows.map((r) => ({
      id: r.id,
      name: r.name,
      sizeBytes: Number(r.size_bytes),
      sha256: r.sha256,
      version: Number(r.version),
      mtime: r.mtime.toISOString(),
    })),
  });
});

app.get('/api/sync/quota', requireAuth, async (req, res) => {
  const used = await usedBytesFor(req.user.id);
  const total = quotaFor(req.user);
  res.json({
    usedBytes: used,
    totalBytes: total,
    planLabel: req.user.pro_active ? 'Pro' : 'Free',
  });
});

app.post(
  '/api/sync/upload',
  requireAuth,
  syncUpload.single('pdf'),
  async (req, res) => {
    if (!req.file) {
      return res.status(400).json({ error: 'Missing "pdf" file field' });
    }

    // Tidy temp file no matter the outcome.
    const cleanupTmp = () => unlink(req.file.path).catch(() => {});

    // Parse meta JSON. Schema: { name, sizeBytes?, mtime?, id? }
    let meta;
    try {
      meta = JSON.parse(req.body?.meta ?? '{}');
    } catch {
      await cleanupTmp();
      return res.status(400).json({ error: 'Invalid "meta" JSON' });
    }
    const name = String(
      meta.name ?? req.file.originalname ?? 'document.pdf',
    ).slice(0, 255).trim() || 'document.pdf';
    const clientMtime = meta.mtime ? new Date(meta.mtime) : new Date();
    const existingId = typeof meta.id === 'string' ? meta.id : null;

    // Quota check BEFORE we accept the bytes into the user's directory.
    // We've already paid the disk cost via multer, but we can refuse to
    // commit to the documents table + final location.
    const used = await usedBytesFor(req.user.id);
    const quota = quotaFor(req.user);
    // For replacements, the existing row's bytes don't count against
    // the post-upload total. Free those bytes for the calculation.
    let existingBytes = 0;
    let existing = null;
    if (existingId) {
      existing = await queryOne(
        `SELECT id, version, size_bytes, storage_path
           FROM documents WHERE id = $1 AND user_id = $2`,
        [existingId, req.user.id],
      );
      if (!existing) {
        await cleanupTmp();
        return res.status(404).json({ error: 'Document not found' });
      }
      existingBytes = Number(existing.size_bytes);
      const ifMatch = req.get('if-match');
      if (ifMatch && Number(ifMatch) !== Number(existing.version)) {
        await cleanupTmp();
        return res.status(409).json({
          error: 'Version conflict — another device updated this document.',
          currentVersion: Number(existing.version),
        });
      }
    }
    if (used - existingBytes + req.file.size > quota) {
      await cleanupTmp();
      return res.status(413).json({
        error: 'Storage quota exceeded.',
        usedBytes: used,
        totalBytes: quota,
      });
    }

    const sha256 = await hashFile(req.file.path);
    const userDir = join(STORAGE_ROOT, req.user.id);
    await mkdir(userDir, { recursive: true });

    const docId = existing?.id ?? randomUUID();
    const version = existing ? Number(existing.version) + 1 : 1;
    const storagePath = join(userDir, `${docId}.pdf`);

    // Atomic move from /var/tmp into user storage. If they're on
    // different filesystems, fall through to copy-and-delete.
    try {
      await rename(req.file.path, storagePath);
    } catch {
      await pipeline(
        createReadStream(req.file.path),
        (await import('node:fs')).createWriteStream(storagePath),
      );
      await cleanupTmp();
    }

    await query(
      `INSERT INTO documents
         (id, user_id, name, size_bytes, sha256, version, storage_path, mtime, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
       ON CONFLICT (id) DO UPDATE
         SET name = EXCLUDED.name,
             size_bytes = EXCLUDED.size_bytes,
             sha256 = EXCLUDED.sha256,
             version = EXCLUDED.version,
             storage_path = EXCLUDED.storage_path,
             mtime = EXCLUDED.mtime,
             updated_at = NOW()`,
      [docId, req.user.id, name, req.file.size, sha256, version, storagePath, clientMtime],
    );
    await audit(req.user.id, 'sync.upload', docId, {
      sizeBytes: req.file.size,
      version,
    });

    res.json({
      id: docId,
      name,
      sizeBytes: req.file.size,
      sha256,
      version,
      mtime: clientMtime.toISOString(),
    });
  },
);

app.get('/api/sync/download/:id', requireAuth, async (req, res) => {
  const row = await queryOne(
    `SELECT name, storage_path, size_bytes
       FROM documents WHERE id = $1 AND user_id = $2`,
    [req.params.id, req.user.id],
  );
  if (!row) return res.status(404).json({ error: 'Not found' });
  try {
    await stat(row.storage_path);
  } catch {
    // Row exists but file vanished — DB/disk inconsistency. Surface a
    // distinct error so the client can resync rather than retry forever.
    return res.status(410).json({ error: 'Blob missing on disk' });
  }
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Length', String(row.size_bytes));
  res.setHeader(
    'Content-Disposition',
    `inline; filename="${encodeURIComponent(row.name)}"`,
  );
  createReadStream(row.storage_path).pipe(res);
});

app.delete('/api/sync/:id', requireAuth, async (req, res) => {
  const row = await queryOne(
    'SELECT storage_path FROM documents WHERE id = $1 AND user_id = $2',
    [req.params.id, req.user.id],
  );
  if (!row) return res.status(404).json({ error: 'Not found' });
  await query('DELETE FROM documents WHERE id = $1', [req.params.id]);
  await unlink(row.storage_path).catch(() => {});
  await audit(req.user.id, 'sync.delete', req.params.id);
  res.status(204).end();
});

// ── Catch-all 404 + error handler ───────────────────────────────────────

app.use('/api', (_req, res) => res.status(404).json({ error: 'Not found' }));

app.use((err, _req, res, _next) => {
  console.error('unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// ── Helpers ─────────────────────────────────────────────────────────────

function defaultDisplayName(contact, contactType) {
  if (contactType === 'email') {
    const [local] = contact.split('@');
    return local.charAt(0).toUpperCase() + local.slice(1);
  }
  // For phone, last 4 digits is the most readable default.
  const tail = contact.replace(/\D/g, '').slice(-4);
  return `User ${tail}`;
}

async function audit(actorId, action, targetId, body) {
  try {
    await query(
      'INSERT INTO audit_log (actor_id, action, target_id, body) VALUES ($1, $2, $3, $4)',
      [actorId ?? null, action, targetId ?? null, body ?? null],
    );
  } catch (err) {
    // Audit failure shouldn't fail the user-visible request.
    console.error('audit insert failed:', err.message);
  }
}

// ── Boot + graceful shutdown ────────────────────────────────────────────

const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`pro-api listening on 127.0.0.1:${PORT}`);
});

const stop = async (sig) => {
  console.log(`Received ${sig}, shutting down`);
  server.close(async () => {
    await shutdown();
    process.exit(0);
  });
  // If the server doesn't close in 10s, exit anyway.
  setTimeout(() => process.exit(1), 10_000).unref();
};
process.on('SIGINT', () => stop('SIGINT'));
process.on('SIGTERM', () => stop('SIGTERM'));
