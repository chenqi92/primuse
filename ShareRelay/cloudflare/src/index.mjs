const DEFAULT_CHUNK_SIZE = 8 * 1024 * 1024;
const DEFAULT_MAXIMUM_FILE_SIZE = 20 * 1024 * 1024 * 1024;
const DEFAULT_MAXIMUM_TTL_SECONDS = 30 * 24 * 60 * 60;
const DEFAULT_UPLOAD_TTL_SECONDS = 24 * 60 * 60;
const MINIMUM_MULTIPART_CHUNK_SIZE = 5 * 1024 * 1024;
const MAXIMUM_CHUNK_SIZE = 32 * 1024 * 1024;
const MAXIMUM_MULTIPART_PARTS = 10_000;
const MAXIMUM_JSON_BYTES = 64 * 1024;
const MAXIMUM_FORM_BYTES = 2 * 1024;
const PASSWORD_ITERATIONS = 210_000;
const SHARE_SESSION_SECONDS = 30 * 60;
const IMPORT_TICKET_SECONDS = 10 * 60;
const AES_GCM_NONCE_BYTES = 12;
const AES_GCM_TAG_BYTES = 16;
const ENCRYPTED_CHUNK_OVERHEAD = AES_GCM_NONCE_BYTES + AES_GCM_TAG_BYTES;
const CLEANUP_BATCH_SIZE = 2;
const CLEANUP_SCAN_PAGE_LIMIT = 10;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
const cleanupShardAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

class RelayError extends Error {
  constructor(status, code, headers = {}) {
    super(code);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

export default {
  async fetch(request, env, context) {
    let response;
    try {
      response = await routeRequest(request, env, context);
    } catch (error) {
      response = error instanceof RelayError
        ? problemResponse(error.status, error.code, error.headers)
        : problemResponse(500, "internal_error");
    }
    return withSecurityHeaders(response);
  },

  async scheduled(event, env, context) {
    const interval = Math.floor(event.scheduledTime / (5 * 60 * 1000));
    const shard = cleanupShardAlphabet[interval % cleanupShardAlphabet.length];
    context.waitUntil(cleanupExpiredShares(env, new Date(event.scheduledTime), shard));
  },
};

async function routeRequest(request, env, context) {
  const url = new URL(request.url);
  if (url.pathname === "/healthz") {
    if (request.method !== "GET" && request.method !== "HEAD") {
      throw new RelayError(405, "method_not_allowed", { Allow: "GET, HEAD" });
    }
    try {
      loadConfiguration(env);
      return jsonResponse({ status: "ok" }, 200, request.method === "HEAD");
    } catch {
      return jsonResponse({ status: "misconfigured" }, 503, request.method === "HEAD");
    }
  }

  const configuration = loadConfiguration(env);
  if (url.pathname === "/v1/uploads") {
    requireMethod(request, "POST");
    return createUpload(request, env, configuration);
  }

  let match = url.pathname.match(/^\/v1\/uploads\/([A-Za-z0-9_-]{16,128})\/chunks\/(\d+)$/);
  if (match) {
    requireMethod(request, "PUT");
    return uploadChunk(request, env, context, configuration, match[1], match[2]);
  }

  match = url.pathname.match(/^\/v1\/uploads\/([A-Za-z0-9_-]{16,128})\/complete$/);
  if (match) {
    requireMethod(request, "POST");
    return completeUpload(request, env, context, configuration, match[1]);
  }

  match = url.pathname.match(/^\/v1\/shares\/([A-Za-z0-9_-]{16,128})$/);
  if (match) {
    requireMethod(request, "DELETE");
    return revokeShare(request, env, context, configuration, match[1]);
  }

  match = url.pathname.match(/^\/s\/([A-Za-z0-9_-]{16,128})$/);
  if (match) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      throw new RelayError(405, "method_not_allowed", { Allow: "GET, HEAD" });
    }
    if (prefersHTML(request)) {
      return serveSharePage(request, env, context, configuration, match[1]);
    }
    return servePublicShare(request, env, context, configuration, match[1], false);
  }

  match = url.pathname.match(/^\/s\/([A-Za-z0-9_-]{16,128})\/auth$/);
  if (match) {
    requireMethod(request, "POST");
    return authenticateShare(request, env, configuration, match[1]);
  }

  match = url.pathname.match(/^\/s\/([A-Za-z0-9_-]{16,128})\/(media|download)$/);
  if (match) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      throw new RelayError(405, "method_not_allowed", { Allow: "GET, HEAD" });
    }
    return servePublicShare(request, env, context, configuration, match[1], match[2] === "download");
  }

  match = url.pathname.match(/^\/s\/([A-Za-z0-9_-]{16,128})\/import$/);
  if (match) {
    requireMethod(request, "POST");
    return createImportTicket(request, env, configuration, match[1]);
  }

  match = url.pathname.match(/^\/i\/([A-Za-z0-9_-]{16,128})$/);
  if (match) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      throw new RelayError(405, "method_not_allowed", { Allow: "GET, HEAD" });
    }
    return consumeImportTicket(request, env, context, configuration, match[1]);
  }

  if (url.pathname === "/share.html" || url.pathname === "/password.html" || url.pathname === "/unavailable.html") {
    throw new RelayError(404, "not_found");
  }

  throw new RelayError(404, "not_found");
}

function loadConfiguration(env) {
  if (!env?.MEDIA_BUCKET || typeof env.MEDIA_BUCKET.get !== "function") {
    throw new Error("MEDIA_BUCKET is unavailable");
  }
  if (!env?.ASSETS || typeof env.ASSETS.fetch !== "function") {
    throw new Error("ASSETS is unavailable");
  }
  if (typeof env.ADMIN_TOKEN !== "string" || textEncoder.encode(env.ADMIN_TOKEN).byteLength < 32) {
    throw new Error("ADMIN_TOKEN is invalid");
  }
  const masterKey = decodeBase64(env.MASTER_KEY);
  if (masterKey.byteLength !== 32) {
    throw new Error("MASTER_KEY is invalid");
  }

  const publicBaseURL = new URL(env.PUBLIC_BASE_URL ?? "");
  if (
    publicBaseURL.protocol !== "https:" ||
    !publicBaseURL.hostname ||
    publicBaseURL.username ||
    publicBaseURL.password ||
    publicBaseURL.search ||
    publicBaseURL.hash ||
    (publicBaseURL.pathname !== "/" && publicBaseURL.pathname !== "")
  ) {
    throw new Error("PUBLIC_BASE_URL is invalid");
  }

  const chunkSize = positiveInteger(env.CHUNK_SIZE_BYTES, DEFAULT_CHUNK_SIZE);
  const maximumFileSize = positiveInteger(env.MAX_FILE_BYTES, DEFAULT_MAXIMUM_FILE_SIZE);
  const maximumTTLSeconds = positiveInteger(env.MAX_TTL_SECONDS, DEFAULT_MAXIMUM_TTL_SECONDS);
  const uploadTTLSeconds = positiveInteger(env.UPLOAD_TTL_SECONDS, DEFAULT_UPLOAD_TTL_SECONDS);
  if (chunkSize < MINIMUM_MULTIPART_CHUNK_SIZE || chunkSize > MAXIMUM_CHUNK_SIZE) {
    throw new Error("CHUNK_SIZE_BYTES is outside the R2 multipart limits");
  }

  return {
    bucket: env.MEDIA_BUCKET,
    publicBaseURL: publicBaseURL.origin,
    adminToken: env.ADMIN_TOKEN,
    masterKey,
    chunkSize,
    maximumFileSize,
    maximumTTLMilliseconds: maximumTTLSeconds * 1000,
    uploadTTLMilliseconds: uploadTTLSeconds * 1000,
  };
}

