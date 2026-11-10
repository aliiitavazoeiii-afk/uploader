'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { pipeline } = require('node:stream/promises');
const { URL } = require('node:url');

const PORT = Number(process.env.PORT || 3000);
const DATA = process.env.DATA_DIR || path.join(__dirname, 'data');
const VIDEO_DIR = path.join(DATA, 'videos');
const INDEX_PATH = path.join(DATA, 'index.json');
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '';
const SESSION_SECRET = process.env.SESSION_SECRET || '';
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/$/, '');
const MIN_FREE_BYTES = Number(process.env.MIN_FREE_BYTES || 1610612736); // reserve 1.5 GiB for OS
const MAX_FILE_BYTES = 30 * 1024 ** 3;
const CHUNK_SIZE = 8 * 1024 * 1024;
const MAX_ACTIVE_UPLOADS = 3;
const MAX_PARALLEL_CHUNKS = 6;
const UPLOAD_IDLE_MS = 6 * 60 * 60 * 1000;
const SESSION_LIFE_SECONDS = 7 * 24 * 60 * 60;
const APP_HTML = fs.readFileSync(path.join(__dirname, 'index.html'));
const ALLOWED_EXTENSIONS = new Set(['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v', '.wmv', '.mpeg', '.mpg', '.3gp', '.ts']);

if (ADMIN_PASSWORD.length < 12 || SESSION_SECRET.length < 32) {
  console.error('Missing or weak ADMIN_PASSWORD or SESSION_SECRET environment variables.');
  process.exit(1);
}
fs.mkdirSync(VIDEO_DIR, { recursive: true });
// Recover disk space from uploads interrupted by an earlier process shutdown.
for (const filename of fs.readdirSync(VIDEO_DIR)) {
  if (/^[a-f0-9]{48}\.part$/.test(filename)) fs.rmSync(path.join(VIDEO_DIR, filename), { force: true });
}
if (!fs.existsSync(INDEX_PATH)) fs.writeFileSync(INDEX_PATH, '{"files":[]}\n', { flag: 'wx' });
let catalog = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf8'));
if (!Array.isArray(catalog.files)) throw new Error('Invalid file index');
let reservations = new Map();
const activeUploads = new Map();
let authFailures = new Map();

