// Weekly usage email for the Interact Pro translate proxy.
//
// Reads NDJSON entries written by index.js's recordUsage(), filters the
// last N days (default 7), aggregates by model, and emails a plain-text +
// HTML summary to MAIL_TO via Resend's HTTP API.
//
// Why HTTP API and not SMTP: Hetzner Cloud blocks outbound 25/465/587 by
// default to prevent spam abuse, so the previous nodemailer/SMTP path was
// DOA on this VPS. The HTTP API uses port 443 (always open), and as a
// bonus gives us:
//   • idempotency-key dedupe (timer firing twice in same week → 1 send)
//   • automatic retry-with-backoff on 5xx
//   • delivery audit trail in the Resend dashboard
//
// Run manually:
//   node usage-report.js
// Or scheduled — see interact-usage-report.timer / .service.

import { readFile } from 'node:fs/promises';
import { hostname } from 'node:os';
import { createHash } from 'node:crypto';

const USAGE_LOG_PATH =
  process.env.USAGE_LOG_PATH ?? '/var/log/interact/translate-usage.ndjson';
const WINDOW_DAYS = Number.parseInt(process.env.USAGE_WINDOW_DAYS ?? '7', 10);
const USAGE_SUBJECT_PREFIX =
  process.env.USAGE_SUBJECT_PREFIX ?? '[Interact Pro] Translate proxy usage';

const RESEND_API_KEY = process.env.RESEND_API_KEY;
const MAIL_FROM =
  process.env.MAIL_FROM ?? 'Interact Pro <noreply@send.interactpak.com>';
const MAIL_TO = process.env.MAIL_TO ?? 'interact@paksaf.com';
const MAIL_REPLY_TO = process.env.MAIL_REPLY_TO ?? 'interact@paksaf.com';

if (!RESEND_API_KEY) {
  console.error('FATAL: RESEND_API_KEY env var required.');
  process.exit(1);
}

// ── Aggregation ──────────────────────────────────────────────────────────

