// In-app purchase server-side verification.
//
// Two platforms, two flows:
//
//   • iOS — the client ships us `serverVerificationData` which is a
//     base64 receipt (or a JWS in StoreKit 2). We POST it to Apple's
//     verifyReceipt endpoint (or use the StoreKit 2 server API with
//     an issuer + key id signed JWT). The response either confirms
//     the receipt is valid or returns a status code we treat as
//     "do not grant".
//
//   • Android — the client ships us the purchase token. We call
//     Google Play Developer API's `purchases.products.get` (or
//     `purchases.subscriptions.get` for subs) with a service-account
//     access token. The response either confirms `purchaseState == 0`
//     (purchased) or we treat it as invalid.
//
// Credentials are optional — without them, this module records the
// receipt as `verified=false, verifier='skipped'` so the audit trail
// still captures the payload, and returns `{ok: false, reason:
// 'verifier-not-configured'}`. The route handler may choose to grant
// Pro anyway during local dev, but production should refuse.
//
// Env (all optional, missing == skip the matching platform):
//   APPLE_SHARED_SECRET           — required for legacy receipt verify
//   APPLE_STOREKIT2_ISSUER_ID     — for StoreKit 2 JWS validation
//   APPLE_STOREKIT2_KEY_ID
//   APPLE_STOREKIT2_PRIVATE_KEY   — PEM body, '\n' newlines
//   GOOGLE_PLAY_PACKAGE_NAME      — e.g. com.interactpak.pro.zeka
//   GOOGLE_PLAY_SERVICE_ACCOUNT   — JSON blob of the service account
//
// The verification calls have aggressive timeouts (10s) so a dead
// Apple/Google endpoint can't block a purchase indefinitely.

const APPLE_PROD = 'https://buy.itunes.apple.com/verifyReceipt';
const APPLE_SANDBOX = 'https://sandbox.itunes.apple.com/verifyReceipt';
const VERIFY_TIMEOUT_MS = 10_000;

/**
 * Verify an iOS purchase. Returns
 *   { ok: true, verifier: 'apple' }
 *   { ok: false, verifier: 'apple', error }
 *   { ok: false, verifier: 'skipped', error: 'no-creds' }
 *
 * `serverVerificationData` is the value Flutter's in_app_purchase
 * plugin returns in `verificationData.serverVerificationData`.
 */
export async function verifyApple({ productId, serverVerificationData }) {
  const sharedSecret = process.env.APPLE_SHARED_SECRET;
  if (!sharedSecret) {
    return { ok: false, verifier: 'skipped', error: 'APPLE_SHARED_SECRET not set' };
  }
  if (!serverVerificationData) {
    return { ok: false, verifier: 'apple', error: 'empty-receipt' };
  }

  // Apple recommends always trying prod first; if status === 21007
  // (sandbox receipt sent to prod) we retry against sandbox. This is
  // the only sanctioned way to support TestFlight + prod from one
  // server.
  const body = JSON.stringify({
    'receipt-data': serverVerificationData,
    password: sharedSecret,
    'exclude-old-transactions': true,
  });

  const prod = await postJson(APPLE_PROD, body);
  if (!prod.ok) return { ok: false, verifier: 'apple', error: prod.error };

  if (prod.json.status === 21007) {
    const sandbox = await postJson(APPLE_SANDBOX, body);
    if (!sandbox.ok) return { ok: false, verifier: 'apple', error: sandbox.error };
    return interpretAppleResponse(sandbox.json, productId);
  }
  return interpretAppleResponse(prod.json, productId);
}

function interpretAppleResponse(json, productId) {
  // status 0 = receipt is valid. Anything else (21000–21199) is a
  // failure code documented at developer.apple.com.
  if (json.status !== 0) {
    return { ok: false, verifier: 'apple', error: `apple-status-${json.status}` };
  }
  // Confirm the receipt actually contains the productId the client
  // claims to have bought. Without this, a valid receipt for a $0.99
  // tier could be replayed to claim the $19.99 tier.
  const items =
    json.latest_receipt_info ?? json.receipt?.in_app ?? [];
  const match = items.some((item) => item.product_id === productId);
  if (!match) {
    return { ok: false, verifier: 'apple', error: 'product-id-mismatch' };
  }
  return { ok: true, verifier: 'apple' };
}

