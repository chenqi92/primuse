import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import worker, { cleanupExpiredShares, testing } from "../src/index.mjs";

const TEST_ADMIN_TOKEN = "test-admin-token-with-more-than-thirty-two-characters";
const TEST_CHUNK_SIZE = 5 * 1024 * 1024;
const utf8 = new TextEncoder();
const utf8Decoder = new TextDecoder();

test("encrypted multipart upload supports full reads, ranges, validators, and secret boundaries", {
  timeout: 60_000,
}, async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket);
  const context = new TestContext();
  const media = new Uint8Array(TEST_CHUNK_SIZE + 65_537);
  for (let index = 0; index < media.byteLength; index += 1) {
    media[index] = index % 251;
  }

  const creation = await createAndUpload({
    bucket,
    env,
    context,
    media,
    fileName: "夜航 / Live.flac",
    contentType: "audio/flac",
  });
  await context.flush();
  const publicPath = new URL(creation.publicURL).pathname;

  const closedUpload = await fetchRelay(env, context, `/v1/uploads/${creation.shareID}/chunks/0`, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${creation.uploadToken}`,
      "Content-Type": "application/octet-stream",
      "Content-Range": `bytes 0-${TEST_CHUNK_SIZE - 1}/${media.byteLength}`,
    },
    body: media.slice(0, TEST_CHUNK_SIZE),
  });
  assert.equal(closedUpload.status, 409);
  await context.flush();
  assert.notEqual(bucket.raw(`data/${creation.shareID}.bin`), null);

  const head = await fetchRelay(env, context, publicPath, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("Accept-Ranges"), "bytes");
  assert.equal(head.headers.get("Content-Length"), String(media.byteLength));
  assert.match(head.headers.get("Content-Disposition"), /filename\*=UTF-8''/);
  assert.equal(head.headers.get("Cache-Control"), "private, no-store, max-age=0");
  assert.equal(head.headers.get("Referrer-Policy"), "no-referrer");

  const rangeStart = TEST_CHUNK_SIZE - 31;
  const rangeEnd = TEST_CHUNK_SIZE + 79;
  const range = await fetchRelay(env, context, publicPath, {
    headers: { Range: `bytes=${rangeStart}-${rangeEnd}` },
  });
  assert.equal(range.status, 206);
  assert.equal(range.headers.get("Content-Range"), `bytes ${rangeStart}-${rangeEnd}/${media.byteLength}`);
  assert.deepEqual(new Uint8Array(await range.arrayBuffer()), media.slice(rangeStart, rangeEnd + 1));

  const suffix = await fetchRelay(env, context, publicPath, {
    headers: { Range: "bytes=-257" },
  });
  assert.equal(suffix.status, 206);
  assert.deepEqual(new Uint8Array(await suffix.arrayBuffer()), media.slice(-257));

  const invalid = await fetchRelay(env, context, publicPath, {
    headers: { Range: "bytes=99999999-100000000" },
  });
  assert.equal(invalid.status, 416);
  assert.equal(invalid.headers.get("Content-Range"), `bytes */${media.byteLength}`);

  const unchanged = await fetchRelay(env, context, publicPath, {
    headers: { "If-None-Match": head.headers.get("ETag") },
  });
  assert.equal(unchanged.status, 304);

  const full = await fetchRelay(env, context, publicPath);
  assert.equal(full.status, 200);
  assert.deepEqual(new Uint8Array(await full.arrayBuffer()), media);

  const rawCiphertext = bucket.raw(`data/${creation.shareID}.bin`);
  assert.equal(
    rawCiphertext.byteLength,
    media.byteLength + 2 * testing.ENCRYPTED_CHUNK_OVERHEAD,
  );
  assert.equal(
    Buffer.from(rawCiphertext).indexOf(Buffer.from(media.subarray(0, 128))),
    -1,
  );
  const persistedText = bucket.textForPrefixes(["metadata/", "indexes/", "parts/"]);
  const publicToken = publicPath.split("/").at(-1);
  for (const secret of [TEST_ADMIN_TOKEN, creation.uploadToken, publicToken, "smb://private/music.flac"]) {
    assert.equal(persistedText.includes(secret), false, `persisted secret: ${secret.slice(0, 4)}`);
  }
  assert.deepEqual(bucket.keys(`parts/${creation.shareID}/`), []);
});

test("password protection and revocation preserve the public capability boundary", {
  timeout: 60_000,
}, async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket);
  const context = new TestContext();
  const media = utf8.encode("password-protected-media".repeat(4096));
  const password = "正确 horse";
  const creation = await createAndUpload({
    bucket,
    env,
    context,
    media,
    fileName: "测试音频.mp3",
    contentType: "audio/mpeg",
    password,
  });
  await context.flush();
  const publicPath = new URL(creation.publicURL).pathname;

  const missing = await fetchRelay(env, context, publicPath);
  assert.equal(missing.status, 401);
  assert.match(missing.headers.get("WWW-Authenticate"), /^Basic /);

  const wrong = await fetchRelay(env, context, publicPath, {
    headers: { Authorization: basicAuthorization("listener", "wrong") },
  });
  assert.equal(wrong.status, 401);

  const correct = await fetchRelay(env, context, publicPath, {
    headers: { Authorization: basicAuthorization("listener", password) },
  });
  assert.equal(correct.status, 200);
  assert.deepEqual(new Uint8Array(await correct.arrayBuffer()), media);

  const persistedMetadata = utf8Decoder.decode(bucket.raw(`metadata/${creation.shareID}.json`));
  assert.equal(persistedMetadata.includes(password), false);
  const revoke = await fetchRelay(env, context, `/v1/shares/${creation.shareID}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${creation.uploadToken}` },
  });
  assert.equal(revoke.status, 204);
  await context.flush();
  assert.equal(bucket.raw(`data/${creation.shareID}.bin`), null);

  const afterRevoke = await fetchRelay(env, context, publicPath, { method: "HEAD" });
  assert.equal(afterRevoke.status, 410);
  const metadata = JSON.parse(utf8Decoder.decode(bucket.raw(`metadata/${creation.shareID}.json`)));
  assert.ok(metadata.revokedAt);
  assert.ok(metadata.dataDeletedAt);
});

test("browser share page exposes only allowed actions and import tickets are one-time", {
  timeout: 60_000,
}, async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket);
  const context = new TestContext();
  const media = utf8.encode("designed-share-media".repeat(4096));
  const creation = await createAndUpload({
    bucket,
    env,
    context,
    media,
    fileName: "陈默寻 - 夜航西飞.flac",
    contentType: "audio/flac",
    title: "夜航西飞 <Live>",
    artist: "陈默寻",
    album: "潮汐纪年",
    audioFormat: "FLAC",
    quality: "24bit/96kHz",
    allowPlayback: true,
    allowDownload: false,
    allowImport: true,
  });
  await context.flush();
  const publicPath = new URL(creation.publicURL).pathname;

  const page = await fetchRelay(env, context, publicPath, {
    headers: { Accept: "text/html", "Sec-Fetch-Mode": "navigate" },
  });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("Content-Type"), /^text\/html/);
  assert.match(page.headers.get("Content-Security-Policy"), /default-src 'none'/);
  const html = await page.text();
  assert.match(html, /夜航西飞 &lt;Live&gt;/);
  assert.match(html, /陈默寻 · 《潮汐纪年》/);
  assert.match(html, /data-download hidden/);
  assert.match(html, new RegExp(`data-file-size="${media.byteLength}"`));
  assert.doesNotMatch(html, /<audio[^>]+src=/);

  const playable = await fetchRelay(env, context, `${publicPath}/media`, {
    headers: { Range: "bytes=20-79" },
  });
  assert.equal(playable.status, 206);
  assert.deepEqual(new Uint8Array(await playable.arrayBuffer()), media.slice(20, 80));

  const forbiddenDownload = await fetchRelay(env, context, `${publicPath}/download`);
  assert.equal(forbiddenDownload.status, 403);

  const ticketResponse = await fetchRelay(env, context, `${publicPath}/import`, {
    method: "POST",
    headers: { Origin: "https://share.soundisle.com", Accept: "application/json" },
  });
  assert.equal(ticketResponse.status, 201);
  const ticket = await ticketResponse.json();
  const importPath = new URL(ticket.importURL).pathname;
  const imported = await fetchRelay(env, context, importPath);
  assert.equal(imported.status, 200);
  assert.match(imported.headers.get("Content-Disposition"), /^attachment;/);
  assert.deepEqual(new Uint8Array(await imported.arrayBuffer()), media);
  await context.flush();
  const reused = await fetchRelay(env, context, importPath);
  assert.equal(reused.status, 410);
});

test("opening an expired browser share schedules encrypted media cleanup", {
  timeout: 60_000,
}, async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket);
  const context = new TestContext();
  const media = utf8.encode("expired-browser-media".repeat(2048));
  const creation = await createAndUpload({
    bucket,
    env,
    context,
    media,
    fileName: "expired.flac",
    contentType: "audio/flac",
  });
  await context.flush();

  const metadataKey = `metadata/${creation.shareID}.json`;
  const metadata = JSON.parse(utf8Decoder.decode(bucket.raw(metadataKey)));
  metadata.createdAt = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
  metadata.expiresAt = new Date(Date.now() - 1_000).toISOString();
  await bucket.put(metadataKey, JSON.stringify(metadata), {
    httpMetadata: { contentType: "application/json" },
  });

  const publicPath = new URL(creation.publicURL).pathname;
  const page = await fetchRelay(env, context, publicPath, {
    headers: { Accept: "text/html", "Sec-Fetch-Mode": "navigate" },
  });
  assert.equal(page.status, 410);
  await context.flush();
  assert.equal(bucket.raw(`data/${creation.shareID}.bin`), null);
  const cleanedMetadata = JSON.parse(utf8Decoder.decode(bucket.raw(metadataKey)));
  assert.ok(cleanedMetadata.dataDeletedAt);
});

test("password browser flow uses a signed session cookie without disclosing metadata", {
  timeout: 60_000,
}, async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket);
  const context = new TestContext();
  const media = utf8.encode("private-browser-media".repeat(2048));
  const creation = await createAndUpload({
    bucket,
    env,
    context,
    media,
    fileName: "私密歌曲.mp3",
    contentType: "audio/mpeg",
    password: "海屋2026",
    title: "不可提前泄露的标题",
  });
  const publicPath = new URL(creation.publicURL).pathname;

  const locked = await fetchRelay(env, context, publicPath, {
    headers: { Accept: "text/html", "Sec-Fetch-Mode": "navigate" },
  });
  assert.equal(locked.status, 200);
  const lockedHTML = await locked.text();
  assert.match(lockedHTML, /受密码保护/);
  assert.doesNotMatch(lockedHTML, /不可提前泄露|私密歌曲/);
  assert.equal(locked.headers.get("WWW-Authenticate"), null);

  const wrong = await fetchRelay(env, context, `${publicPath}/auth`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      Origin: "https://share.soundisle.com",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ password: "wrong" }),
  });
  assert.equal(wrong.status, 401);
  assert.equal(wrong.headers.get("WWW-Authenticate"), null);

  const unlocked = await fetchRelay(env, context, `${publicPath}/auth`, {
    method: "POST",
    headers: {
      Accept: "application/json",
      Origin: "https://share.soundisle.com",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({ password: "海屋2026" }),
  });
  assert.equal(unlocked.status, 200);
  const cookie = unlocked.headers.get("Set-Cookie");
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);
  assert.equal(cookie.includes("海屋2026"), false);

  const session = cookie.split(";", 1)[0];
  const privatePage = await fetchRelay(env, context, publicPath, {
    headers: {
      Accept: "text/html",
      "Sec-Fetch-Mode": "navigate",
      Cookie: session,
    },
  });
  assert.equal(privatePage.status, 200);
  assert.match(await privatePage.text(), /不可提前泄露的标题/);

  const privateMedia = await fetchRelay(env, context, `${publicPath}/media`, {
    headers: { Cookie: session },
  });
  assert.equal(privateMedia.status, 200);
  assert.deepEqual(new Uint8Array(await privateMedia.arrayBuffer()), media);
});

test("scheduled cleanup removes expired encrypted media and abandoned multipart uploads", {
  timeout: 60_000,
}, async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket, { UPLOAD_TTL_SECONDS: "60" });
  const context = new TestContext();
  const media = utf8.encode("expiring-media".repeat(1024));
  const expiresAt = new Date(Date.now() + 5 * 60 * 1000);
  const complete = await createAndUpload({
    bucket,
    env,
    context,
    media,
    fileName: "short.ogg",
    contentType: "audio/ogg",
    expiresAt,
  });
  await context.flush();

  const pending = await createOnly(env, context, {
    fileName: "abandoned.aac",
    contentType: "audio/aac",
    size: 4096,
    expiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
  });
  assert.equal(bucket.hasMultipartUploadFor(`data/${pending.shareID}.bin`), true);

  await cleanupExpiredShares(env, new Date(Date.now() + 10 * 60 * 1000));
  assert.equal(bucket.raw(`data/${complete.shareID}.bin`), null);
  assert.equal(bucket.hasMultipartUploadFor(`data/${pending.shareID}.bin`), false);

  const gone = await fetchRelay(env, context, new URL(complete.publicURL).pathname);
  assert.equal(gone.status, 410);
  const pendingMetadata = JSON.parse(utf8Decoder.decode(bucket.raw(`metadata/${pending.shareID}.json`)));
  assert.ok(pendingMetadata.dataDeletedAt);
});

test("configuration, authentication, media validation, and range parsing fail closed", async () => {
  const bucket = new MemoryBucket();
  const env = makeEnvironment(bucket);
  const context = new TestContext();

  const healthy = await fetchRelay(env, context, "/healthz");
  assert.equal(healthy.status, 200);
  const unhealthy = await fetchRelay({ ...env, MASTER_KEY: "short" }, context, "/healthz");
  assert.equal(unhealthy.status, 503);

  const unauthorized = await fetchRelay(env, context, "/v1/uploads", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ fileName: "x.mp3", contentType: "audio/mpeg", size: 1 }),
  });
  assert.equal(unauthorized.status, 401);

  const invalid = await fetchRelay(env, context, "/v1/uploads", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TEST_ADMIN_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ fileName: "..", contentType: "text/html", size: 1 }),
  });
  assert.equal(invalid.status, 400);

  assert.deepEqual(testing.requestedRange("bytes=3-8", 10), { start: 3, end: 8, partial: true });
  assert.deepEqual(testing.requestedRange("bytes=-4", 10), { start: 6, end: 9, partial: true });
  assert.equal(testing.requestedRange("bytes=20-30", 10), null);
  assert.deepEqual(testing.parseContentRange("bytes 5-9/10"), { start: 5, end: 9, total: 10 });
  assert.equal(testing.parseContentRange("bytes 5-10/10"), null);
  assert.equal(testing.sanitizeFileName("  ../bad:name  "), ".._bad_name");
  assert.equal(testing.sanitizeContentType("text/html"), "application/octet-stream");
});

async function createAndUpload({
  env,
  context,
  media,
  fileName,
  contentType,
  password = "",
  expiresAt = new Date(Date.now() + 60 * 60 * 1000),
  ...presentation
}) {
  const creation = await createOnly(env, context, {
    fileName,
    contentType,
    size: media.byteLength,
    expiresAt: expiresAt.toISOString(),
    password,
    ...presentation,
  });
  for (let index = 0, offset = 0; offset < media.byteLength; index += 1, offset += creation.chunkSize) {
    const end = Math.min(offset + creation.chunkSize, media.byteLength);
    const response = await fetchRelay(env, context, `/v1/uploads/${creation.shareID}/chunks/${index}`, {
      method: "PUT",
      headers: {
        Authorization: `Bearer ${creation.uploadToken}`,
        "Content-Type": "application/octet-stream",
        "Content-Range": `bytes ${offset}-${end - 1}/${media.byteLength}`,
      },
      body: media.slice(offset, end),
    });
    await assertResponseStatus(response, 204);
  }
  const completed = await fetchRelay(env, context, `/v1/uploads/${creation.shareID}/complete`, {
    method: "POST",
    headers: { Authorization: `Bearer ${creation.uploadToken}` },
  });
  await assertResponseStatus(completed, 200);
  return creation;
}

async function createOnly(env, context, input) {
  const response = await fetchRelay(env, context, "/v1/uploads", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${TEST_ADMIN_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(input),
  });
  await assertResponseStatus(response, 201);
  return response.json();
}

async function assertResponseStatus(response, expected) {
  if (response.status !== expected) {
    assert.fail(`status=${response.status}, expected=${expected}, body=${await response.text()}`);
  }
}

function fetchRelay(env, context, path, init = {}) {
  return worker.fetch(new Request(`https://share.soundisle.com${path}`, init), env, context);
}

