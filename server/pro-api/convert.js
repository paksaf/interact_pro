// SPDX-License-Identifier: AGPL-3.0
//
// Spike E — Office → PDF conversion via libreoffice headless.
//
// Lets the Pro app render .docx / .doc / .xlsx / .xls / .pptx / .ppt /
// .rtf / .odt / .ods / .odp / Pages / Numbers / Keynote natively in
// the existing PDF viewer instead of handing off to whatever Office
// app the user has installed. Conversion is server-side because:
//
//   • LibreOffice on every Android / iOS device is a non-starter.
//   • The Hetzner VPS already runs LibreOffice headless for the
//     legacy estimates/invoice → PDF pipeline. Reuses that binary.
//   • Cached by sha256(input) so re-opens are zero-latency.
//
// VPS prereq:
//   sudo apt install libreoffice --no-install-recommends
//   sudo apt install fonts-noto-cjk fonts-noto-color-emoji   # CJK + emoji
//
// Caddy block (add inside `pro.interactpak.com {}`):
//   handle_path /api/convert/* { reverse_proxy 127.0.0.1:3050 }
// (Already covered by the existing /api/* proxy; this is a
//  reminder — no Caddy change needed.)

import { spawn } from 'node:child_process';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, stat, unlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CACHE_DIR = process.env.CONVERT_CACHE_DIR || '/var/cache/interact-pro/convert';
const LIBREOFFICE_BIN = process.env.LIBREOFFICE_BIN || '/usr/bin/libreoffice';
const CONVERT_TIMEOUT_MS = 60_000;

// Supported source MIME → libreoffice filter target. All produce PDF
// via the canonical `pdf` writer. The discriminator here exists in
// case we ever want different output profiles (PDF/A vs. plain PDF).
const SUPPORTED = new Map([
  ['application/msword', 'pdf'],
  ['application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'pdf'],
  ['application/vnd.ms-excel', 'pdf'],
  ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'pdf'],
  ['application/vnd.ms-powerpoint', 'pdf'],
  ['application/vnd.openxmlformats-officedocument.presentationml.presentation', 'pdf'],
  ['application/rtf', 'pdf'],
  ['application/vnd.oasis.opendocument.text', 'pdf'],
  ['application/vnd.oasis.opendocument.spreadsheet', 'pdf'],
  ['application/vnd.oasis.opendocument.presentation', 'pdf'],
  ['application/vnd.apple.pages', 'pdf'],
  ['application/vnd.apple.numbers', 'pdf'],
  ['application/vnd.apple.keynote', 'pdf'],
]);

/**
 * Multer-style middleware compatible with the existing pro-api
 * `upload` import (used by /api/sync/upload). Caller wires it up
 * as:
 *
 *   import { convertToPdfRoute } from './convert.js';
 *   app.post('/api/convert/to-pdf', requireAuth,
 *            upload.single('file'), convertToPdfRoute);
 *
 * Returns the converted PDF as a binary stream. The original file is
 * NOT persisted — we cache the OUTPUT PDF by sha256(input) so a
 * second user uploading the same .docx gets the cached result.
 */
export async function convertToPdfRoute(req, res) {
  if (!req.file) {
    return res.status(400).json({ error: 'Missing "file" multipart part.' });
  }
  const mime = req.file.mimetype;
  if (!SUPPORTED.has(mime)) {
    return res.status(415).json({
      error: `Unsupported MIME: ${mime}`,
      supported: Array.from(SUPPORTED.keys()),
    });
  }

  // Cache by sha256 of the input bytes. Same .docx → same PDF.
  const inputHash = createHash('sha256').update(req.file.buffer).digest('hex');
  await mkdir(CACHE_DIR, { recursive: true });
  const cachedPath = join(CACHE_DIR, `${inputHash}.pdf`);

  try {
    const st = await stat(cachedPath);
    if (st.size > 0) {
      res.setHeader('Content-Type', 'application/pdf');
      res.setHeader('X-Cache', 'HIT');
      res.setHeader('Content-Length', st.size);
      return createReadStream(cachedPath).pipe(res);
    }
  } catch {
    // not cached — fall through to convert
  }

  // Write the input to a temp file (libreoffice can only operate on
  // files, not stdin). Use a per-request workdir so concurrent
  // conversions don't collide.
  const workDir = join(tmpdir(), `lo-${process.pid}-${Date.now()}`);
  await mkdir(workDir, { recursive: true });
  const ext = extFor(mime);
  const inputPath = join(workDir, `input.${ext}`);
  await writeFile(inputPath, req.file.buffer);

  try {
    await runLibreOffice(inputPath, workDir);
    // LO writes to <workDir>/input.pdf
    const outPath = join(workDir, 'input.pdf');
    const outStat = await stat(outPath).catch(() => null);
    if (!outStat || outStat.size === 0) {
      return res
        .status(500)
        .json({ error: 'LibreOffice produced no output.' });
    }
    // Move into the cache atomically.
    await pipe(outPath, cachedPath);
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('X-Cache', 'MISS');
    res.setHeader('Content-Length', outStat.size);
    createReadStream(cachedPath).pipe(res);
  } catch (e) {
    return res.status(500).json({ error: `Conversion failed: ${e.message}` });
  } finally {
    // Best-effort cleanup. Cache-hit path already returned before this.
    unlink(inputPath).catch(() => {});
  }
}

function extFor(mime) {
  return ({
    'application/msword': 'doc',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
    'application/vnd.ms-excel': 'xls',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
    'application/vnd.ms-powerpoint': 'ppt',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
    'application/rtf': 'rtf',
    'application/vnd.oasis.opendocument.text': 'odt',
    'application/vnd.oasis.opendocument.spreadsheet': 'ods',
    'application/vnd.oasis.opendocument.presentation': 'odp',
    'application/vnd.apple.pages': 'pages',
    'application/vnd.apple.numbers': 'numbers',
    'application/vnd.apple.keynote': 'key',
  }[mime] || 'bin');
}

function runLibreOffice(inputPath, outDir) {
  return new Promise((resolve, reject) => {
    const proc = spawn(
      LIBREOFFICE_BIN,
      [
        '--headless',
        '--nologo',
        '--nofirststartwizard',
        '--convert-to', 'pdf',
        '--outdir', outDir,
        inputPath,
      ],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    let stderr = '';
    proc.stderr.on('data', (b) => { stderr += b.toString(); });
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`LibreOffice timed out after ${CONVERT_TIMEOUT_MS}ms`));
    }, CONVERT_TIMEOUT_MS);
    proc.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`LibreOffice exit ${code}: ${stderr.slice(0, 500)}`));
        return;
      }
      resolve();
    });
    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function pipe(src, dest) {
  return new Promise((resolve, reject) => {
    const r = createReadStream(src);
    const w = createWriteStream(dest);
    r.on('error', reject);
    w.on('error', reject);
    w.on('close', resolve);
    r.pipe(w);
  });
}
