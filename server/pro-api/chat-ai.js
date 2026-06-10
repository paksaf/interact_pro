// DeepSeek-backed support auto-responder.
//
// On every NEW user message in an open conversation, the API server
// asks DeepSeek to draft a reply. If DeepSeek is confident the answer
// resolves the issue (heuristic: response doesn't hedge with "I'm not
// sure" / "contact support" / similar), we send it as the AI reply.
// Otherwise we mark the conversation status='admin_handoff' and
// auto-post a system message telling the user "An admin will reply
// within 24 hours."
//
// The system prompt embeds an APP CONTEXT cheat-sheet (features,
// known issues, how-tos) so the model can answer routine "how do I
// print" / "where's my Drive sync" questions without hallucinating.
// Edit APP_CONTEXT below as the app evolves.

const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY;
const DEEPSEEK_PROXY_URL = process.env.DEEPSEEK_PROXY_URL;
// Use the same proxy the Flutter client uses if available; otherwise
// hit DeepSeek directly with the server's own API key.
const DEEPSEEK_ENDPOINT = DEEPSEEK_PROXY_URL ||
  'https://api.deepseek.com/v1/chat/completions';
const APP_TRANSLATE_TOKEN = process.env.APP_TRANSLATE_TOKEN ?? '';

const SLA_HOURS = 24;

// ── App context cheat-sheet ─────────────────────────────────────────
// Rough living document of what the app does + common questions. The
// model uses this to answer factually rather than confabulating.
const APP_CONTEXT = `Interact Pro is a mobile PDF workstation for Android & iPad.

Core features the user might ask about:
• PDF viewer with annotations (highlight, signature, stamp, hotspots).
• "Book mode" — long-press a book on the Library shelf to read with
  page-flip animation; on landscape iPad it's a 2-page spread.
• Document scanner — Home → ⋮ overflow → Scan Document → uses the camera
  to scan + auto-crop pages into a PDF.
• OCR — extract text from any PDF or photo. ML Kit on-device by default.
• Translate — selection or full-page translation via DeepSeek (16 langs).
• Read aloud / dictation — TTS read + voice-to-text (Pro feature).
• Handwriting — draw on screen → text via ML Kit digital ink, or
  photograph handwritten notes → transcribed (DeepSeek vision).
• Image identifier — what's in this picture, with optional AI deep-dive.
• QR / barcode scanner + generator (history saved).
• Cast to TV — via OS share sheet (AirPlay on iOS, Cast targets on
  Android; in-app SDK currently disabled).
• LAN device pairing — Send PDF to other Interact Pro devices on same
  Wi-Fi via mDNS pairing.
• Save to Google Drive — Settings → Sign in with Google → ⋮ Save to Drive.
• Cloud sync to our server — Pro feature, stores PDFs on
  pro.interactpak.com (active during 7-day trial + Pro subscription).
• Print — Home → ⋮ Print. Uses OS print sheet. On Android, the user
  needs Mopria or Brother Print Service Plugin installed for the
  printer to be discoverable.

Common issues and fixes:
• "Printer not found on Android" → install Mopria Print Service from
  Play Store. Brother users can use Brother Print Service Plugin.
• "Printer not found on iOS" → Settings → Interact Pro → Local Network
  → On.
• "Trial expired" → upgrade via the in-app paywall, OR contact admin
  to extend.
• "Can't sign in" → check email spam / verify number country code.

Out of scope — politely decline:
• Anything not about Interact Pro.
• Account-specific data ("what's my password", "show my files") — direct
  to the relevant in-app screen instead.
• Hate speech, illegal activity, etc.`;

// Phrases that signal the AI is uncertain and we should hand off.
const HEDGE_PATTERNS = [
  /i'?m not sure/i,
  /i don'?t (?:know|have)/i,
  /contact (?:our )?support/i,
  /can'?t help/i,
  /unable to/i,
  /please reach out/i,
  /escalat\w*/i,
];

/**
 * Draft an AI reply to the latest user message in the given
 * conversation. Returns one of:
 *   { kind: 'reply', body: '...' }     — confident; send as AI message
 *   { kind: 'handoff', reason: '...' } — uncertain; mark for admin
 *   { kind: 'error',  reason: '...' } — couldn't reach DeepSeek
 *
 * Pass the FULL message history so the model has full context. Keep
 * it bounded (e.g. last 20 turns) to stay under token limits.
 */
export async function draftAiReply({ history }) {
  if (!DEEPSEEK_API_KEY && !DEEPSEEK_PROXY_URL) {
    return { kind: 'handoff', reason: 'AI not configured' };
  }

  const messages = [
    { role: 'system', content: buildSystemPrompt() },
    ...history.slice(-20).map((m) => ({
      role: m.role === 'user' ? 'user'
          : m.role === 'admin' ? 'assistant'
          : m.role === 'ai' ? 'assistant'
          : 'system',
      content: m.body,
    })),
  ];

  const headers = { 'Content-Type': 'application/json' };
  if (DEEPSEEK_PROXY_URL && APP_TRANSLATE_TOKEN) {
    headers['X-App-Token'] = APP_TRANSLATE_TOKEN;
  } else if (DEEPSEEK_API_KEY) {
    headers['Authorization'] = `Bearer ${DEEPSEEK_API_KEY}`;
  }

  try {
    const res = await fetch(DEEPSEEK_ENDPOINT, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages,
        temperature: 0.3,
        max_tokens: 350,
        stream: false,
      }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      console.error(`DeepSeek chat error ${res.status}: ${body.slice(0, 200)}`);
      return { kind: 'error', reason: `Upstream ${res.status}` };
    }
    const json = await res.json();
    const content =
      json?.choices?.[0]?.message?.content?.trim() ?? '';

    if (!content) return { kind: 'handoff', reason: 'Empty AI response' };
    if (HEDGE_PATTERNS.some((rx) => rx.test(content))) {
      return { kind: 'handoff', reason: 'AI hedged' };
    }
    return { kind: 'reply', body: content };
  } catch (err) {
    console.error(`DeepSeek chat call failed: ${err.message}`);
    return { kind: 'error', reason: err.message };
  }
}

function buildSystemPrompt() {
  return `You are the in-app support assistant for Interact Pro.

${APP_CONTEXT}

Style:
• Friendly, concise (≤ 4 sentences for routine questions, longer only
  if the user explicitly asks for detail).
• Step-by-step for "how do I X" answers — use short numbered or
  bulleted lists.
• If you cannot reasonably help (off-topic, account-specific, complex
  bug), say so plainly. The system will then route the user to a human
  admin who replies within ${SLA_HOURS} hours.
• Never invent features the app doesn't have. The list above is the
  source of truth.`;
}

export const SLA_MESSAGE = `Got it — I've flagged this for an admin. They typically reply within ${SLA_HOURS} hours. You'll see their message here as soon as it's posted.`;