function makeEnvironment(bucket, overrides = {}) {
  return {
    MEDIA_BUCKET: bucket,
    ASSETS: new MemoryAssets(),
    PUBLIC_RATE_LIMITER: { limit: async () => ({ success: true }) },
    PASSWORD_RATE_LIMITER: { limit: async () => ({ success: true }) },
    ADMIN_TOKEN: TEST_ADMIN_TOKEN,
    MASTER_KEY: Buffer.alloc(32, 0x42).toString("base64"),
    PUBLIC_BASE_URL: "https://share.soundisle.com",
    CHUNK_SIZE_BYTES: String(TEST_CHUNK_SIZE),
    MAX_FILE_BYTES: String(64 * 1024 * 1024),
    MAX_TTL_SECONDS: String(24 * 60 * 60),
    UPLOAD_TTL_SECONDS: String(60 * 60),
    ...overrides,
  };
}

class MemoryAssets {
  async fetch(request) {
    const name = new URL(request.url).pathname.slice(1);
    try {
      const data = await readFile(new URL(`../../web/${name}`, import.meta.url));
      const contentType = name.endsWith(".html")
        ? "text/html; charset=utf-8"
        : name.endsWith(".css")
          ? "text/css; charset=utf-8"
          : name.endsWith(".js")
            ? "text/javascript; charset=utf-8"
            : "application/octet-stream";
      return new Response(data, { status: 200, headers: { "Content-Type": contentType } });
    } catch {
      return new Response(null, { status: 404 });
    }
  }
}