async function createUpload(request, env, configuration) {
  if (!(await tokenMatches(bearerToken(request), configuration.adminToken))) {
    throw new RelayError(401, "unauthorized");
  }
  const input = await decodeJSONRequest(request);
  const fileName = sanitizeFileName(input.fileName);
  const contentType = sanitizeContentType(input.contentType);
  if (
    !fileName ||
    !Number.isSafeInteger(input.size) ||
    input.size <= 0 ||
    input.size > configuration.maximumFileSize ||
    Math.ceil(input.size / configuration.chunkSize) > MAXIMUM_MULTIPART_PARTS
  ) {
    throw new RelayError(400, "invalid_media");
  }
  const password = input.password == null ? "" : input.password;
  if (typeof password !== "string" || textEncoder.encode(password).byteLength > 128) {
    throw new RelayError(400, "invalid_password");
  }
  const title = sanitizeDisplayText(input.title, 160);
  const artist = sanitizeDisplayText(input.artist, 160);
  const album = sanitizeDisplayText(input.album, 160);
  const audioFormat = sanitizeDisplayText(input.audioFormat, 32);
  const quality = sanitizeDisplayText(input.quality, 80);
  if ([title, artist, album, audioFormat, quality].some((value) => value.includes("\u0000"))) {
    throw new RelayError(400, "invalid_media");
  }
  const durationSeconds = input.durationSeconds == null ? 0 : input.durationSeconds;
  if (!Number.isFinite(durationSeconds) || durationSeconds < 0 || durationSeconds > 7 * 24 * 60 * 60) {
    throw new RelayError(400, "invalid_media");
  }
  for (const permission of [input.allowPlayback, input.allowDownload, input.allowImport]) {
    if (permission != null && typeof permission !== "boolean") {
      throw new RelayError(400, "invalid_permissions");
    }
  }

  const now = new Date();
  const expiresAt = input.expiresAt == null || input.expiresAt === ""
    ? new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000)
    : parseRFC3339(input.expiresAt);
  if (
    !expiresAt ||
    expiresAt.getTime() <= now.getTime() ||
    expiresAt.getTime() > now.getTime() + configuration.maximumTTLMilliseconds
  ) {
    throw new RelayError(400, "invalid_expiration");
  }

  const id = randomToken(18);
  const publicToken = randomToken(32);
  const uploadToken = randomToken(32);
  const dataKey = dataObjectKey(id);
  const multipartUpload = await configuration.bucket.createMultipartUpload(dataKey, {
    httpMetadata: { contentType: "application/octet-stream" },
    customMetadata: { shareID: id, format: "aes-256-gcm-chunks-v1" },
  });

  const metadata = {
    version: 2,
    id,
    publicTokenHash: await tokenHash(publicToken),
    controlHash: await tokenHash(uploadToken),
    fileName,
    contentType,
    size: input.size,
    chunkSize: configuration.chunkSize,
    createdAt: now.toISOString(),
    expiresAt: expiresAt.toISOString(),
    uploadExpiresAt: new Date(now.getTime() + configuration.uploadTTLMilliseconds).toISOString(),
    completedAt: null,
    revokedAt: null,
    dataDeletedAt: null,
    etag: `"${randomToken(18)}"`,
    passwordSalt: null,
    passwordHash: null,
    title,
    artist,
    album,
    audioFormat,
    quality,
    durationSeconds,
    allowPlayback: input.allowPlayback ?? true,
    allowDownload: input.allowDownload ?? true,
    allowImport: input.allowImport ?? true,
    dataKey,
    uploadId: multipartUpload.uploadId,
  };
  if (password) {
    const salt = crypto.getRandomValues(new Uint8Array(16));
    metadata.passwordSalt = bytesToBase64(salt, false);
    metadata.passwordHash = bytesToBase64(await passwordVerifier(password, salt), false);
  }

  try {
    await putMetadata(configuration.bucket, metadata);
    await putJSON(configuration.bucket, publicIndexKey(metadata.publicTokenHash), { shareID: id });
  } catch (error) {
    await Promise.allSettled([
      multipartUpload.abort(),
      configuration.bucket.delete(metadataObjectKey(id)),
      configuration.bucket.delete(publicIndexKey(metadata.publicTokenHash)),
    ]);
    throw error;
  }

  return jsonResponse({
    shareID: id,
    uploadToken,
    publicURL: `${configuration.publicBaseURL}/s/${publicToken}`,
    chunkSize: metadata.chunkSize,
    expiresAt: metadata.expiresAt,
  }, 201);
}

async function uploadChunk(request, env, context, configuration, shareID, rawIndex) {
  const loaded = await loadMetadataByID(configuration.bucket, shareID, configuration);
  if (!loaded || !(await controlTokenMatches(request, loaded.metadata))) {
    throw new RelayError(404, "not_found");
  }
  const now = Date.now();
  if (isUploadClosed(loaded.metadata, now)) {
    if (isRevoked(loaded.metadata) || Date.parse(loaded.metadata.uploadExpiresAt) <= now) {
      scheduleCleanup(context, env, loaded.metadata);
    }
    throw new RelayError(409, "upload_closed");
  }

  const index = Number(rawIndex);
  if (!Number.isSafeInteger(index) || index < 0) {
    throw new RelayError(400, "invalid_chunk");
  }
  const expectedStart = index * loaded.metadata.chunkSize;
  if (expectedStart >= loaded.metadata.size) {
    throw new RelayError(400, "invalid_chunk");
  }
  const expectedLength = Math.min(loaded.metadata.chunkSize, loaded.metadata.size - expectedStart);
  const contentRange = parseContentRange(request.headers.get("Content-Range"));
  if (
    !contentRange ||
    contentRange.start !== expectedStart ||
    contentRange.end - contentRange.start + 1 !== expectedLength ||
    contentRange.total !== loaded.metadata.size
  ) {
    throw new RelayError(400, "invalid_content_range");
  }
  const declaredLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declaredLength) && declaredLength > expectedLength) {
    throw new RelayError(400, "invalid_chunk_size");
  }
  const plaintext = new Uint8Array(await request.arrayBuffer());
  if (plaintext.byteLength !== expectedLength) {
    throw new RelayError(400, "invalid_chunk_size");
  }

  const key = await importMasterKey(configuration.masterKey);
  const encrypted = await encryptChunk(key, loaded.metadata.id, index, plaintext);
  const upload = configuration.bucket.resumeMultipartUpload(
    loaded.metadata.dataKey,
    loaded.metadata.uploadId,
  );
  let uploadedPart;
  try {
    uploadedPart = await upload.uploadPart(index + 1, encrypted);
  } catch {
    throw new RelayError(503, "storage_unavailable", { "Retry-After": "2" });
  }
  await configuration.bucket.put(partRecordKey(shareID, index + 1), "", {
    httpMetadata: { contentType: "application/json" },
    customMetadata: {
      partNumber: String(uploadedPart.partNumber),
      etag: uploadedPart.etag,
    },
  });
  return new Response(null, { status: 204 });
}

