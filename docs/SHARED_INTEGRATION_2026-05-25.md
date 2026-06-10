# interact_pro — Shared Services Integration Plan

**Date:** 2026-05-25
**Companion to:** `_shared/knowledge-hub/COMMS_AND_AI_OPPORTUNITIES.md`

## What landed in shared today (because of interact_pro)

1. **`_shared/services/comms-client/resend-direct.ts`** — the canonical Resend HTTPS pattern that interact_pro proved on the Hetzner VPS is now reusable by every app. Exported from `@interact/comms-client` as `sendEmailDirectResend`. interact_pro's own `server/pro-api/email.js` stays put for now (its env-var names — `OTP_MAIL_FROM`, `OTP_MAIL_REPLY_TO` — are baked into the systemd unit) but new INTERACT apps can pull this from shared instead of re-deriving the pattern.

## What needs to happen in interact_pro (next sessions)

| # | Action | Why |
|---|---|---|
| 1 | Add a thin Dart wrapper in `lib/core/comms/` that re-exports the shared `interact_realtime` package (`_shared/services/realtime-client/dart/`). | Future remote-collab features (PDF live edit, voice annotation) consume the same signaling stack as AutoSenseAI. |
| 2 | Convert `lib/features/voice/data/{stt,tts,voice_command}_controller.dart` into a publishable Dart package at `_shared/services/voice-controllers/dart/`. | AutoSenseAI's M2 needs identical Riverpod-wrapped STT/TTS; copying is forbidden by the comms-fix rule "don't override or redo whole jobs separately for all". |
| 3 | When the Pro AI backend ships ColPali retrieval, expose it at `pro.interactpak.com/api/retrieval/*` and let interact_pro's library search and AutoSenseAI's fault-signature retrieval both call it. | The interact-pro-ai-backend is already the canonical FastAPI + systemd + Caddy deploy template. |
| 4 | Replace `server/pro-api/email.js` with `import { sendEmailDirectResend } from "@interact/comms-client/resend-direct"`. | Single source of truth — eliminates drift. |

## Don't do

- Don't migrate `interact_pro/server/pro-api/email.js` until step 4 above. The current file works and is wired to the existing systemd OTP_MAIL_* env vars.
- Don't move `lib/features/casting/` to shared yet — the Bonsoir + DLNA + shelf stack is interact_pro-specific until a second app needs it (Sahulat seller↔buyer live-photo share is the likely first reuse case).