function basicAuthorization(username, password) {
  return `Basic ${Buffer.from(`${username}:${password}`, "utf8").toString("base64")}`;
}

class TestContext {
  constructor() {
    this.pending = [];
  }

  waitUntil(promise) {
    this.pending.push(Promise.resolve(promise));
  }

  async flush() {
    while (this.pending.length > 0) {
      const current = this.pending.splice(0);
      await Promise.all(current);
    }
  }
}

class MemoryBucket {
  constructor() {
    this.objects = new Map();
    this.uploads = new Map();
    this.counter = 0;
  }

  async put(key, value, options = {}) {
    const previous = this.objects.get(key);
    if (options.onlyIf?.etagMatches && previous?.etag !== options.onlyIf.etagMatches) {
      return null;
    }
    const bytes = await valueBytes(value);
    const record = {
      bytes,
      etag: `object-${++this.counter}`,
      uploaded: new Date(),
      httpMetadata: { ...(options.httpMetadata ?? {}) },
      customMetadata: { ...(options.customMetadata ?? {}) },
    };
    this.objects.set(key, record);
    return this.objectView(key, record, false);
  }

  async get(key, options = {}) {
    const record = this.objects.get(key);
    if (!record) {
      return null;
    }
    let bytes = record.bytes;
    let range;
    if (options.range && !(options.range instanceof Headers)) {
      const offset = options.range.offset ?? 0;
      const length = options.range.length ?? bytes.byteLength - offset;
      bytes = bytes.slice(offset, offset + length);
      range = { offset, length: bytes.byteLength };
    }
    return this.objectView(key, record, true, bytes, range);
  }