async function completeUpload(request, env, context, configuration, shareID) {
  let loaded = await loadMetadataByID(configuration.bucket, shareID, configuration);
  if (!loaded || !(await controlTokenMatches(request, loaded.metadata))) {
    throw new RelayError(404, "not_found");
  }
  if (isRevoked(loaded.metadata) || Date.parse(loaded.metadata.uploadExpiresAt) <= Date.now()) {
    scheduleCleanup(context, env, loaded.metadata);
    throw new RelayError(409, "upload_closed");
  }

  const expectedPartCount = Math.ceil(loaded.metadata.size / loaded.metadata.chunkSize);
  const expectedEncryptedSize = loaded.metadata.size + expectedPartCount * ENCRYPTED_CHUNK_OVERHEAD;
  let completedObject = await configuration.bucket.head(loaded.metadata.dataKey);
  if (!completedObject) {
    const parts = await listUploadedParts(configuration.bucket, shareID);
    if (parts.length !== expectedPartCount || parts.some((part, index) => part.partNumber !== index + 1)) {
      throw new RelayError(409, "missing_chunk");
    }
    const upload = configuration.bucket.resumeMultipartUpload(
      loaded.metadata.dataKey,
      loaded.metadata.uploadId,
    );
    try {
      completedObject = await upload.complete(parts);
    } catch {
      completedObject = await configuration.bucket.head(loaded.metadata.dataKey);
      if (!completedObject) {
        throw new RelayError(503, "storage_unavailable", { "Retry-After": "2" });
      }
    }
  }
  if (completedObject.size !== expectedEncryptedSize) {
    throw new RelayError(500, "storage_inconsistent");
  }

  loaded = await markUploadCompleted(configuration, request, shareID);
  if (!loaded) {
    await configuration.bucket.delete(dataObjectKey(shareID));
    throw new RelayError(409, "upload_closed");
  }
  context?.waitUntil?.(deletePartRecords(configuration.bucket, shareID));
  return jsonResponse({
    shareID: loaded.metadata.id,
    expiresAt: loaded.metadata.expiresAt,
  });
}

async function markUploadCompleted(configuration, request, shareID) {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const loaded = await loadMetadataByID(configuration.bucket, shareID, configuration);
    if (!loaded || !(await controlTokenMatches(request, loaded.metadata))) {
      return null;
    }
    if (isRevoked(loaded.metadata) || Date.parse(loaded.metadata.uploadExpiresAt) <= Date.now()) {
      return null;
    }
    if (isComplete(loaded.metadata)) {
      return loaded;
    }
    const updated = { ...loaded.metadata, completedAt: new Date().toISOString() };
    const stored = await putMetadata(configuration.bucket, updated, loaded.object.etag);
    if (stored) {
      return { metadata: updated, object: stored };
    }
  }
  throw new RelayError(503, "busy", { "Retry-After": "2" });
}

async function revokeShare(request, env, context, configuration, shareID) {
  let revoked;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const loaded = await loadMetadataByID(configuration.bucket, shareID, configuration);
    if (!loaded) {
      throw new RelayError(404, "not_found");
    }
    const authorized = await controlTokenMatches(request, loaded.metadata)
      || await tokenMatches(bearerToken(request), configuration.adminToken);
    if (!authorized) {
      throw new RelayError(404, "not_found");
    }
    if (isRevoked(loaded.metadata)) {
      revoked = loaded;
      break;
    }
    const updated = { ...loaded.metadata, revokedAt: new Date().toISOString() };
    const stored = await putMetadata(configuration.bucket, updated, loaded.object.etag);
    if (stored) {
      revoked = { metadata: updated, object: stored };
      break;
    }
  }
  if (!revoked) {
    throw new RelayError(503, "busy", { "Retry-After": "2" });
  }
  await cleanupShareData(configuration.bucket, revoked.metadata);
  await markDataDeleted(configuration, revoked.metadata.id);
  context?.waitUntil?.(deletePartRecords(configuration.bucket, shareID));
  return new Response(null, { status: 204 });
}

async function servePublicShare(request, env, context, configuration, publicToken, attachment) {
  if (env.PUBLIC_RATE_LIMITER?.limit) {
    const peer = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const result = await env.PUBLIC_RATE_LIMITER.limit({ key: `primuse-share-relay:${peer}` });
    if (!result.success) {
      throw new RelayError(429, "rate_limited", { "Retry-After": "60" });
    }
  }

  const loaded = await loadMetadataByPublicToken(configuration.bucket, publicToken, configuration);
  if (!loaded || !isComplete(loaded.metadata) || isRevoked(loaded.metadata)) {
    throw new RelayError(410, "unavailable");
  }
  if (Date.parse(loaded.metadata.expiresAt) <= Date.now() || loaded.metadata.dataDeletedAt) {
    scheduleCleanup(context, env, loaded.metadata);
    throw new RelayError(410, "unavailable");
  }
  if (
    loaded.metadata.passwordHash &&
    !(await verifyPassword(request, loaded.metadata)) &&
    !(await verifyShareSession(request, configuration, publicToken, loaded.metadata))
  ) {
    throw new RelayError(401, "password_required", {
      "WWW-Authenticate": 'Basic realm="Primuse Share", charset="UTF-8"',
    });
  }
  if (attachment && !metadataPermission(loaded.metadata.allowDownload, true)) {
    throw new RelayError(403, "download_disabled");
  }
  if (!attachment && !metadataPermission(loaded.metadata.allowPlayback, true)) {
    throw new RelayError(403, "playback_disabled");
  }
  return serveMetadataMedia(request, configuration, loaded.metadata, attachment);
}

async function serveMetadataMedia(request, configuration, metadata, attachment) {
  const headers = new Headers({
    "Accept-Ranges": "bytes",
    "Cache-Control": "private, no-store, max-age=0",
    "Content-Type": metadata.contentType,
    "Content-Disposition": contentDisposition(metadata.fileName, attachment),
    ETag: metadata.etag,
    "Last-Modified": new Date(metadata.completedAt).toUTCString(),
  });
  if (request.headers.get("If-None-Match") === metadata.etag && !request.headers.has("Range")) {
    return new Response(null, { status: 304, headers });
  }

  let requested = requestedRange(request.headers.get("Range"), metadata.size);
  if (request.headers.has("If-Range") && request.headers.get("If-Range") !== metadata.etag) {
    requested = { start: 0, end: metadata.size - 1, partial: false };
  }
  if (!requested) {
    throw new RelayError(416, "invalid_range", {
      "Content-Range": `bytes */${metadata.size}`,
    });
  }
  headers.set("Content-Length", String(requested.end - requested.start + 1));
  if (requested.partial) {
    headers.set("Content-Range", `bytes ${requested.start}-${requested.end}/${metadata.size}`);
  }

  const expectedPartCount = Math.ceil(metadata.size / metadata.chunkSize);
  const expectedEncryptedSize = metadata.size + expectedPartCount * ENCRYPTED_CHUNK_OVERHEAD;
  if (request.method === "HEAD") {
    const object = await configuration.bucket.head(metadata.dataKey);
    if (!object || object.size !== expectedEncryptedSize) {
      throw new RelayError(503, "storage_unavailable", { "Retry-After": "2" });
    }
    return new Response(null, { status: requested.partial ? 206 : 200, headers });
  }

  const firstChunk = Math.floor(requested.start / metadata.chunkSize);
  const lastChunk = Math.floor(requested.end / metadata.chunkSize);
  const encryptedStart = firstChunk * (metadata.chunkSize + ENCRYPTED_CHUNK_OVERHEAD);
  const lastPlaintextLength = Math.min(
    metadata.chunkSize,
    metadata.size - lastChunk * metadata.chunkSize,
  );
  const encryptedEnd = lastChunk * (metadata.chunkSize + ENCRYPTED_CHUNK_OVERHEAD)
    + lastPlaintextLength + ENCRYPTED_CHUNK_OVERHEAD;
  const object = await configuration.bucket.get(metadata.dataKey, {
    range: { offset: encryptedStart, length: encryptedEnd - encryptedStart },
  });
  if (!object?.body) {
    throw new RelayError(503, "storage_unavailable", { "Retry-After": "2" });
  }
  const key = await importMasterKey(configuration.masterKey);
  const body = decryptedRangeStream(
    object.body,
    key,
    metadata,
    requested.start,
    requested.end,
    firstChunk,
    lastChunk,
  );
  return new Response(body, { status: requested.partial ? 206 : 200, headers });
}

