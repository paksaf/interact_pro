// Chat-with-document (market-fit Gate B, 2026-06-12) — the feature ChatPDF
// and Acrobat AI lead with. Grounds answers in the PDF's extracted text so
// the model quotes the document instead of hallucinating. Reuses the same
// DeepSeek endpoint/auth as the support responder (chat-ai.js).
//
// Contract:
//   POST /api/ai/doc-chat  (auth + Pro entitlement)
//   body { docText: string, question: string, mode?: 'ask'|'summarize'|'extract'|'translate', targetLang?, history?: [{role,content}] }
//   → { ok: true, answer: string, truncated: boolean }
//
// The client extracts page text (Syncfusion PdfTextExtractor) and sends it.
// Text is hard-capped so a 500-page PDF can't blow the token budget — the
// client should send the relevant pages (current ± a few) for long docs.

const DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY;
const DEEPSEEK_PROXY_URL = process.env.DEEPSEEK_PROXY_URL;
const DEEPSEEK_ENDPOINT =
  DEEPSEEK_PROXY_URL || 'https://api.deepseek.com/v1/chat/completions';
const APP_TRANSLATE_TOKEN = process.env.APP_TRANSLATE_TOKEN ?? '';

const MAX_DOC_CHARS = 24000; // ~6-8k tokens of context, leaves room for answer

function modePrompt(mode, targetLang) {
  switch (mode) {
    case 'summarize':
      return 'Summarize the document below in clear bullet points. Be faithful to the text; do not invent facts.';
    case 'extract':
      return 'Extract the key facts, figures, dates, names and action items from the document below as a structured list.';
    case 'translate':
      return `Translate the document below into ${targetLang || 'English'}. Preserve meaning and formatting; do not add commentary.`;
    default:
      return 'Answer the user\'s question using ONLY the document below. If the answer is not in the document, say so plainly. Quote the relevant passage when helpful.';
  }
}

export async function docChat({ docText, question, mode = 'ask', targetLang, history = [] }) {
  if (!DEEPSEEK_API_KEY && !DEEPSEEK_PROXY_URL) {
    return { ok: false, error: 'AI not configured on this server' };
  }
  const raw = String(docText || '');
  const truncated = raw.length > MAX_DOC_CHARS;
  const doc = truncated ? raw.slice(0, MAX_DOC_CHARS) : raw;
  if (!doc.trim()) {
    return { ok: false, error: 'No document text — this PDF may be scanned (run OCR first).' };
  }

  const system =
    'You are Interact Pro\'s document assistant. ' +
    modePrompt(mode, targetLang) +
    (truncated ? ' NOTE: the document was truncated; answer from the provided portion and say if more context is needed.' : '');

  const messages = [
    { role: 'system', content: system },
    ...history.slice(-8).map((m) => ({
      role: m.role === 'user' ? 'user' : 'assistant',
      content: String(m.content || '').slice(0, 2000),
    })),
    {
      role: 'user',
      content:
        (mode === 'ask' && question ? `Question: ${question}\n\n` : '') +
        `--- DOCUMENT ---\n${doc}\n--- END DOCUMENT ---`,
    },
  ];

  const headers = { 'Content-Type': 'application/json' };
  if (DEEPSEEK_PROXY_URL && APP_TRANSLATE_TOKEN) headers['X-App-Token'] = APP_TRANSLATE_TOKEN;
  else if (DEEPSEEK_API_KEY) headers['Authorization'] = `Bearer ${DEEPSEEK_API_KEY}`;

  try {
    const res = await fetch(DEEPSEEK_ENDPOINT, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        model: 'deepseek-chat',
        messages,
        temperature: 0.2,
        max_tokens: 900,
        stream: false,
      }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      return { ok: false, error: `Upstream ${res.status}: ${body.slice(0, 160)}` };
    }
    const json = await res.json();
    const answer = json?.choices?.[0]?.message?.content?.trim() ?? '';
    if (!answer) return { ok: false, error: 'Empty response from AI' };
    return { ok: true, answer, truncated };
  } catch (e) {
    return { ok: false, error: e.name === 'TimeoutError' ? 'AI timed out' : e.message };
  }
}