  async head(key) {
    const record = this.objects.get(key);
    return record ? this.objectView(key, record, false) : null;
  }

  async delete(keys) {
    for (const key of Array.isArray(keys) ? keys : [keys]) {
      this.objects.delete(key);
    }
  }

  async list(options = {}) {
    const prefix = options.prefix ?? "";
    const limit = options.limit ?? 1000;
    const start = Number(options.cursor ?? 0);
    const all = [...this.objects.keys()].filter((key) => key.startsWith(prefix)).sort();
    const selected = all.slice(start, start + limit);
    const truncated = start + selected.length < all.length;
    return {
      objects: selected.map((key) => this.objectView(key, this.objects.get(key), false)),
      truncated,
      cursor: truncated ? String(start + selected.length) : undefined,
      delimitedPrefixes: [],
    };
  }

  async createMultipartUpload(key, options = {}) {
    const uploadId = `upload-${++this.counter}`;
    this.uploads.set(uploadId, { key, options, parts: new Map() });
    return this.multipartView(key, uploadId);
  }

  resumeMultipartUpload(key, uploadId) {
    return this.multipartView(key, uploadId);
  }

  multipartView(key, uploadId) {
    return {
      key,
      uploadId,
      uploadPart: async (partNumber, value) => {
        const upload = this.uploads.get(uploadId);
        if (!upload || upload.key !== key) {
          throw new Error("NoSuchUpload");
        }
        const bytes = await valueBytes(value);
        const etag = `part-${partNumber}-${++this.counter}`;
        upload.parts.set(partNumber, { bytes, etag });
        return { partNumber, etag };
      },
      complete: async (parts) => {
        const upload = this.uploads.get(uploadId);
        if (!upload || upload.key !== key) {
          throw new Error("NoSuchUpload");
        }
        const selected = [];
        for (const part of parts) {
          const stored = upload.parts.get(part.partNumber);
          if (!stored || stored.etag !== part.etag) {
            throw new Error("InvalidPart");
          }
          selected.push(stored.bytes);
        }
        for (let index = 0; index < selected.length - 1; index += 1) {
          if (selected[index].byteLength < 5 * 1024 * 1024) {
            throw new Error("EntityTooSmall");
          }
          if (index > 0 && selected[index].byteLength !== selected[0].byteLength) {
            throw new Error("InvalidPart");
          }
        }
        const bytes = concatenate(selected);
        const record = {
          bytes,
          etag: `multipart-${++this.counter}`,
          uploaded: new Date(),
          httpMetadata: { ...(upload.options.httpMetadata ?? {}) },
          customMetadata: { ...(upload.options.customMetadata ?? {}) },
        };
        this.objects.set(key, record);
        this.uploads.delete(uploadId);
        return this.objectView(key, record, false);
      },
      abort: async () => {
        const upload = this.uploads.get(uploadId);
        if (!upload || upload.key !== key) {
          throw new Error("NoSuchUpload");
        }
        this.uploads.delete(uploadId);
      },
    };
  }