function prefersHTML(request) {
  if (request.method !== "GET" || request.headers.has("Range")) {
    return false;
  }
  return request.headers.get("Sec-Fetch-Mode") === "navigate"
    || (request.headers.get("Accept") ?? "").toLowerCase().includes("text/html");
}

async function serveSharePage(request, env, context, configuration, publicToken) {
  if (!(await publicRateLimitAllows(request, env))) {
    return templateResponse(request, env, "unavailable.html", 429);
  }
  const loaded = await loadMetadataByPublicToken(configuration.bucket, publicToken, configuration);
  if (!activeShare(loaded?.metadata)) {
    if (cleanupDue(loaded?.metadata)) {
      scheduleCleanup(context, env, loaded.metadata);
    }
    return templateResponse(request, env, "unavailable.html", 410);
  }
  if (
    loaded.metadata.passwordHash &&
    !(await verifyPassword(request, loaded.metadata)) &&
    !(await verifyShareSession(request, configuration, publicToken, loaded.metadata))
  ) {
    return passwordPage(request, env, configuration, publicToken, 200);
  }
  return unlockedSharePage(request, env, configuration, publicToken, loaded.metadata);
}

function cleanupDue(metadata, now = Date.now()) {
  if (!metadata || metadata.dataDeletedAt || isRevoked(metadata)) {
    return Boolean(metadata && !metadata.dataDeletedAt && isRevoked(metadata));
  }
  const cleanupAt = Date.parse(isComplete(metadata) ? metadata.expiresAt : metadata.uploadExpiresAt);
  return Number.isFinite(cleanupAt) && cleanupAt <= now;
}

async function publicRateLimitAllows(request, env) {
  if (!env.PUBLIC_RATE_LIMITER?.limit) {
    return true;
  }
  const peer = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const result = await env.PUBLIC_RATE_LIMITER.limit({ key: `primuse-share-relay:${peer}` });
  return result.success;
}

function activeShare(metadata) {
  return Boolean(
    metadata &&
    isComplete(metadata) &&
    !isRevoked(metadata) &&
    Date.parse(metadata.expiresAt) > Date.now() &&
    !metadata.dataDeletedAt,
  );
}

async function unlockedSharePage(request, env, configuration, publicToken, metadata) {
  const title = metadata.title || metadata.fileName.replace(/\.[^.]+$/, "") || "未命名音乐";
  let artistAlbum = metadata.artist || "";
  if (metadata.album) {
    artistAlbum += `${artistAlbum ? " · " : ""}《${metadata.album}》`;
  }
  artistAlbum ||= "来自 Primuse 的音乐分享";
  const audioFormat = (metadata.audioFormat || metadata.fileName.split(".").at(-1) || "").toUpperCase();
  const size = humanFileSize(metadata.size);
  const technical = [audioFormat, metadata.quality, size].filter(Boolean).join(" · ");
  const playback = metadataPermission(metadata.allowPlayback, true);
  const download = metadataPermission(metadata.allowDownload, true);
  const allowImport = metadataPermission(metadata.allowImport, true);
  const permissionNote = [];
  if (!download) permissionNote.push("分享者未开放下载");
  if (allowImport) permissionNote.push("导入使用一次性短期凭证，不含密码");
  const base = `${configuration.publicBaseURL}/s/${publicToken}`;
  return templateResponse(request, env, "share.html", 200, {
    TITLE: title,
    SOCIAL_DESCRIPTION: `${artistAlbum} · ${technical}`,
    COVER_URL: `${configuration.publicBaseURL}/fallback-cover.webp?v=20260903.3`,
    COVER_PATH: "/fallback-cover.webp?v=20260903.3",
    CANONICAL_URL: base,
    MEDIA_PATH: `/s/${publicToken}/media`,
    DOWNLOAD_PATH: `/s/${publicToken}/download`,
    IMPORT_PATH: `/s/${publicToken}/import`,
    FILE_NAME: metadata.fileName,
    FILE_SIZE_BYTES: String(metadata.size),
    SIZE: size,
    ACCESS_LABEL: metadata.passwordHash ? "已通过密码验证" : "持有链接即可访问",
    EXPIRES_ISO: metadata.expiresAt,
    EXPIRES_LABEL: `有效至 ${new Date(metadata.expiresAt).toISOString().slice(0, 16).replace("T", " ")} UTC`,
    SESSION_HIDDEN: metadata.passwordHash ? "" : "hidden",
    ARTIST_ALBUM: artistAlbum,
    FORMAT: audioFormat,
    QUALITY: metadata.quality || "",
    FORMAT_HIDDEN: hiddenUnless(Boolean(audioFormat)),
    QUALITY_HIDDEN: hiddenUnless(Boolean(metadata.quality)),
    PLAYBACK_HIDDEN: hiddenUnless(playback),
    IMPORT_HIDDEN: hiddenUnless(allowImport),
    DOWNLOAD_HIDDEN: hiddenUnless(download),
    PLAYBACK_PERMISSION_CLASS: deniedUnless(playback),
    DOWNLOAD_PERMISSION_CLASS: deniedUnless(download),
    IMPORT_PERMISSION_CLASS: deniedUnless(allowImport),
    PERMISSION_NOTE: permissionNote.join(" · "),
  });
}

function hiddenUnless(value) {
  return value ? "" : "hidden";
}

function deniedUnless(value) {
  return value ? "allowed" : "denied";
}

function humanFileSize(bytes) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return unit === 0 ? `${bytes} B` : `${value.toFixed(1)} ${units[unit]}`;
}

async function passwordPage(request, env, configuration, publicToken, status, options = {}) {
  return templateResponse(request, env, "password.html", status, {
    AUTH_PATH: `/s/${publicToken}/auth`,
    RETRY_AFTER: options.retryAfter ? String(options.retryAfter) : "",
    ERROR_CLASS: options.error ? "error" : "",
    MESSAGE_CLASS: options.error ? "error" : "",
    MESSAGE: options.message ?? "",
  }, options.retryAfter ? { "Retry-After": String(options.retryAfter) } : {});
}

async function templateResponse(request, env, name, status, values = {}, extraHeaders = {}) {
  const assetURL = new URL(`/${name}`, request.url);
  const source = await env.ASSETS.fetch(new Request(assetURL));
  if (!source.ok) {
    throw new RelayError(500, "template_unavailable");
  }
  let page = await source.text();
  for (const [key, value] of Object.entries(values)) {
    page = page.replaceAll(`{{${key}}}`, escapeHTML(String(value)));
  }
  if (page.includes("{{")) {
    throw new RelayError(500, "template_invalid");
  }
  return new Response(page, {
    status,
    headers: {
      "Cache-Control": "private, no-store, max-age=0",
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self' data:; media-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "Cross-Origin-Opener-Policy": "same-origin",
      ...extraHeaders,
    },
  });
}

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
}

