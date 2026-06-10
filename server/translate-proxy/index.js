// Interact Pro — DeepSeek translation proxy.
//
// Why this exists:
//   The Flutter client posts to DEEPSEEK_PROXY_URL with the same JSON body
//   it would send to api.deepseek.com directly, but WITHOUT an
//   Authorization header. This service injects the Bearer token from the
//   environment, forwards the request to DeepSeek, and streams the
//   response back unchanged. The mobile app never sees the API key.
//
// Run:
//   DEEPSEEK_API_KEY=sk-... \
//   APP_SHARED_SECRET=long-random-string \
//   PORT=8081 \
//   node index.js
//
// Endpoint: POST /translate (Content-Type: application/json)
//   - Validates the OpenAI-style chat-completions body the app sends.
//   - Optional: requires `x-app-token` header to match APP_SHARED_SECRET
//     so only your app (or whoever you give the token to) can use it.
//   - Rate limit: 60 req / minute per IP by default — tune for traffic.
//   - Forwards to DeepSeek and pipes the JSON response back.

import express from 'express';
import rateLimit from 'express-rate-limit';
import morgan from 'morgan';
import { appendFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const PORT = Number.parseInt(process.env.PORT ?? '8081', 10);
const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY;
const DEEPSEEK_BASE_URL =
  process.env.DEEPSEEK_BASE_URL ?? 'https://api.deepseek.com/v1/chat/completions';
const APP_SHARED_SECRET = process.env.APP_SHARED_SECRET ?? '';
const ALLOWED_MODELS = (process.env.ALLOWED_MODELS ?? 'deepseek-chat,deepseek-reasoner')
  .split(',')
  .map((m) => m.trim());
const MAX_INPUT_CHARS = Number.parseInt(process.env.MAX_INPUT_CHARS ?? '8000', 10);
const USAGE_LOG_PATH = process.env.USAGE_LOG_PATH ?? '';

if (!DEEPSEEK_API_KEY) {
  console.error('FATAL: DEEPSEEK_API_KEY env var is required.');
  process.exit(1);
}

// Ensure the log directory exists at startup so the first append doesn't
// race with the dir creation. No-op if logging is disabled.
if (USAGE_LOG_PATH) {
  await mkdir(dirname(USAGE_LOG_PATH), { recursive: true }).catch((e) =>
    console.warn(`usage log dir create failed: ${e.message}`),
  );
}

/**
 * Append one NDJSON line to USAGE_LOG_PATH per successful upstream call.
 * Best-effort: if the disk's full or perms are wrong we log to stderr but
 * still serve the response. The log shape is what usage-report.js reads.
 */
async function recordUsage(entry) {
  if (!USAGE_LOG_PATH) return;
  try {
    await appendFile(USAGE_LOG_PATH, JSON.stringify(entry) + '\n');
  } catch (e) {
    console.warn('usage log append failed:', e.message);
  }
}

const app = express();
app.disable("x-powered-by");
app.set('trust proxy', 1); // We sit behind Caddy/nginx — trust X-Forwarded-For.
app.use(express.json({ limit: '256kb' }));
app.use(morgan('tiny'));

// Per-IP rate limiter. Adjust to taste; 60/min/IP keeps malicious clients
// from racking up a DeepSeek bill while leaving normal users untouched.
const limiter = rateLimit({
  windowMs: 60_000,
  max: Number.parseInt(process.env.RATE_LIMIT_PER_MIN ?? '60', 10),
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Rate limit exceeded' },
});

// Healthcheck for Caddy / load balancer probes.
app.get('/healthz', (_req, res) => res.json({ ok: true }));

app.post('/translate', limiter, async (req, res) => {
  // Optional shared-secret gate. Set APP_SHARED_SECRET on the server and
  // ship the same string to the app via --dart-define=APP_TRANSLATE_TOKEN.
  // Then add a header in DeepSeekClient or include it in the proxy URL's
  // query string. If APP_SHARED_SECRET is empty the gate is disabled.
  if (APP_SHARED_SECRET) {
    const token =
      req.header('x-app-token') ||
      (typeof req.query.token === 'string' ? req.query.token : '');
    if (token !== APP_SHARED_SECRET) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  }

  const body = req.body ?? {};
  // Shape validation — the app always sends model + messages.
  if (typeof body.model !== 'string' || !ALLOWED_MODELS.includes(body.model)) {
    return res.status(400).json({ error: 'Invalid model' });
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return res.status(400).json({ error: 'messages[] required' });
  }
  // Cheap content-length cap — protects DeepSeek bill from someone sending
  // a War-and-Peace-sized blob.
  const totalChars = body.messages.reduce(
    (sum, m) => sum + (typeof m?.content === 'string' ? m.content.length : 0),
    0,
  );
  if (totalChars > MAX_INPUT_CHARS) {
    return res.status(413).json({
      error: `Input too long (${totalChars} > ${MAX_INPUT_CHARS} chars)`,
    });
  }

  try {
    const upstream = await fetch(DEEPSEEK_BASE_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${DEEPSEEK_API_KEY}`,
      },
      body: JSON.stringify({
        model: body.model,
        messages: body.messages,
        temperature: typeof body.temperature === 'number' ? body.temperature : 0.2,
        stream: false,
      }),
    });

    const text = await upstream.text();
    res
      .status(upstream.status)
      .type(upstream.headers.get('content-type') ?? 'application/json')
      .send(text);

    // Best-effort usage logging. Parse the upstream JSON to grab the
    // OpenAI-style `usage` block; if the body isn't JSON or the call failed
    // we still record the request count for the report.
    let usage = null;
    if (upstream.ok) {
      try {
        const parsed = JSON.parse(text);
        usage = parsed?.usage ?? null;
      } catch {
        // Non-JSON response — leave usage null.
      }
    }
    void recordUsage({
      ts: new Date().toISOString(),
      ip: req.ip,
      model: body.model,
      status: upstream.status,
      ok: upstream.ok,
      input_chars: totalChars,
      prompt_tokens: usage?.prompt_tokens ?? null,
      completion_tokens: usage?.completion_tokens ?? null,
      total_tokens: usage?.total_tokens ?? null,
      cached_tokens: usage?.prompt_cache_hit_tokens ?? 0,
    });
  } catch (err) {
    console.error('Proxy error:', err);
    res.status(502).json({ error: 'Upstream translation failure' });
  }
});

// Block everything else so the surface stays minimal.
app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

app.listen(PORT, '127.0.0.1', () => {
  console.log(`translate-proxy listening on 127.0.0.1:${PORT}`);
});