  objectView(key, record, includeBody, selectedBytes = record.bytes, range) {
    const view = {
      key,
      version: "memory",
      size: record.bytes.byteLength,
      etag: record.etag,
      httpEtag: `"${record.etag}"`,
      uploaded: record.uploaded,
      httpMetadata: { ...record.httpMetadata },
      customMetadata: { ...record.customMetadata },
      range,
    };
    if (includeBody) {
      view.body = chunkedStream(selectedBytes);
      view.arrayBuffer = async () => selectedBytes.slice().buffer;
      view.text = async () => utf8Decoder.decode(selectedBytes);
      view.json = async () => JSON.parse(utf8Decoder.decode(selectedBytes));
      view.blob = async () => new Blob([selectedBytes]);
    }
    return view;
  }

  raw(key) {
    const bytes = this.objects.get(key)?.bytes;
    return bytes ? bytes.slice() : null;
  }

  keys(prefix = "") {
    return [...this.objects.keys()].filter((key) => key.startsWith(prefix)).sort();
  }

  textForPrefixes(prefixes) {
    return [...this.objects.entries()]
      .filter(([key]) => prefixes.some((prefix) => key.startsWith(prefix)))
      .map(([, record]) => utf8Decoder.decode(record.bytes))
      .join("\n");
  }

  hasMultipartUploadFor(key) {
    return [...this.uploads.values()].some((upload) => upload.key === key);
  }
}

async function valueBytes(value) {
  if (typeof value === "string") {
    return utf8.encode(value);
  }
  if (value instanceof Uint8Array) {
    return value.slice();
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value.slice(0));
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
  }
  if (value instanceof Blob) {
    return new Uint8Array(await value.arrayBuffer());
  }
  if (value instanceof ReadableStream) {
    return new Uint8Array(await new Response(value).arrayBuffer());
  }
  throw new TypeError("unsupported R2 value");
}

function concatenate(chunks) {
  const output = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.byteLength, 0));
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return output;
}

function chunkedStream(bytes) {
  let offset = 0;
  let turn = 0;
  const sizes = [65_521, 131_071, 32_749];
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.byteLength) {
        controller.close();
        return;
      }
      const end = Math.min(offset + sizes[turn % sizes.length], bytes.byteLength);
      controller.enqueue(bytes.slice(offset, end));
      offset = end;
      turn += 1;
    },
  });
}