async function authenticateShare(request, env, configuration, publicToken) {
  const loaded = await loadMetadataByPublicToken(configuration.bucket, publicToken, configuration);
  if (!activeShare(loaded?.metadata)) {
    return authenticationFailure(request, env, configuration, publicToken, 410, "unavailable");
  }
  if (!sameOriginRequest(request, configuration.publicBaseURL)) {
    return authenticationFailure(request, env, configuration, publicToken, 403, "invalid_origin");
  }
  const password = await passwordFromForm(request);
  if (loaded.metadata.passwordHash && env.PASSWORD_RATE_LIMITER?.limit) {
    const peer = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const key = await tokenHash(`${loaded.metadata.publicTokenHash}:${peer}`);
    const result = await env.PASSWORD_RATE_LIMITER.limit({ key: `primuse-password:${key}` });
    if (!result.success) {
      return authenticationFailure(request, env, configuration, publicToken, 429, "rate_limited", 60);
    }
  }
  if (loaded.metadata.passwordHash && !(await verifyPasswordValue(password, loaded.metadata))) {
    return authenticationFailure(request, env, configuration, publicToken, 401, "password_required");
  }
  const headers = new Headers({ "Cache-Control": "no-store" });
  if (loaded.metadata.passwordHash) {
    headers.set("Set-Cookie", await shareSessionCookie(configuration, publicToken, loaded.metadata));
  }
  if ((request.headers.get("Accept") ?? "").toLowerCase().includes("application/json")) {
    headers.set("Content-Type", "application/json; charset=utf-8");
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers });
  }
  headers.set("Location", `${configuration.publicBaseURL}/s/${publicToken}`);
  return new Response(null, { status: 303, headers });
}

async function authenticationFailure(
  request,
  env,
  configuration,
  publicToken,
  status,
  code,
  retryAfter = 0,
) {
  if ((request.headers.get("Accept") ?? "").toLowerCase().includes("application/json")) {
    return problemResponse(status, code, retryAfter ? { "Retry-After": String(retryAfter) } : {});
  }
  if (status === 410) {
    return templateResponse(request, env, "unavailable.html", 410);
  }
  const message = status === 429
    ? "尝试次数过多，请稍后重试。"
    : "密码不正确，请检查后重试。";
  return passwordPage(request, env, configuration, publicToken, status, {
    error: true,
    message,
    retryAfter,
  });
}

async function passwordFromForm(request) {
  const declaredLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAXIMUM_FORM_BYTES) {
    throw new RelayError(400, "invalid_password");
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAXIMUM_FORM_BYTES) {
    throw new RelayError(400, "invalid_password");
  }
  const password = new URLSearchParams(textDecoder.decode(bytes)).get("password") ?? "";
  if (textEncoder.encode(password).byteLength > 128) {
    throw new RelayError(400, "invalid_password");
  }
  return password;
}

function sameOriginRequest(request, publicBaseURL) {
  const origin = request.headers.get("Origin");
  return !origin || origin === publicBaseURL;
}

function shareCookieName(metadata) {
  return `primuse_share_${metadata.publicTokenHash.slice(0, 16)}`;
}

async function sessionSignature(configuration, publicToken, metadata, expiresUnix) {
  const key = await crypto.subtle.importKey(
    "raw",
    configuration.masterKey,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const payload = `${metadata.id}\n${await tokenHash(publicToken)}\n${metadata.passwordHash}\n${expiresUnix}`;
  return bytesToBase64(new Uint8Array(await crypto.subtle.sign("HMAC", key, textEncoder.encode(payload))), true);
}

async function shareSessionCookie(configuration, publicToken, metadata) {
  const expiresAt = Math.min(
    Date.now() + SHARE_SESSION_SECONDS * 1000,
    Date.parse(metadata.expiresAt),
  );
  const expiresUnix = Math.floor(expiresAt / 1000);
  const signature = await sessionSignature(configuration, publicToken, metadata, expiresUnix);
  return `${shareCookieName(metadata)}=${expiresUnix}.${signature}; Path=/s/${publicToken}; Max-Age=${Math.max(1, expiresUnix - Math.floor(Date.now() / 1000))}; Expires=${new Date(expiresUnix * 1000).toUTCString()}; Secure; HttpOnly; SameSite=Strict`;
}

async function verifyShareSession(request, configuration, publicToken, metadata) {
  const cookies = request.headers.get("Cookie") ?? "";
  const expectedName = `${shareCookieName(metadata)}=`;
  const raw = cookies.split(";").map((value) => value.trim()).find((value) => value.startsWith(expectedName));
  if (!raw) return false;
  const parts = raw.slice(expectedName.length).split(".");
  if (parts.length !== 2) return false;
  const expiresUnix = Number(parts[0]);
  const now = Date.now();
  if (
    !Number.isSafeInteger(expiresUnix) ||
    expiresUnix * 1000 <= now ||
    expiresUnix * 1000 > now + (SHARE_SESSION_SECONDS + 60) * 1000 ||
    expiresUnix * 1000 > Date.parse(metadata.expiresAt)
  ) {
    return false;
  }
  return constantTimeStringEqual(
    parts[1],
    await sessionSignature(configuration, publicToken, metadata, expiresUnix),
  );
}

async function createImportTicket(request, env, configuration, publicToken) {
  if (!sameOriginRequest(request, configuration.publicBaseURL)) {
    throw new RelayError(403, "invalid_origin");
  }
  const loaded = await loadMetadataByPublicToken(configuration.bucket, publicToken, configuration);
  if (!activeShare(loaded?.metadata)) {
    throw new RelayError(410, "unavailable");
  }
  if (!metadataPermission(loaded.metadata.allowImport, true)) {
    throw new RelayError(403, "import_disabled");
  }
  if (
    loaded.metadata.passwordHash &&
    !(await verifyShareSession(request, configuration, publicToken, loaded.metadata))
  ) {
    throw new RelayError(401, "password_required");
  }
  const token = randomToken(32);
  const expiresAt = new Date(Math.min(
    Date.now() + IMPORT_TICKET_SECONDS * 1000,
    Date.parse(loaded.metadata.expiresAt),
  ));
  const ticket = {
    version: 1,
    shareID: loaded.metadata.id,
    expiresAt: expiresAt.toISOString(),
    usedAt: null,
  };
  await putImportTicket(configuration.bucket, await tokenHash(token), ticket);
  return jsonResponse({
    importURL: `${configuration.publicBaseURL}/i/${token}`,
    expiresAt: ticket.expiresAt,
  }, 201);
}

async function consumeImportTicket(request, env, context, configuration, token) {
  if (!(await publicRateLimitAllows(request, env))) {
    throw new RelayError(429, "rate_limited", { "Retry-After": "60" });
  }
  const key = importTicketObjectKey(await tokenHash(token));
  const loadedTicket = await getJSON(configuration.bucket, key);
  if (!validImportTicket(loadedTicket?.value) || loadedTicket.value.usedAt || Date.parse(loadedTicket.value.expiresAt) <= Date.now()) {
    throw new RelayError(410, "unavailable");
  }
  const loaded = await loadMetadataByID(configuration.bucket, loadedTicket.value.shareID, configuration);
  if (!activeShare(loaded?.metadata) || !metadataPermission(loaded.metadata.allowImport, true)) {
    throw new RelayError(410, "unavailable");
  }
  if (request.method === "GET") {
    const usedTicket = { ...loadedTicket.value, usedAt: new Date().toISOString() };
    const stored = await putImportTicket(
      configuration.bucket,
      await tokenHash(token),
      usedTicket,
      loadedTicket.object.etag,
    );
    if (!stored) {
      throw new RelayError(410, "unavailable");
    }
    context?.waitUntil?.(cleanupExpiredImportTickets(configuration.bucket, new Date()));
  }
  return serveMetadataMedia(request, configuration, loaded.metadata, true);
}

function validImportTicket(ticket) {
  return Boolean(
    ticket &&
    ticket.version === 1 &&
    TOKEN_PATTERN.test(ticket.shareID) &&
    Number.isFinite(Date.parse(ticket.expiresAt)) &&
    (ticket.usedAt == null || Number.isFinite(Date.parse(ticket.usedAt))),
  );
}

function metadataPermission(value, fallback) {
  return typeof value === "boolean" ? value : fallback;
}

async function putImportTicket(bucket, hash, ticket, etag) {
  const options = {
    httpMetadata: { contentType: "application/json" },
    customMetadata: {
      expiresAt: String(Date.parse(ticket.expiresAt)),
      used: ticket.usedAt ? "true" : "false",
    },
  };
  if (etag) options.onlyIf = { etagMatches: etag };
  return bucket.put(importTicketObjectKey(hash), JSON.stringify(ticket), options);
}

function importTicketObjectKey(hash) {
  return `import-tickets/${hash}.json`;
}

async function cleanupExpiredImportTickets(bucket, now) {
  const result = await bucket.list({ prefix: "import-tickets/", limit: 1000, include: ["customMetadata"] });
  const keys = result.objects
    .filter((object) => object.customMetadata?.used === "true"
      || Number(object.customMetadata?.expiresAt) <= now.getTime())
    .slice(0, 100)
    .map((object) => object.key);
  if (keys.length > 0) await bucket.delete(keys);
}

function decryptedRangeStream(source, key, metadata, start, end, firstChunk, lastChunk) {
  const reader = source.getReader();
  const bytes = new ExactByteReader(reader);
  let index = firstChunk;
  let finished = false;

  return new ReadableStream({
    async pull(controller) {
      if (finished) {
        return;
      }
      try {
        if (index > lastChunk) {
          finished = true;
          controller.close();
          reader.releaseLock();
          return;
        }
        const plaintextLength = Math.min(metadata.chunkSize, metadata.size - index * metadata.chunkSize);
        const encrypted = await bytes.readExactly(plaintextLength + ENCRYPTED_CHUNK_OVERHEAD);
        if (!encrypted) {
          throw new Error("encrypted object ended early");
        }
        const plaintext = await decryptChunk(key, metadata.id, index, encrypted);
        const chunkStart = index * metadata.chunkSize;
        const lower = Math.max(start - chunkStart, 0);
        const upper = Math.min(end - chunkStart + 1, plaintext.byteLength);
        if (lower < upper) {
          controller.enqueue(plaintext.subarray(lower, upper));
        }
        index += 1;
        if (index > lastChunk) {
          finished = true;
          controller.close();
          reader.releaseLock();
        }
      } catch (error) {
        finished = true;
        controller.error(error);
        await reader.cancel(error).catch(() => {});
      }
    },
    async cancel(reason) {
      finished = true;
      await reader.cancel(reason).catch(() => {});
    },
  });
}

class ExactByteReader {
  constructor(reader) {
    this.reader = reader;
    this.current = new Uint8Array(0);
    this.offset = 0;
  }

  async readExactly(length) {
    const output = new Uint8Array(length);
    let written = 0;
    while (written < length) {
      if (this.offset >= this.current.byteLength) {
        const next = await this.reader.read();
        if (next.done) {
          return null;
        }
        this.current = next.value instanceof Uint8Array ? next.value : new Uint8Array(next.value);
        this.offset = 0;
      }
      const available = this.current.byteLength - this.offset;
      const count = Math.min(available, length - written);
      output.set(this.current.subarray(this.offset, this.offset + count), written);
      this.offset += count;
      written += count;
    }
    return output;
  }
}

async function encryptChunk(key, shareID, index, plaintext) {
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({
    name: "AES-GCM",
    iv: nonce,
    additionalData: textEncoder.encode(`${shareID}:${index}`),
    tagLength: AES_GCM_TAG_BYTES * 8,
  }, key, plaintext));
  const output = new Uint8Array(nonce.byteLength + ciphertext.byteLength);
  output.set(nonce);
  output.set(ciphertext, nonce.byteLength);
  return output;
}

