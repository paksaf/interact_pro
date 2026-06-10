// JWT issuance + verification + denylist + Express auth middleware.
//
// SSO note (2026-05-08): the JWT_SECRET env var is being renamed to
// INTERACT_AUTH_SECRET so it can be shared with `app.interactpak.com`
// (Next.js staff portal) and tokens minted here verify there too. We
// accept either name during the migration window — drop JWT_SECRET in
// 2.2 once every host has the new var set.

import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';
import { query, queryOne } from './db.js';

const SSO_SECRET = process.env.INTERACT_AUTH_SECRET ?? process.env.JWT_SECRET;
const JWT_TTL_SECONDS = Number.parseInt(
  process.env.JWT_TTL_SECONDS ?? `${60 * 60 * 24 * 30}`,
  10,
); // 30 days default

if (!SSO_SECRET || SSO_SECRET.length < 32) {
  console.error(
    'FATAL: INTERACT_AUTH_SECRET (or legacy JWT_SECRET) env var required (≥32 chars).',
  );
  process.exit(1);
}

/**
 * Mint a fresh JWT for [user]. Embeds a unique `jti` (revocable via
 * /api/auth/sign-out) plus enriched claims (`role`, `email`, `name`,
 * `pro`) so other INTERACT services that verify this token (the
 * Next.js staff portal at app.interactpak.com) don't need to do a
 * follow-up DB round-trip just to render the page.
 *
 * Caller passes the loaded `users` row — see /api/auth/otp/verify.
 */
export function signToken(user) {
  const jti = randomUUID();
  const token = jwt.sign(
    {
      sub: user.id,
      jti,
      // SSO claims — Next.js verifier reads these directly from the
      // payload instead of DB-loading the user, so any host with the
      // shared secret can authorise the request fully on its own.
      role: user.role ?? 'user',
      email: user.email ?? null,
      name: user.display_name ?? null,
      pro: user.pro_active === true,
      // `iss` lets each verifier know which host minted the token —
      // useful for diagnostics, not enforced.
      iss: 'pro.interactpak.com',
    },
    SSO_SECRET,
    { algorithm: 'HS256', expiresIn: JWT_TTL_SECONDS },
  );
  return { token, jti, expiresInSec: JWT_TTL_SECONDS };
}

/**
 * Verify a token. Returns the decoded payload, or null if invalid /
 * expired / denylisted. Side-effect-free; doesn't touch the request.
 */
export async function verifyToken(rawToken) {
  if (!rawToken) return null;
  let payload;
  try {
    payload = jwt.verify(rawToken, SSO_SECRET, { algorithms: ['HS256'] });
  } catch {
    return null;
  }
  if (!payload?.sub || !payload?.jti) return null;
  // Denylist check.
  const denied = await queryOne(
    'SELECT 1 FROM jwt_denylist WHERE jti = $1 AND expires_at > NOW()',
    [payload.jti],
  );
  if (denied) return null;
  return payload;
}

/**
 * Tiny cookie parser. We intentionally avoid `cookie-parser` middleware to
 * keep the dependency surface small — this single function is all we need
 * to read the `interact-session` cookie set by the SSO sign-in path.
 */
function readCookie(req, name) {
  const raw = req.get('cookie');
  if (!raw) return null;
  for (const piece of raw.split(';')) {
    const [k, ...rest] = piece.trim().split('=');
    if (k === name) return decodeURIComponent(rest.join('='));
  }
  return null;
}

/**
 * Express middleware: accepts the session token from EITHER the
 * `Authorization: Bearer <token>` header (used by the Flutter Pro app) OR
 * the `interact-session` cookie (used by browsers visiting any
 * `*.interactpak.com` host after SSO sign-in). Verifies it, looks up the
 * user. On success, attaches `req.user` and calls next(). On failure,
 * sends 401 immediately.
 */
export async function requireAuth(req, res, next) {
  const headerAuth = req.get('authorization') ?? '';
  const headerMatch = /^Bearer\s+(.+)$/.exec(headerAuth);
  const cookieToken = readCookie(req, 'interact-session');
  const rawToken = headerMatch?.[1] ?? cookieToken;
  if (!rawToken) {
    return res.status(401).json({ error: 'Missing session token' });
  }
  const payload = await verifyToken(rawToken);
  if (!payload) return res.status(401).json({ error: 'Invalid or expired token' });
  const user = await queryOne(
    `SELECT id, email, phone, display_name, role, trial_ends_at, pro_active
       FROM users
      WHERE id = $1`,
    [payload.sub],
  );
  if (!user) return res.status(401).json({ error: 'User not found' });
  req.user = user;
  req.jwtJti = payload.jti;
  req.jwtExpiresAt = new Date(payload.exp * 1000);
  next();
}

/**
 * Sibling middleware: requireAuth + role === 'admin'. Use on every
 * /api/admin/* endpoint. Don't trust the client's role claim — we
 * loaded the row from Postgres so the role is whatever the DB says.
 */
export function requireAdmin(req, res, next) {
  return requireAuth(req, res, () => {
    if (req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Admin access required' });
    }
    next();
  });
}

/**
 * Burn a JWT — adds it to the denylist until it would have naturally
 * expired anyway. Used by /api/auth/sign-out.
 */
export async function denyToken(jti, expiresAt) {
  await query(
    'INSERT INTO jwt_denylist (jti, expires_at) VALUES ($1, $2) ON CONFLICT DO NOTHING',
    [jti, expiresAt],
  );
}

/**
 * Shape the user row so the client's `AuthUser.fromJson` consumes
 * the same field names whether it came from /verify or /me.
 */
export function userToJson(row) {
  return {
    id: row.id,
    email: row.email,
    phone: row.phone,
    displayName: row.display_name,
    role: row.role,
    trialEndsAt: row.trial_ends_at?.toISOString() ?? null,
    proActive: row.pro_active,
  };
}