function send(res, status, data, headers = {}) {
  const body = Buffer.from(JSON.stringify(data));
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': body.length,
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers });
  res.end(body);
}
function saveIndex() {
  const temp = INDEX_PATH + '.' + crypto.randomBytes(6).toString('hex') + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(catalog, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(temp, INDEX_PATH);
}
function validPassword(candidate) {
  const a = crypto.createHash('sha256').update(String(candidate)).digest();
  const b = crypto.createHash('sha256').update(ADMIN_PASSWORD).digest();
  return crypto.timingSafeEqual(a, b);
}
function sign(payload) {
  return crypto.createHmac('sha256', SESSION_SECRET).update(payload).digest('base64url');
}
function sessionCookie() {
  const value = `${Date.now() + SESSION_LIFE_SECONDS * 1000}.${crypto.randomBytes(12).toString('base64url')}`;
  return `${value}.${sign(value)}`;
}
function authorized(req) {
  const raw = (req.headers.cookie || '').split(';').map(x => x.trim()).find(x => x.startsWith('vd_session='));
  if (!raw) return false;
  const token = raw.slice('vd_session='.length);
  const pieces = token.split('.');
  if (pieces.length !== 3) return false;
  const payload = pieces[0] + '.' + pieces[1];
  const expected = Buffer.from(sign(payload));
  const actual = Buffer.from(pieces[2]);
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual) && Number(pieces[0]) > Date.now();
}
function checkMutationOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true; // e.g. script/curl, still needs session authentication
  const host = req.headers.host;
  try { return new URL(origin).host === host && new URL(origin).protocol === 'https:'; }
  catch { return false; }
}
function cleanName(value) {
  let name;
  try { name = decodeURIComponent(value || ''); } catch { return ''; }
  return name.normalize('NFC').replace(/[\\/\x00-\x1f\x7f<>:"|?*]/g, '_').replace(/^\.+/, '').trim().slice(0, 180);
}
function diskInfo() {
  const s = fs.statfsSync(VIDEO_DIR, { bigint: true });
  return { diskTotal: Number(s.blocks * s.bsize), diskFree: Number(s.bavail * s.bsize) };
}
function publicUrl(file) { return `${PUBLIC_BASE_URL}/d/${file.id}/${encodeURIComponent(file.name)}`; }
function sessionIp(req) { return String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim(); }
async function readJson(req, max = 4096) {
  const chunks = []; let n = 0;
  for await (const chunk of req) { n += chunk.length; if (n > max) throw new Error('TOO_LARGE'); chunks.push(chunk); }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
function fileStats() {
  const disk = diskInfo();
  return { ...disk, reserve: MIN_FREE_BYTES, used: catalog.files.reduce((sum, f) => sum + f.size, 0),
    inProgress: [...reservations.values()].reduce((sum, val) => sum + val, 0),
    files: [...catalog.files].reverse().map(f => ({ id: f.id, name: f.name, size: f.size, created: f.created, url: publicUrl(f) })) };
}

function handleDownload(req, res, urlPath) {
  const match = /^\/d\/([a-f0-9]{48})(?:\/.*)?$/.exec(urlPath);
  if (!match) return send(res, 404, { error: 'فایل پیدا نشد' });
  const file = catalog.files.find(item => item.id === match[1]);
  if (!file) return send(res, 404, { error: 'لینک منقضی یا حذف شده است' });
  const filePath = path.join(VIDEO_DIR, file.id + '.bin');
  let stat;
  try { stat = fs.statSync(filePath); } catch { return send(res, 404, { error: 'فایل وجود ندارد' }); }
  const size = stat.size;
  let start = 0, end = size - 1, status = 200;
  const range = req.headers.range;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (!m || (!m[1] && !m[2]) || m[0].includes(',')) {
      res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end();
    }
    if (!m[1]) {
      const suffix = Number(m[2]);
      if (!Number.isSafeInteger(suffix) || suffix <= 0) {
        res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end();
      }
      start = Math.max(0, size - suffix);
    } else {
      start = Number(m[1]);
      end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
    }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) {
      res.writeHead(416, { 'Content-Range': `bytes */${size}` }); return res.end();
    }
    status = 206;
  }
  const headers = { 'Content-Type': 'application/octet-stream',
    'Content-Disposition': `attachment; filename="video"; filename*=UTF-8''${encodeURIComponent(file.name)}`,
    'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes', 'Cache-Control': 'private, no-store',
    'X-Content-Type-Options': 'nosniff', 'X-Robots-Tag': 'noindex, nofollow' };
  if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
  res.writeHead(status, headers);
  if (req.method === 'HEAD') return res.end();
  const stream = fs.createReadStream(filePath, { start, end });
  stream.on('error', () => res.destroy());
  res.on('close', () => stream.destroy());
  stream.pipe(res);
}

async function upload(req, res) {
  const name = cleanName(req.headers['x-file-name']);
  const length = Number(req.headers['content-length']);
  if (!name || !ALLOWED_EXTENSIONS.has(path.extname(name).toLowerCase())) return send(res, 400, { error: 'فقط فایل ویدئویی مجاز است' });
  if (!Number.isSafeInteger(length) || length <= 0 || length > MAX_FILE_BYTES) return send(res, 413, { error: 'حجم فایل نامعتبر یا بیش از حد مجاز است' });
  const { diskFree } = diskInfo();
  const reserved = [...reservations.values()].reduce((sum, v) => sum + v, 0);
  if (diskFree - reserved - length < MIN_FREE_BYTES) return send(res, 507, { error: 'فضای کافی روی سرور باقی نمانده است' });
  const id = crypto.randomBytes(24).toString('hex');
  const temporary = path.join(VIDEO_DIR, id + '.part');
  const destination = path.join(VIDEO_DIR, id + '.bin');
  reservations.set(id, length);
  try {
    let received = 0;
    req.on('data', chunk => { received += chunk.length; });
    await pipeline(req, fs.createWriteStream(temporary, { flags: 'wx', mode: 0o600 }));
    if (received !== length) throw new Error('UPLOAD_INCOMPLETE');
    fs.renameSync(temporary, destination);
    const entry = { id, name, size: length, created: new Date().toISOString() };
    catalog.files.push(entry);
    try { saveIndex(); } catch (e) { catalog.files.pop(); fs.rmSync(destination, { force: true }); throw e; }
    send(res, 201, { ok: true, file: { ...entry, url: publicUrl(entry) } });
  } catch (err) {
    try { fs.rmSync(temporary, { force: true }); } catch {}
    if (!res.writableEnded && !res.destroyed) send(res, 500, { error: 'آپلود کامل نشد؛ دوباره امتحان کنید' });
    console.error('upload error', err.code || err.message);
  } finally { reservations.delete(id); }
}

// Parallel chunk uploads: each chunk is written directly to its offset on disk.
// Existing /api/upload remains supported for older browser sessions.
function cleanupMultipart(record) {
  activeUploads.delete(record.id);
  reservations.delete(record.id);
  try { fs.rmSync(record.temporary, { force: true }); } catch {}
}
async function initMultipart(req, res) {
  let input;
  try { input = await readJson(req, 2048); } catch { return send(res, 400, { error: 'اطلاعات فایل نامعتبر است' }); }
  const name = cleanName(input.name);
  const size = input.size;
  if (!name || !ALLOWED_EXTENSIONS.has(path.extname(name).toLowerCase())) return send(res, 400, { error: 'فقط فایل ویدئویی مجاز است' });
  if (!Number.isSafeInteger(size) || size < 1 || size > MAX_FILE_BYTES) return send(res, 413, { error: 'حجم فایل نامعتبر است' });
  if (activeUploads.size >= MAX_ACTIVE_UPLOADS) return send(res, 429, { error: 'تعداد آپلودهای هم‌زمان زیاد است' });
  const reserved = [...reservations.values()].reduce((sum, v) => sum + v, 0);
  if (diskInfo().diskFree - reserved - size < MIN_FREE_BYTES) return send(res, 507, { error: 'فضای کافی روی سرور باقی نمانده است' });
  const id = crypto.randomBytes(24).toString('hex');
  const temporary = path.join(VIDEO_DIR, id + '.part');
  let fd;
  try {
    fd = fs.openSync(temporary, 'wx+', 0o600);
    fs.ftruncateSync(fd, size); // sparse file; only transferred bytes occupy disk blocks
  } catch (err) {
    try { if (fd !== undefined) fs.closeSync(fd); } catch {}
    try { fs.rmSync(temporary, { force: true }); } catch {}
    return send(res, 507, { error: 'امکان رزرو فایل روی دیسک وجود ندارد' });
  }
  fs.closeSync(fd);
  const record = { id, name, size, temporary, chunks: Math.ceil(size / CHUNK_SIZE),
    received: new Set(), inflight: new Set(), lastActivity: Date.now(), cancelled: false, completing: false };
  activeUploads.set(id, record);
  reservations.set(id, size);
  return send(res, 201, { id, chunkSize: CHUNK_SIZE, chunks: record.chunks });
}
async function receiveChunk(req, res, id, part) {
  const record = activeUploads.get(id);
  if (!record || record.cancelled) return send(res, 404, { error: 'آپلود پیدا نشد' });
  const index = Number(part);
  if (!Number.isSafeInteger(index) || index < 0 || index >= record.chunks) return send(res, 400, { error: 'شماره بخش نامعتبر است' });
  if (record.completing) return send(res, 409, { error: 'آپلود در حال تکمیل است' });
  if (record.received.has(index)) return send(res, 200, { ok: true, alreadyReceived: true });
  if (record.inflight.has(index)) return send(res, 409, { error: 'این بخش در حال دریافت است' });
  if (record.inflight.size >= MAX_PARALLEL_CHUNKS) return send(res, 429, { error: 'اتصال‌های هم‌زمان بیش از حد است' });
  const expected = Math.min(CHUNK_SIZE, record.size - index * CHUNK_SIZE);
  if (Number(req.headers['content-length']) !== expected) return send(res, 400, { error: 'حجم بخش با انتظار سرور مطابقت ندارد' });
  record.inflight.add(index);
  record.lastActivity = Date.now();
  try {
    let received = 0;
    req.on('data', piece => { received += piece.length; });
    await pipeline(req, fs.createWriteStream(record.temporary, { flags: 'r+', start: index * CHUNK_SIZE, highWaterMark: 1024 * 1024 }));
    if (received !== expected) throw new Error('CHUNK_INCOMPLETE');
    if (!record.cancelled) record.received.add(index);
    if (!res.destroyed && !res.writableEnded) return send(res, record.cancelled ? 410 : 200, { ok: !record.cancelled });
  } catch (err) {
    console.error('chunk error', id, index, err.code || err.message);
    if (!res.destroyed && !res.writableEnded) send(res, 500, { error: 'ارسال بخش ناموفق بود؛ دوباره تلاش کن' });
  } finally {
    record.inflight.delete(index);
    record.lastActivity = Date.now();
    if (record.cancelled && record.inflight.size === 0) cleanupMultipart(record);
  }
}
function finishMultipart(req, res, id) {
  const record = activeUploads.get(id);
  if (!record || record.cancelled) return send(res, 404, { error: 'آپلود پیدا نشد' });
  if (record.inflight.size || record.received.size !== record.chunks) return send(res, 409, { error: 'تمام بخش‌های فایل دریافت نشده‌اند' });
  if (record.completing) return send(res, 409, { error: 'آپلود در حال تکمیل است' });
  record.completing = true;
  const destination = path.join(VIDEO_DIR, id + '.bin');
  const entry = { id, name: record.name, size: record.size, created: new Date().toISOString() };
  try {
    fs.renameSync(record.temporary, destination);
    catalog.files.push(entry);
    try { saveIndex(); } catch (err) { catalog.files.pop(); throw err; }
    activeUploads.delete(id);
    reservations.delete(id);
    return send(res, 201, { ok: true, file: { ...entry, url: publicUrl(entry) } });
  } catch (err) {
    console.error('finalize error', err.code || err.message);
    try { fs.rmSync(destination, { force: true }); } catch {}
    cleanupMultipart(record);
    return send(res, 500, { error: 'ثبت فایل ناموفق بود' });
  }
}
function cancelMultipart(req, res, id) {
  const record = activeUploads.get(id);
  if (!record) return send(res, 200, { ok: true });
  if (record.completing) return send(res, 409, { error: 'آپلود در حال تکمیل است' });
  record.cancelled = true;
  if (!record.inflight.size) cleanupMultipart(record);
  return send(res, 200, { ok: true });
}
setInterval(() => {
  const now = Date.now();
  for (const record of activeUploads.values()) {
    if (now - record.lastActivity > UPLOAD_IDLE_MS && !record.completing) {
      record.cancelled = true;
      if (!record.inflight.size) cleanupMultipart(record);
    }
  }
}, 10 * 60 * 1000).unref();

async function handler(req, res) {
  try {
    const pathname = new URL(req.url, 'http://localhost').pathname;
    if ((req.method === 'GET' || req.method === 'HEAD') && pathname.startsWith('/d/')) return handleDownload(req, res, pathname);
    if (req.method === 'GET' && pathname === '/healthz') return send(res, 200, { ok: true });
    if (req.method === 'GET' && pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': APP_HTML.length,
        'Cache-Control': 'no-store', 'Content-Security-Policy': "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY', 'X-Content-Type-Options': 'nosniff' });
      return res.end(APP_HTML);
    }
    if (req.method === 'POST' && pathname === '/api/login') {
      if (!checkMutationOrigin(req)) return send(res, 403, { error: 'درخواست نامعتبر' });
      const ip = sessionIp(req), prev = authFailures.get(ip) || { count: 0, until: 0 };
      if (prev.until > Date.now()) return send(res, 429, { error: 'تلاش زیاد؛ ۱۵ دقیقه بعد دوباره امتحان کنید' });
      let data;
      try { data = await readJson(req); } catch { return send(res, 400, { error: 'درخواست نامعتبر' }); }
      if (!validPassword(data.password)) {
        const count = prev.count + 1;
        authFailures.set(ip, { count, until: count >= 6 ? Date.now() + 15 * 60_000 : 0 });
        return send(res, 401, { error: 'رمز عبور اشتباه است' });
      }
      authFailures.delete(ip);
      return send(res, 200, { ok: true }, { 'Set-Cookie': `vd_session=${sessionCookie()}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${SESSION_LIFE_SECONDS}` });
    }
    if (pathname.startsWith('/api/')) {
      if (!authorized(req)) return send(res, 401, { error: 'لطفاً وارد شوید' });
      if (req.method !== 'GET' && !checkMutationOrigin(req)) return send(res, 403, { error: 'درخواست نامعتبر' });
      if (req.method === 'GET' && pathname === '/api/state') return send(res, 200, fileStats());
      if (req.method === 'POST' && pathname === '/api/logout') return send(res, 200, { ok: true }, { 'Set-Cookie': 'vd_session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0' });
      if (req.method === 'POST' && pathname === '/api/upload') return upload(req, res);
      if (req.method === 'POST' && pathname === '/api/uploads') return initMultipart(req, res);
      const chunkMatch = /^\/api\/uploads\/([a-f0-9]{48})\/chunks\/(\d+)$/.exec(pathname);
      if (req.method === 'POST' && chunkMatch) return receiveChunk(req, res, chunkMatch[1], chunkMatch[2]);
      const uploadMatch = /^\/api\/uploads\/([a-f0-9]{48})$/.exec(pathname);
      if (uploadMatch && req.method === 'POST') return finishMultipart(req, res, uploadMatch[1]);
      if (uploadMatch && req.method === 'DELETE') return cancelMultipart(req, res, uploadMatch[1]);
      const m = /^\/api\/files\/([a-f0-9]{48})$/.exec(pathname);
      if (req.method === 'DELETE' && m) {
        const i = catalog.files.findIndex(f => f.id === m[1]);
        if (i < 0) return send(res, 404, { error: 'فایل یافت نشد' });
        const f = catalog.files[i];
        catalog.files.splice(i, 1); saveIndex();
        fs.rmSync(path.join(VIDEO_DIR, f.id + '.bin'), { force: true });
        return send(res, 200, { ok: true });
      }
    }
    return send(res, 404, { error: 'صفحه پیدا نشد' });
  } catch (err) {
    console.error('request error', err);
    if (!res.headersSent) send(res, 500, { error: 'خطای سرور' }); else res.destroy();
  }
}

const server = http.createServer({ requestTimeout: 0, headersTimeout: 60_000 }, handler);
server.listen(PORT, '0.0.0.0', () => console.log(`VideoShare listening on ${PORT}`));