async function decryptChunk(key, shareID, index, encrypted) {
  if (encrypted.byteLength < ENCRYPTED_CHUNK_OVERHEAD) {
    throw new Error("encrypted chunk is truncated");
  }
  const plaintext = await crypto.subtle.decrypt({
    name: "AES-GCM",
    iv: encrypted.subarray(0, AES_GCM_NONCE_BYTES),
    additionalData: textEncoder.encode(`${shareID}:${index}`),
    tagLength: AES_GCM_TAG_BYTES * 8,
  }, key, encrypted.subarray(AES_GCM_NONCE_BYTES));
  return new Uint8Array(plaintext);
}

async function importMasterKey(rawKey) {
  return crypto.subtle.importKey("raw", rawKey, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

async function passwordVerifier(password, salt) {
  const passwordKey = await crypto.subtle.importKey(
    "raw",
    textEncoder.encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  return new Uint8Array(await crypto.subtle.deriveBits({
    name: "PBKDF2",
    hash: "SHA-256",
    salt,
    iterations: PASSWORD_ITERATIONS,
  }, passwordKey, 256));
}

async function verifyPassword(request, metadata) {
  const password = basicAuthPassword(request.headers.get("Authorization"));
  if (password == null) {
    return false;
  }
  return verifyPasswordValue(password, metadata);
}

async function verifyPasswordValue(password, metadata) {
  const salt = decodeBase64(metadata.passwordSalt);
  const expected = decodeBase64(metadata.passwordHash);
  if (salt.byteLength !== 16 || expected.byteLength !== 32) {
    return false;
  }
  const actual = await passwordVerifier(password, salt);
  return constantTimeBytesEqual(actual, expected);
}

function basicAuthPassword(header) {
  if (typeof header !== "string" || !header.startsWith("Basic ")) {
    return null;
  }
  try {
    const decoded = textDecoder.decode(decodeBase64(header.slice(6).trim()));
    const separator = decoded.indexOf(":");
    return separator >= 0 ? decoded.slice(separator + 1) : null;
  } catch {
    return null;
  }
}

async function loadMetadataByPublicToken(bucket, publicToken, configuration) {
  if (!TOKEN_PATTERN.test(publicToken)) {
    return null;
  }
  const publicTokenHash = await tokenHash(publicToken);
  const index = await getJSON(bucket, publicIndexKey(publicTokenHash));
  if (!index || !TOKEN_PATTERN.test(index.value?.shareID ?? "")) {
    return null;
  }
  const loaded = await loadMetadataByID(bucket, index.value.shareID, configuration);
  if (!loaded || !constantTimeStringEqual(loaded.metadata.publicTokenHash, publicTokenHash)) {
    return null;
  }
  return loaded;
}

async function loadMetadataByID(bucket, shareID, configuration) {
  if (!TOKEN_PATTERN.test(shareID)) {
    return null;
  }
  const loaded = await getJSON(bucket, metadataObjectKey(shareID));
  if (!loaded || !validMetadata(loaded.value, shareID, configuration)) {
    return null;
  }
  return { metadata: loaded.value, object: loaded.object };
}

function validMetadata(metadata, shareID, configuration) {
  if (
    !metadata ||
    (metadata.version !== 1 && metadata.version !== 2) ||
    metadata.id !== shareID ||
    !TOKEN_PATTERN.test(metadata.id) ||
    !SHA256_PATTERN.test(metadata.publicTokenHash) ||
    !SHA256_PATTERN.test(metadata.controlHash) ||
    constantTimeStringEqual(metadata.publicTokenHash, metadata.controlHash) ||
    !metadata.fileName ||
    sanitizeFileName(metadata.fileName) !== metadata.fileName ||
    sanitizeContentType(metadata.contentType) !== metadata.contentType ||
    !Number.isSafeInteger(metadata.size) ||
    metadata.size <= 0 ||
    metadata.size > configuration.maximumFileSize ||
    !Number.isSafeInteger(metadata.chunkSize) ||
    metadata.chunkSize < MINIMUM_MULTIPART_CHUNK_SIZE ||
    metadata.chunkSize > MAXIMUM_CHUNK_SIZE ||
    metadata.dataKey !== dataObjectKey(shareID) ||
    typeof metadata.uploadId !== "string" ||
    metadata.uploadId.length < 1 ||
    metadata.uploadId.length > 1024 ||
    typeof metadata.etag !== "string" ||
    !/^"[A-Za-z0-9_-]{16,128}"$/.test(metadata.etag)
  ) {
    return false;
  }
  if (metadata.version === 2) {
    if (
      sanitizeDisplayText(metadata.title, 160) !== metadata.title ||
      sanitizeDisplayText(metadata.artist, 160) !== metadata.artist ||
      sanitizeDisplayText(metadata.album, 160) !== metadata.album ||
      sanitizeDisplayText(metadata.audioFormat, 32) !== metadata.audioFormat ||
      sanitizeDisplayText(metadata.quality, 80) !== metadata.quality ||
      !Number.isFinite(metadata.durationSeconds) ||
      metadata.durationSeconds < 0 ||
      metadata.durationSeconds > 7 * 24 * 60 * 60 ||
      typeof metadata.allowPlayback !== "boolean" ||
      typeof metadata.allowDownload !== "boolean" ||
      typeof metadata.allowImport !== "boolean"
    ) {
      return false;
    }
  }
  const createdAt = Date.parse(metadata.createdAt);
  const expiresAt = Date.parse(metadata.expiresAt);
  const uploadExpiresAt = Date.parse(metadata.uploadExpiresAt);
  if (!Number.isFinite(createdAt) || expiresAt <= createdAt || uploadExpiresAt <= createdAt) {
    return false;
  }
  for (const optionalDate of [metadata.completedAt, metadata.revokedAt, metadata.dataDeletedAt]) {
    if (optionalDate != null && !Number.isFinite(Date.parse(optionalDate))) {
      return false;
    }
  }
  const hasSalt = typeof metadata.passwordSalt === "string" && metadata.passwordSalt.length > 0;
  const hasHash = typeof metadata.passwordHash === "string" && metadata.passwordHash.length > 0;
  if (hasSalt !== hasHash) {
    return false;
  }
  if (hasSalt) {
    try {
      if (decodeBase64(metadata.passwordSalt).byteLength !== 16 || decodeBase64(metadata.passwordHash).byteLength !== 32) {
        return false;
      }
    } catch {
      return false;
    }
  }
  return true;
}

async function putMetadata(bucket, metadata, etag) {
  const options = {
    httpMetadata: { contentType: "application/json" },
    customMetadata: {
      state: isRevoked(metadata) ? "revoked" : isComplete(metadata) ? "complete" : "pending",
      nextCleanupAt: String(isRevoked(metadata)
        ? Date.parse(metadata.revokedAt)
        : Date.parse(isComplete(metadata) ? metadata.expiresAt : metadata.uploadExpiresAt)),
      dataDeleted: metadata.dataDeletedAt ? "true" : "false",
      publicTokenHash: metadata.publicTokenHash,
    },
  };
  if (etag) {
    options.onlyIf = { etagMatches: etag };
  }
  return bucket.put(metadataObjectKey(metadata.id), JSON.stringify(metadata), options);
}

async function putJSON(bucket, key, value) {
  return bucket.put(key, JSON.stringify(value), {
    httpMetadata: { contentType: "application/json" },
  });
}

async function getJSON(bucket, key) {
  const object = await bucket.get(key);
  if (!object) {
    return null;
  }
  try {
    return { value: await object.json(), object };
  } catch {
    return null;
  }
}

async function listUploadedParts(bucket, shareID) {
  const prefix = partRecordPrefix(shareID);
  const parts = [];
  let cursor;
  do {
    const result = await bucket.list({ prefix, cursor, limit: 1000, include: ["customMetadata"] });
    for (const object of result.objects) {
      const partNumber = Number(object.customMetadata?.partNumber);
      const etag = object.customMetadata?.etag;
      if (
        !Number.isSafeInteger(partNumber) ||
        partNumber < 1 ||
        partNumber > MAXIMUM_MULTIPART_PARTS ||
        typeof etag !== "string" ||
        etag.length < 1 ||
        etag.length > 256 ||
        object.key !== partRecordKey(shareID, partNumber)
      ) {
        throw new RelayError(500, "storage_inconsistent");
      }
      parts.push({ partNumber, etag });
    }
    cursor = result.truncated ? result.cursor : undefined;
  } while (cursor);
  parts.sort((left, right) => left.partNumber - right.partNumber);
  return parts;
}

async function deletePartRecords(bucket, shareID) {
  const prefix = partRecordPrefix(shareID);
  for (let page = 0; page < 11; page += 1) {
    const result = await bucket.list({ prefix, limit: 1000 });
    const keys = result.objects.map((object) => object.key);
    if (keys.length === 0) {
      return;
    }
    await bucket.delete(keys);
  }
}

async function cleanupShareData(bucket, metadata) {
  if (!isComplete(metadata) && metadata.uploadId) {
    await bucket.resumeMultipartUpload(metadata.dataKey, metadata.uploadId).abort().catch(() => {});
  }
  await bucket.delete(metadata.dataKey).catch(() => {});
  await deletePartRecords(bucket, metadata.id).catch(() => {});
}

async function markDataDeleted(configuration, shareID) {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const loaded = await loadMetadataByID(configuration.bucket, shareID, configuration);
    if (!loaded || loaded.metadata.dataDeletedAt) {
      return;
    }
    const updated = { ...loaded.metadata, dataDeletedAt: new Date().toISOString() };
    const stored = await putMetadata(configuration.bucket, updated, loaded.object.etag);
    if (stored) {
      return;
    }
  }
}

function scheduleCleanup(context, env, metadata) {
  if (!context?.waitUntil) {
    return;
  }
  context.waitUntil((async () => {
    const configuration = loadConfiguration(env);
    await cleanupShareData(configuration.bucket, metadata);
    await markDataDeleted(configuration, metadata.id);
  })());
}

export async function cleanupExpiredShares(env, now = new Date(), shard = null) {
  const configuration = loadConfiguration(env);
  const prefix = `metadata/${shard ?? ""}`;
  const candidates = [];
  let cursor;
  for (let page = 0; page < CLEANUP_SCAN_PAGE_LIMIT && candidates.length < CLEANUP_BATCH_SIZE; page += 1) {
    const result = await configuration.bucket.list({
      prefix,
      cursor,
      limit: 1000,
      include: ["customMetadata"],
    });
    for (const object of result.objects) {
      const nextCleanupAt = Number(object.customMetadata?.nextCleanupAt);
      if (
        object.customMetadata?.dataDeleted !== "true" &&
        Number.isFinite(nextCleanupAt) &&
        nextCleanupAt <= now.getTime()
      ) {
        candidates.push(object.key.slice("metadata/".length, -".json".length));
        if (candidates.length >= CLEANUP_BATCH_SIZE) {
          break;
        }
      }
    }
    cursor = result.truncated ? result.cursor : undefined;
    if (!cursor) {
      break;
    }
  }

  for (const shareID of candidates) {
    const loaded = await loadMetadataByID(configuration.bucket, shareID, configuration);
    if (!loaded || loaded.metadata.dataDeletedAt) {
      continue;
    }
    const cleanupAt = isRevoked(loaded.metadata)
      ? Date.parse(loaded.metadata.revokedAt)
      : Date.parse(isComplete(loaded.metadata) ? loaded.metadata.expiresAt : loaded.metadata.uploadExpiresAt);
    if (cleanupAt > now.getTime()) {
      continue;
    }
    await cleanupShareData(configuration.bucket, loaded.metadata);
    await markDataDeleted(configuration, shareID);
  }
  await cleanupExpiredImportTickets(configuration.bucket, now);
}

function requestedRange(header, total) {
  if (!Number.isSafeInteger(total) || total <= 0) {
    return null;
  }
  if (!header) {
    return { start: 0, end: total - 1, partial: false };
  }
  if (!header.startsWith("bytes=") || header.includes(",")) {
    return null;
  }
  const match = header.slice(6).match(/^(\d*)-(\d*)$/);
  if (!match) {
    return null;
  }
  if (match[1] === "") {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) {
      return null;
    }
    const length = Math.min(suffix, total);
    return { start: total - length, end: total - 1, partial: true };
  }
  const start = Number(match[1]);
  if (!Number.isSafeInteger(start) || start < 0 || start >= total) {
    return null;
  }
  let end = total - 1;
  if (match[2] !== "") {
    end = Number(match[2]);
    if (!Number.isSafeInteger(end) || end < start) {
      return null;
    }
    end = Math.min(end, total - 1);
  }
  return { start, end, partial: true };
}

function parseContentRange(value) {
  const match = typeof value === "string" ? value.match(/^bytes (\d+)-(\d+)\/(\d+)$/) : null;
  if (!match) {
    return null;
  }
  const start = Number(match[1]);
  const end = Number(match[2]);
  const total = Number(match[3]);
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    !Number.isSafeInteger(total) ||
    start < 0 || end < start || total <= end
  ) {
    return null;
  }
  return { start, end, total };
}