/**
 * Verify an Android purchase. Returns same shape as verifyApple.
 *
 * The Google Play Developer API needs an OAuth2 access token from a
 * service account JSON. We do the token mint inline (no extra
 * dependency) — single JWT, sign with the service-account RSA key,
 * exchange for an access_token at https://oauth2.googleapis.com/token.
 */
export async function verifyGoogle({ productId, purchaseToken }) {
  const pkg = process.env.GOOGLE_PLAY_PACKAGE_NAME;
  const saJson = process.env.GOOGLE_PLAY_SERVICE_ACCOUNT;
  if (!pkg || !saJson) {
    return { ok: false, verifier: 'skipped', error: 'GOOGLE_PLAY_* not set' };
  }
  if (!purchaseToken) {
    return { ok: false, verifier: 'google', error: 'empty-token' };
  }

  let sa;
  try {
    sa = JSON.parse(saJson);
  } catch (e) {
    return { ok: false, verifier: 'google', error: 'service-account-json-parse-failed' };
  }

  const accessToken = await mintGoogleAccessToken(sa);
  if (!accessToken.ok) {
    return { ok: false, verifier: 'google', error: accessToken.error };
  }

  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(pkg)}/purchases/products/` +
    `${encodeURIComponent(productId)}/tokens/` +
    `${encodeURIComponent(purchaseToken)}`;
  const resp = await fetchWithTimeout(url, {
    headers: { Authorization: `Bearer ${accessToken.token}` },
  });
  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    return {
      ok: false,
      verifier: 'google',
      error: `google-status-${resp.status}: ${body.slice(0, 200)}`,
    };
  }
  const j = await resp.json();
  // purchaseState: 0=purchased, 1=canceled, 2=pending. Only 0 is
  // grantable. Subscriptions use a different endpoint; this module
  // currently handles one-shot products.
  if (j.purchaseState !== 0) {
    return {
      ok: false,
      verifier: 'google',
      error: `google-purchaseState-${j.purchaseState}`,
    };
  }
  return { ok: true, verifier: 'google' };
}

// ── Helpers ────────────────────────────────────────────────────────────────

async function postJson(url, body) {
  try {
    const resp = await fetchWithTimeout(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    });
    if (!resp.ok) {
      const text = await resp.text().catch(() => '');
      return { ok: false, error: `http-${resp.status}: ${text.slice(0, 200)}` };
    }
    return { ok: true, json: await resp.json() };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function fetchWithTimeout(url, init) {
  return fetch(url, { ...init, signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS) });
}

async function mintGoogleAccessToken(sa) {
  try {
    const now = Math.floor(Date.now() / 1000);
    const header = base64UrlJson({ alg: 'RS256', typ: 'JWT', kid: sa.private_key_id });
    const payload = base64UrlJson({
      iss: sa.client_email,
      scope: 'https://www.googleapis.com/auth/androidpublisher',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    });
    const unsigned = `${header}.${payload}`;
    const crypto = await import('node:crypto');
    const signer = crypto.createSign('RSA-SHA256');
    signer.update(unsigned);
    const sig = signer.sign(sa.private_key, 'base64url');
    const assertion = `${unsigned}.${sig}`;

    const resp = await fetchWithTimeout('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }).toString(),
    });
    if (!resp.ok) {
      const t = await resp.text().catch(() => '');
      return { ok: false, error: `oauth-${resp.status}: ${t.slice(0, 200)}` };
    }
    const j = await resp.json();
    return { ok: true, token: j.access_token };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

function base64UrlJson(obj) {
  return Buffer.from(JSON.stringify(obj))
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