async function loadEntries() {
  let raw;
  try {
    raw = await readFile(USAGE_LOG_PATH, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return [];
    throw e;
  }
  return raw
    .split('\n')
    .filter((l) => l.length > 0)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function summarise(entries, sinceMs) {
  const filtered = entries.filter((e) => new Date(e.ts).getTime() >= sinceMs);
  const byModel = new Map();
  let totalReq = 0;
  let totalOk = 0;
  let totalPrompt = 0;
  let totalCompletion = 0;
  let totalTokens = 0;
  let totalCachedHits = 0;
  let totalChars = 0;
  const uniqueIps = new Set();

  for (const e of filtered) {
    totalReq++;
    if (e.ok) totalOk++;
    totalPrompt += e.prompt_tokens ?? 0;
    totalCompletion += e.completion_tokens ?? 0;
    totalTokens += e.total_tokens ?? 0;
    totalCachedHits += e.cached_tokens ?? 0;
    totalChars += e.input_chars ?? 0;
    if (e.ip) uniqueIps.add(e.ip);

    const m = e.model ?? 'unknown';
    if (!byModel.has(m)) {
      byModel.set(m, { requests: 0, ok: 0, total_tokens: 0 });
    }
    const slot = byModel.get(m);
    slot.requests++;
    if (e.ok) slot.ok++;
    slot.total_tokens += e.total_tokens ?? 0;
  }

  return {
    totalReq,
    totalOk,
    totalPrompt,
    totalCompletion,
    totalTokens,
    totalCachedHits,
    totalChars,
    uniqueIps: uniqueIps.size,
    byModel: Array.from(byModel.entries()).map(([model, v]) => ({ model, ...v })),
  };
}

// ── Formatting ───────────────────────────────────────────────────────────

function fmtNum(n) {
  return Number.isFinite(n) ? n.toLocaleString() : String(n);
}

function buildText(summary, windowDays) {
  const lines = [
    `Interact Pro — Translate proxy usage`,
    `Window: last ${windowDays} day${windowDays === 1 ? '' : 's'}`,
    `Host: ${hostname()}`,
    ``,
    `Requests:        ${fmtNum(summary.totalReq)} (${fmtNum(summary.totalOk)} ok)`,
    `Unique IPs:      ${fmtNum(summary.uniqueIps)}`,
    `Input chars:     ${fmtNum(summary.totalChars)}`,
    `Prompt tokens:   ${fmtNum(summary.totalPrompt)}`,
    `Completion:      ${fmtNum(summary.totalCompletion)}`,
    `Total tokens:    ${fmtNum(summary.totalTokens)}`,
    `Cache hits:      ${fmtNum(summary.totalCachedHits)} prompt-tokens`,
    ``,
    `By model:`,
  ];
  for (const m of summary.byModel) {
    lines.push(
      `  ${m.model.padEnd(20)} ${fmtNum(m.requests).padStart(8)} req · ${fmtNum(m.total_tokens).padStart(10)} tokens`,
    );
  }
  if (summary.byModel.length === 0) {
    lines.push('  (no requests in window)');
  }
  lines.push(
    '',
    `Bill estimate: visit https://platform.deepseek.com to see actual spend.`,
    `Source log:    ${USAGE_LOG_PATH}`,
  );
  return lines.join('\n');
}

function buildHtml(summary, windowDays) {
  const rows = summary.byModel
    .map(
      (m) =>
        `<tr><td>${escapeHtml(m.model)}</td><td style="text-align:right">${fmtNum(m.requests)}</td><td style="text-align:right">${fmtNum(m.ok)}</td><td style="text-align:right">${fmtNum(m.total_tokens)}</td></tr>`,
    )
    .join('') ||
    `<tr><td colspan="4" style="text-align:center;color:#666">No requests in window</td></tr>`;
  return `
<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;line-height:1.5;color:#222;max-width:600px">
  <h2 style="margin:0 0 8px 0">Interact Pro — Translate proxy usage</h2>
  <p style="margin:0 0 16px 0;color:#666">Last ${windowDays} day${windowDays === 1 ? '' : 's'} · Host: ${escapeHtml(hostname())}</p>
  <table style="border-collapse:collapse;width:100%;margin-bottom:16px">
    <tbody>
      ${kvRow('Requests', `${fmtNum(summary.totalReq)} (${fmtNum(summary.totalOk)} ok)`)}
      ${kvRow('Unique IPs', fmtNum(summary.uniqueIps))}
      ${kvRow('Input chars', fmtNum(summary.totalChars))}
      ${kvRow('Prompt tokens', fmtNum(summary.totalPrompt))}
      ${kvRow('Completion tokens', fmtNum(summary.totalCompletion))}
      ${kvRow('Total tokens', `<strong>${fmtNum(summary.totalTokens)}</strong>`)}
      ${kvRow('Prompt cache hits', fmtNum(summary.totalCachedHits))}
    </tbody>
  </table>
  <h3 style="margin:0 0 8px 0">By model</h3>
  <table style="border-collapse:collapse;width:100%;border:1px solid #eee">
    <thead style="background:#f6f8fa">
      <tr>
        <th style="text-align:left;padding:6px 10px">Model</th>
        <th style="text-align:right;padding:6px 10px">Requests</th>
        <th style="text-align:right;padding:6px 10px">OK</th>
        <th style="text-align:right;padding:6px 10px">Tokens</th>
      </tr>
    </thead>
    <tbody>${rows}</tbody>
  </table>
  <p style="margin-top:16px;color:#888;font-size:13px">
    Actual spend: <a href="https://platform.deepseek.com">platform.deepseek.com</a><br>
    Source log: ${escapeHtml(USAGE_LOG_PATH)}
  </p>
</div>
`;
}

function kvRow(k, v) {
  return `<tr><td style="padding:4px 10px;color:#666;width:160px">${k}</td><td style="padding:4px 10px">${v}</td></tr>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[c]));
}

// ── Resend HTTP API send ─────────────────────────────────────────────────

/**
 * ISO 8601 week number. Used in the idempotency key so Resend dedupes if
 * the timer accidentally fires twice in the same week (e.g. systemd
 * restart at 09:00:30 after the original 09:00:00 firing).
 */
function isoWeek(d = new Date()) {
  const date = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const dayNum = date.getUTCDay() || 7;
  date.setUTCDate(date.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((date - yearStart) / 86400000 + 1) / 7);
  return { year: date.getUTCFullYear(), week };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * POST to Resend's /emails endpoint with retry-with-backoff on transient
 * failures. 4xx fails fast (those are config errors and retrying won't
 * help). 5xx and network errors retry up to 3 times: 2s, 4s, 8s.
 *
 * `body` is the fully-formed request payload — passing it in (rather than
 * constructing here) lets the caller hash it for the idempotency key
 * BEFORE we send, so the key only collides on identical bodies.
 */
async function sendViaResend({ body, idempotencyKey }) {
  const maxAttempts = 3;
  let lastErr;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey,
        },
        body: JSON.stringify(body),
        // 30 s ceiling — Resend usually responds in <500 ms.
        signal: AbortSignal.timeout(30_000),
      });

      const raw = await res.text();
      let json;
      try { json = JSON.parse(raw); } catch { json = { raw }; }

      if (res.ok) {
        return { id: json.id, attempts: attempt };
      }

      // 4xx — permanent. Don't retry — bail immediately.
      if (res.status >= 400 && res.status < 500) {
        const err = new Error(`Resend ${res.status}: ${json.message ?? raw}`);
        err.permanent = true;
        throw err;
      }

      // 5xx — transient. Fall through to retry.
      lastErr = new Error(`Resend ${res.status}: ${json.message ?? raw}`);
    } catch (e) {
      if (e.permanent) throw e;
      lastErr = e;
    }

    if (attempt < maxAttempts) {
      const delay = 2 ** attempt * 1000; // 2 s, 4 s, 8 s
      console.warn(
        `usage-report send attempt ${attempt} failed (${lastErr.message}) — retrying in ${delay}ms`,
      );
      await sleep(delay);
    }
  }

  throw lastErr ?? new Error('send failed for unknown reason');
}

// ── Main ─────────────────────────────────────────────────────────────────

const since = Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000;
const entries = await loadEntries();
const summary = summarise(entries, since);

const subject = `${USAGE_SUBJECT_PREFIX} · ${summary.totalReq} requests / ${WINDOW_DAYS}d`;
const text = buildText(summary, WINDOW_DAYS);
const html = buildHtml(summary, WINDOW_DAYS);

// Build the request body upfront so we can hash its exact bytes into the
// idempotency key. Resend's dedupe contract: same key + same body → return
// original message id (good); same key + different body → 409 conflict.
// By appending a content hash to the key, identical content always dedupes
// (true accidental dupes — e.g. timer firing twice in one minute) and any
// content change always sends through (manual reruns after new translate
// activity, log file growth, etc.). The week+window prefix is kept for
// human-readable Resend logs.
const requestBody = {
  from: MAIL_FROM,
  to: [MAIL_TO],
  reply_to: MAIL_REPLY_TO,
  subject,
  text,
  html,
};

const bodyHash = createHash('sha256')
  .update(JSON.stringify(requestBody))
  .digest('hex')
  .slice(0, 12);

const { year, week } = isoWeek();
const idempotencyKey =
  `usage-report-${year}-W${String(week).padStart(2, '0')}-${WINDOW_DAYS}d-${bodyHash}`;

try {
  const result = await sendViaResend({ body: requestBody, idempotencyKey });
  console.log(
    `usage-report sent: ${result.id} (attempts=${result.attempts}, ` +
      `${summary.totalReq} req, ${summary.totalTokens} tokens, key=${idempotencyKey})`,
  );
} catch (e) {
  console.error(`usage-report FAILED: ${e.message}`);
  process.exit(2);
}