function sanitizeFileName(value) {
  if (typeof value !== "string") {
    return "";
  }
  const sanitized = [...value.trim().replace(/[\p{Cc}/\\:]/gu, "_")].slice(0, 180).join("");
  return sanitized === "." || sanitized === ".." ? "" : sanitized;
}

function sanitizeContentType(value) {
  if (typeof value !== "string") {
    return "application/octet-stream";
  }
  const mediaType = value.split(";", 1)[0].trim().toLowerCase();
  if (/^(audio|video)\/[a-z0-9!#$&^_.+-]+$/.test(mediaType) || mediaType === "application/octet-stream") {
    return mediaType;
  }
  return "application/octet-stream";
}

function sanitizeDisplayText(value, maximumCharacters) {
  if (value == null) {
    return "";
  }
  if (typeof value !== "string") {
    return "\u0000";
  }
  return [...value.trim().replace(/[\p{Cc}]/gu, "")].slice(0, maximumCharacters).join("");
}

function contentDisposition(fileName, attachment = false) {
  let ascii = [...fileName].map((character) => {
    const codePoint = character.codePointAt(0);
    return codePoint >= 0x20 && codePoint <= 0x7e && character !== '"' && character !== "\\"
      ? character
      : "_";
  }).join("");
  if (!ascii.replaceAll("_", "")) {
    ascii = "media";
  }
  const encoded = encodeURIComponent(fileName).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
  return `${attachment ? "attachment" : "inline"}; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

async function decodeJSONRequest(request) {
  const declaredLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAXIMUM_JSON_BYTES) {
    throw new RelayError(400, "invalid_json");
  }
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > MAXIMUM_JSON_BYTES) {
    throw new RelayError(400, "invalid_json");
  }
  try {
    const value = JSON.parse(textDecoder.decode(bytes));
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new Error("JSON object required");
    }
    return value;
  } catch {
    throw new RelayError(400, "invalid_json");
  }
}

function parseRFC3339(value) {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
  ) {
    return null;
  }
  const milliseconds = Date.parse(value);
  return Number.isFinite(milliseconds) ? new Date(milliseconds) : null;
}

function positiveInteger(value, fallback) {
  if (value == null || value === "") {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error("positive integer expected");
  }
  return parsed;
}

function requireMethod(request, expected) {
  if (request.method !== expected) {
    throw new RelayError(405, "method_not_allowed", { Allow: expected });
  }
}

function isComplete(metadata) {
  return typeof metadata.completedAt === "string" && metadata.completedAt.length > 0;
}

function isRevoked(metadata) {
  return typeof metadata.revokedAt === "string" && metadata.revokedAt.length > 0;
}

function isUploadClosed(metadata, now) {
  return isComplete(metadata) || isRevoked(metadata) || Date.parse(metadata.uploadExpiresAt) <= now;
}

function metadataObjectKey(shareID) {
  return `metadata/${shareID}.json`;
}

function publicIndexKey(hash) {
  return `indexes/public/${hash}.json`;
}

function dataObjectKey(shareID) {
  return `data/${shareID}.bin`;
}

function partRecordPrefix(shareID) {
  return `parts/${shareID}/`;
}

function partRecordKey(shareID, partNumber) {
  return `${partRecordPrefix(shareID)}${String(partNumber).padStart(5, "0")}.json`;
}

function bearerToken(request) {
  const value = request.headers.get("Authorization") ?? "";
  return value.startsWith("Bearer ") ? value.slice(7).trim() : "";
}

async function controlTokenMatches(request, metadata) {
  const actual = await tokenHash(bearerToken(request));
  return constantTimeStringEqual(actual, metadata.controlHash);
}

async function tokenMatches(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || !left || !right) {
    return false;
  }
  return constantTimeBytesEqual(await sha256(left), await sha256(right));
}

async function tokenHash(value) {
  return bytesToHex(await sha256(value));
}

async function sha256(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", textEncoder.encode(value)));
}

function constantTimeBytesEqual(left, right) {
  if (left.byteLength !== right.byteLength) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.byteLength; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

function constantTimeStringEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string" || left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function randomToken(byteCount) {
  return bytesToBase64(crypto.getRandomValues(new Uint8Array(byteCount)), true);
}

function bytesToHex(bytes) {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function bytesToBase64(bytes, urlSafe) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  const encoded = btoa(binary).replace(/=+$/g, "");
  return urlSafe ? encoded.replaceAll("+", "-").replaceAll("/", "_") : encoded;
}

function decodeBase64(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9+/_=-]*$/.test(value)) {
    throw new Error("invalid base64");
  }
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function jsonResponse(value, status = 200, omitBody = false) {
  return new Response(omitBody ? null : JSON.stringify(value), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function problemResponse(status, code, extraHeaders = {}) {
  return new Response(JSON.stringify({ error: code }), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/problem+json; charset=utf-8",
      ...extraHeaders,
    },
  });
}

function withSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  headers.set("X-Robots-Tag", "noindex, nofollow, noarchive");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export const testing = {
  ENCRYPTED_CHUNK_OVERHEAD,
  contentDisposition,
  parseContentRange,
  requestedRange,
  sanitizeContentType,
  sanitizeFileName,
  tokenHash,
};
