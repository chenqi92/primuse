(() => {
  "use strict";

  const body = document.body;
  const canonicalURL = body.dataset.canonicalUrl;
  const mediaURL = body.dataset.mediaUrl;
  const downloadURL = body.dataset.downloadUrl;
  const importEndpoint = body.dataset.importUrl;
  const manifestURL = body.dataset.manifestUrl;
  const chunkBaseURL = body.dataset.chunkBaseUrl;
  const encryptionMode = body.dataset.encryptionMode;
  const clientEncryptionMode = "client-aes-256-gcm-chunks-v1";
  const usesClientEncryption = encryptionMode === clientEncryptionMode;
  let fileSize = Number(body.dataset.fileSize || 0);
  let title = body.dataset.title || "Primuse 音乐分享";
  let activeKeyToken = "";
  let encryptedDetails = null;
  let decryptedMediaPromise = null;
  let decryptedMedia = null;

  const one = (selector, root = document) => root.querySelector(selector);
  const all = (selector, root = document) => [...root.querySelectorAll(selector)];

  function currentShareURL() {
    if (!canonicalURL || !usesClientEncryption || !activeKeyToken) return canonicalURL;
    return `${canonicalURL}#k=${activeKeyToken}`;
  }

  for (const expiry of all("time[data-expiry]")) {
    const date = new Date(expiry.dateTime);
    if (!Number.isNaN(date.valueOf())) {
      expiry.textContent = new Intl.DateTimeFormat("zh-CN", {
        year: "numeric",
        month: "long",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      }).format(date);
    }
  }

  let toastTimer;
  function showToast(message) {
    const toast = one("[data-toast]");
    if (!toast) return;
    window.clearTimeout(toastTimer);
    toast.textContent = message;
    toast.hidden = false;
    toastTimer = window.setTimeout(() => { toast.hidden = true; }, 2200);
  }

  async function copyText(value, successMessage = "链接已复制") {
    try {
      await navigator.clipboard.writeText(value);
    } catch {
      const input = document.createElement("textarea");
      input.value = value;
      input.setAttribute("readonly", "");
      input.style.position = "fixed";
      input.style.opacity = "0";
      document.body.append(input);
      input.select();
      document.execCommand("copy");
      input.remove();
    }
    showToast(successMessage);
  }

  function openDialog(dialog) {
    if (!dialog) return;
    if (typeof dialog.showModal === "function") dialog.showModal();
    else dialog.setAttribute("open", "");
  }

  for (const dialog of all("dialog")) {
    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) dialog.close();
    });
  }

  const menuButton = one("[data-menu-button]");
  const actionMenu = one("[data-action-menu]");
  menuButton?.addEventListener("click", () => {
    const isOpen = actionMenu && !actionMenu.hidden;
    if (actionMenu) actionMenu.hidden = isOpen;
    menuButton.setAttribute("aria-expanded", String(!isOpen));
  });
  document.addEventListener("click", (event) => {
    if (!actionMenu || actionMenu.hidden || menuButton?.contains(event.target) || actionMenu.contains(event.target)) return;
    actionMenu.hidden = true;
    menuButton?.setAttribute("aria-expanded", "false");
  });

  for (const button of all("[data-copy]")) {
    button.addEventListener("click", () => {
      if (usesClientEncryption && !activeKeyToken) {
        decryptionCard?.scrollIntoView({ behavior: "smooth", block: "center" });
        keyInput?.focus();
        showToast("请先输入解密密钥");
        return;
      }
      void copyText(currentShareURL());
    });
  }

  for (const button of all("[data-share]")) {
    button.addEventListener("click", async () => {
      if (usesClientEncryption && !activeKeyToken) {
        decryptionCard?.scrollIntoView({ behavior: "smooth", block: "center" });
        keyInput?.focus();
        showToast("请先输入解密密钥");
        return;
      }
      if (navigator.share) {
        try {
          await navigator.share({ title, text: `来自 Primuse 的音乐分享：${title}`, url: currentShareURL() });
          return;
        } catch (error) {
          if (error?.name === "AbortError") return;
        }
      }
      await copyText(currentShareURL(), "当前浏览器不支持系统分享，链接已复制");
    });
  }

  const privacyDialog = one("[data-privacy-dialog]");
  for (const button of all("[data-privacy]")) {
    button.addEventListener("click", () => openDialog(privacyDialog));
  }

  const keyForm = one("[data-key-form]");
  const keyInput = one("[data-key-input]");
  const keySubmit = one("[data-key-submit]");
  const keyMessage = one("[data-key-message]");
  const decryptionCard = one("[data-decryption-card]");
  const decryptionTitle = one("[data-decryption-title]");
  const decryptionState = one("[data-decryption-state]");
  const decryptionCopy = one("[data-decryption-copy]");
  const decryptionProgress = one("[data-decryption-progress]");
  const decryptionProgressLabel = one("[data-decryption-progress-label]");
  const decryptionProgressValue = one("[data-decryption-progress-value]");
  const decryptionProgressBar = one("[data-decryption-progress-bar]");
  const textEncoder = new TextEncoder();
  const textDecoder = new TextDecoder();

  function bytesToBase64URL(bytes) {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
  }

  function base64URLToBytes(value) {
    if (typeof value !== "string" || !/^[A-Za-z0-9_-]+={0,2}$/.test(value)) {
      throw new Error("invalid_key");
    }
    const raw = value.replace(/=+$/g, "");
    const padded = raw.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - raw.length % 4) % 4);
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  }

  function keyTokenFromValue(rawValue) {
    let value = String(rawValue || "").trim();
    if (!value) throw new Error("missing_key");
    try {
      const parsed = new URL(value);
      if (canonicalURL) {
        const expected = new URL(canonicalURL);
        if (parsed.origin !== expected.origin || parsed.pathname !== expected.pathname) {
          throw new Error("wrong_share");
        }
      }
      value = new URLSearchParams(parsed.hash.slice(1)).get("k") || "";
    } catch (error) {
      if (error?.message === "wrong_share") throw error;
      if (value.startsWith("#")) value = value.slice(1);
      if (value.startsWith("k=")) value = new URLSearchParams(value).get("k") || "";
    }
    const bytes = base64URLToBytes(value);
    if (bytes.byteLength !== 32) throw new Error("invalid_key");
    return bytesToBase64URL(bytes);
  }

  async function importDecryptionKey(token) {
    if (!globalThis.crypto?.subtle) throw new Error("crypto_unavailable");
    return crypto.subtle.importKey(
      "raw",
      base64URLToBytes(token),
      { name: "AES-GCM" },
      false,
      ["decrypt"],
    );
  }

  async function decryptEnvelope(encrypted, key, additionalData) {
    if (!(encrypted instanceof Uint8Array) || encrypted.byteLength <= 28) {
      throw new Error("invalid_envelope");
    }
    const plaintext = await crypto.subtle.decrypt({
      name: "AES-GCM",
      iv: encrypted.subarray(0, 12),
      additionalData: textEncoder.encode(additionalData),
      tagLength: 128,
    }, key, encrypted.subarray(12));
    return new Uint8Array(plaintext);
  }

  function cleanManifestText(value, maximum, optional = false) {
    if (value == null && optional) return "";
    if (typeof value !== "string" || value.length > maximum || /[\u0000-\u001f\u007f]/.test(value)) {
      throw new Error("invalid_manifest");
    }
    return value.trim();
  }

  function validatedManifest(value, expectedSize, expectedChunkSize) {
    if (!value || value.version !== 1 || !Number.isSafeInteger(value.size) || value.size !== expectedSize ||
        !Number.isSafeInteger(value.chunkSize) || value.chunkSize !== expectedChunkSize ||
        !Number.isFinite(value.durationSeconds) || value.durationSeconds < 0 || value.durationSeconds > 7 * 24 * 60 * 60) {
      throw new Error("invalid_manifest");
    }
    const fileName = cleanManifestText(value.fileName, 180);
    const contentType = cleanManifestText(value.contentType, 96).toLowerCase();
    const titleValue = cleanManifestText(value.title, 160);
    if (!fileName || !titleValue || !/^(?:audio|video)\/[a-z0-9!#$&^_.+-]+$|^application\/(?:octet-stream|ogg)$/.test(contentType)) {
      throw new Error("invalid_manifest");
    }
    return {
      version: 1,
      fileName,
      contentType,
      size: value.size,
      chunkSize: value.chunkSize,
      title: titleValue,
      artist: cleanManifestText(value.artist, 160, true),
      album: cleanManifestText(value.album, 160, true),
      audioFormat: cleanManifestText(value.audioFormat, 32, true),
      quality: cleanManifestText(value.quality, 80, true),
      durationSeconds: value.durationSeconds,
    };
  }

  function humanFileSize(bytes) {
    const units = ["B", "KB", "MB", "GB", "TB"];
    let value = bytes;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
    return unit === 0 ? `${bytes} B` : `${value.toFixed(1)} ${units[unit]}`;
  }

  function revealEncryptedShare(manifest) {
    title = manifest.title;
    fileSize = manifest.size;
    body.dataset.title = manifest.title;
    body.dataset.fileName = manifest.fileName;
    body.dataset.fileSize = String(manifest.size);
    const artistAlbum = [manifest.artist, manifest.album ? `《${manifest.album}》` : ""].filter(Boolean).join(" · ")
      || "来自 Primuse 的音乐分享";
    const sizeLabel = humanFileSize(manifest.size);
    const titleNode = one("[data-track-title]");
    const artistNode = one("[data-artist-album]");
    const formatNode = one("[data-audio-format]");
    const qualityNode = one("[data-audio-quality]");
    if (titleNode) titleNode.textContent = manifest.title;
    if (artistNode) artistNode.textContent = artistAlbum;
    if (formatNode) { formatNode.textContent = manifest.audioFormat; formatNode.hidden = !manifest.audioFormat; }
    if (qualityNode) { qualityNode.textContent = manifest.quality; qualityNode.hidden = !manifest.quality; }
    for (const node of all("[data-file-size-label], [data-download-size]")) node.textContent = sizeLabel;
    for (const node of all("[data-download-file-name]")) node.textContent = manifest.fileName;
    const cover = one(".cover");
    if (cover) cover.alt = `《${manifest.title}》封面`;
    if (body.dataset.allowPlayback === "true") one('[data-protected-action="playback"]')?.removeAttribute("hidden");
    if (body.dataset.allowDownload === "true") one('[data-protected-action="download"]')?.removeAttribute("hidden");
    if (body.dataset.allowImport === "true") one('[data-protected-action="import"]')?.removeAttribute("hidden");
    document.title = `${manifest.title} · Primuse 音乐分享`;
    if (decryptionCard) decryptionCard.dataset.state = "ready";
    if (decryptionTitle) decryptionTitle.textContent = "已在此设备解密";
    if (decryptionState) decryptionState.textContent = "密钥未上传";
    if (decryptionCopy) decryptionCopy.textContent = "歌曲信息与音频只在当前设备解密。";
    if (keyInput) keyInput.value = "";
  }

  function setDecryptionProgress(fraction, label = "正在本地解密…") {
    const normalized = Math.max(0, Math.min(1, fraction));
    if (decryptionProgress) decryptionProgress.hidden = false;
    if (decryptionProgressBar) decryptionProgressBar.value = normalized;
    if (decryptionProgressValue) decryptionProgressValue.textContent = `${Math.round(normalized * 100)}%`;
    if (decryptionProgressLabel) decryptionProgressLabel.textContent = label;
  }

  function showKeyError(error) {
    const messages = {
      missing_key: "请输入解密密钥或完整分享链接。",
      invalid_key: "密钥格式不正确，请向分享者确认。",
      wrong_share: "这条完整链接不属于当前分享。",
      crypto_unavailable: "当前浏览器不支持安全的本地解密，请更新浏览器。",
    };
    if (keyMessage) {
      keyMessage.textContent = messages[error?.message] || "无法解密。密钥可能不正确，或分享数据已损坏。";
      keyMessage.className = "form-message error";
    }
    if (decryptionState) decryptionState.textContent = "解密失败";
    if (decryptionProgress) decryptionProgress.hidden = true;
  }

  async function unlockEncryptedShare(rawKey) {
    if (!usesClientEncryption || !manifestURL) return;
    const token = keyTokenFromValue(rawKey);
    if (keySubmit) keySubmit.disabled = true;
    if (decryptionState) decryptionState.textContent = "验证中";
    if (keyMessage) { keyMessage.textContent = "正在获取加密信息并在本地验证密钥…"; keyMessage.className = "form-message"; }
    try {
      const key = await importDecryptionKey(token);
      const response = await fetch(manifestURL, { credentials: "same-origin", cache: "no-store" });
      if (!response.ok) throw new Error(response.status === 401 ? "password_required" : "manifest_unavailable");
      const shareID = response.headers.get("X-Primuse-Share-ID") || "";
      const expectedSize = Number(response.headers.get("X-Primuse-Plaintext-Size"));
      const expectedChunkSize = Number(response.headers.get("X-Primuse-Chunk-Size"));
      if (!/^[A-Za-z0-9_-]{16,128}$/.test(shareID) || !Number.isSafeInteger(expectedSize) || expectedSize <= 0 ||
          !Number.isSafeInteger(expectedChunkSize) || expectedChunkSize < 256 * 1024 || expectedChunkSize > 32 * 1024 * 1024 ||
          (fileSize > 0 && expectedSize !== fileSize)) {
        throw new Error("invalid_manifest");
      }
      const encrypted = new Uint8Array(await response.arrayBuffer());
      const plaintext = await decryptEnvelope(encrypted, key, `primuse-share-e2ee-v1:${shareID}:manifest`);
      const manifest = validatedManifest(JSON.parse(textDecoder.decode(plaintext)), expectedSize, expectedChunkSize);
      if (decryptedMedia?.objectURL) URL.revokeObjectURL(decryptedMedia.objectURL);
      decryptedMedia = null;
      decryptedMediaPromise = null;
      audioLoaded = false;
      activeKeyToken = token;
      encryptedDetails = { key, shareID, manifest };
      const current = new URL(window.location.href);
      current.hash = `k=${token}`;
      history.replaceState(null, "", current);
      revealEncryptedShare(manifest);
      qrReady = false;
    } catch (error) {
      activeKeyToken = "";
      encryptedDetails = null;
      showKeyError(error);
      throw error;
    } finally {
      if (keySubmit) keySubmit.disabled = false;
    }
  }

  keyForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    try { await unlockEncryptedShare(keyInput?.value); } catch { /* feedback is shown inline */ }
  });

  const audio = one("[data-audio]");
  const playButton = one("[data-play]");
  const timeline = one("[data-timeline]");
  const currentTime = one("[data-current-time]");
  const duration = one("[data-duration]");
  const playerMessage = one("[data-player-message]");
  const artworkStage = one(".artwork-stage");
  const volume = one("[data-volume]");
  const muteButton = one("[data-mute]");
  let audioLoaded = false;

  function formatTime(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return "--:--";
    const whole = Math.floor(seconds);
    const hours = Math.floor(whole / 3600);
    const minutes = Math.floor((whole % 3600) / 60);
    const remainder = String(whole % 60).padStart(2, "0");
    return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${remainder}` : `${minutes}:${remainder}`;
  }

  function setPlayerState(state) {
    if (!playButton) return;
    playButton.dataset.state = state;
    const labels = { idle: "播放", loading: "正在加载", playing: "暂停", paused: "播放" };
    playButton.setAttribute("aria-label", labels[state] || "播放");
    if (artworkStage) artworkStage.dataset.spins = String(state === "playing");
  }

  function showPlayerError(message) {
    setPlayerState("paused");
    if (playerMessage) {
      playerMessage.textContent = message;
      playerMessage.hidden = false;
    }
  }

  async function ensureDecryptedMedia() {
    if (!usesClientEncryption) return null;
    if (decryptedMedia) return decryptedMedia;
    if (decryptedMediaPromise) return decryptedMediaPromise;
    if (!encryptedDetails || !chunkBaseURL) {
      decryptionCard?.scrollIntoView({ behavior: "smooth", block: "center" });
      keyInput?.focus();
      throw new Error("missing_key");
    }
    decryptedMediaPromise = (async () => {
      const { key, shareID, manifest } = encryptedDetails;
      const chunkCount = Math.ceil(manifest.size / manifest.chunkSize);
      const chunks = [];
      setDecryptionProgress(0, "正在下载并本地解密音频…");
      for (let index = 0; index < chunkCount; index += 1) {
        const expectedLength = Math.min(manifest.chunkSize, manifest.size - index * manifest.chunkSize);
        const response = await fetch(`${chunkBaseURL}/${index}`, {
          credentials: "same-origin",
          cache: "no-store",
        });
        if (!response.ok) throw new Error("media_unavailable");
        const encrypted = new Uint8Array(await response.arrayBuffer());
        if (encrypted.byteLength !== expectedLength + 28) throw new Error("invalid_envelope");
        const plaintext = await decryptEnvelope(
          encrypted,
          key,
          `primuse-share-e2ee-v1:${shareID}:chunk:${index}:${expectedLength}`,
        );
        if (plaintext.byteLength !== expectedLength) throw new Error("invalid_envelope");
        chunks.push(plaintext);
        setDecryptionProgress((index + 1) / chunkCount, "正在下载并本地解密音频…");
      }
      const blob = new Blob(chunks, { type: manifest.contentType });
      const objectURL = URL.createObjectURL(blob);
      decryptedMedia = { blob, objectURL };
      setDecryptionProgress(1, "音频已在此设备解密");
      window.setTimeout(() => { if (decryptionProgress) decryptionProgress.hidden = true; }, 900);
      return decryptedMedia;
    })();
    try {
      return await decryptedMediaPromise;
    } catch (error) {
      decryptedMediaPromise = null;
      if (decryptionProgress) decryptionProgress.hidden = true;
      throw error;
    }
  }

  async function togglePlayback() {
    if (!audio || (!mediaURL && !usesClientEncryption)) return;
    if (!audioLoaded) {
      setPlayerState("loading");
      try {
        audio.src = usesClientEncryption
          ? (await ensureDecryptedMedia()).objectURL
          : mediaURL;
      } catch (error) {
        showPlayerError(error?.message === "missing_key"
          ? "请先输入解密密钥。"
          : "本地解密失败，请检查网络或重新输入密钥。");
        return;
      }
      audio.load();
      audioLoaded = true;
    }
    if (audio.paused) {
      try {
        setPlayerState("loading");
        await audio.play();
      } catch {
        showPlayerError("暂时无法播放。你可以稍后重试，或下载原文件。");
      }
    } else {
      audio.pause();
    }
  }

  playButton?.addEventListener("click", togglePlayback);
  audio?.addEventListener("playing", () => {
    if (playerMessage) playerMessage.hidden = true;
    setPlayerState("playing");
  });
  audio?.addEventListener("pause", () => setPlayerState("paused"));
  audio?.addEventListener("waiting", () => setPlayerState("loading"));
  audio?.addEventListener("loadedmetadata", () => {
    if (duration) duration.textContent = formatTime(audio.duration);
  });
  audio?.addEventListener("timeupdate", () => {
    if (!timeline || !audio.duration) return;
    const value = Math.round((audio.currentTime / audio.duration) * 1000);
    timeline.value = String(value);
    timeline.style.setProperty("--value", `${value / 10}%`);
    if (currentTime) currentTime.textContent = formatTime(audio.currentTime);
  });
  audio?.addEventListener("error", () => {
    const code = audio.error?.code;
    const message = code === 4
      ? "当前浏览器不支持这个音频格式，可下载原文件或用 Primuse 打开。"
      : "音频加载失败，请检查网络后重试。";
    showPlayerError(message);
  });

  timeline?.addEventListener("input", () => {
    const value = Number(timeline.value);
    timeline.style.setProperty("--value", `${value / 10}%`);
    if (audio?.duration) audio.currentTime = (value / 1000) * audio.duration;
  });
  volume?.addEventListener("input", () => {
    if (!audio) return;
    audio.volume = Number(volume.value);
    audio.muted = false;
    volume.style.setProperty("--value", `${Number(volume.value) * 100}%`);
  });
  if (volume) volume.style.setProperty("--value", "70%");
  muteButton?.addEventListener("click", () => {
    if (!audio) return;
    audio.muted = !audio.muted;
    muteButton.setAttribute("aria-label", audio.muted ? "取消静音" : "静音");
    muteButton.style.opacity = audio.muted ? "0.5" : "1";
  });

  document.addEventListener("keydown", (event) => {
    if (!audio || event.target instanceof HTMLInputElement || event.target instanceof HTMLTextAreaElement) return;
    if (event.code === "Space") {
      event.preventDefault();
      togglePlayback();
    } else if (event.code === "ArrowLeft" && audioLoaded) {
      audio.currentTime = Math.max(0, audio.currentTime - 15);
    } else if (event.code === "ArrowRight" && audioLoaded) {
      audio.currentTime = Math.min(audio.duration || Infinity, audio.currentTime + 15);
    }
  });

  window.addEventListener("pagehide", () => {
    if (!audio) return;
    audio.pause();
    audio.removeAttribute("src");
    audio.load();
    if (decryptedMedia?.objectURL) URL.revokeObjectURL(decryptedMedia.objectURL);
  });

  const downloadDialog = one("[data-download-dialog]");
  async function startDownload() {
    if (!downloadURL && !usesClientEncryption) return;
    let targetURL = downloadURL;
    try {
      if (usesClientEncryption) targetURL = (await ensureDecryptedMedia()).objectURL;
    } catch (error) {
      showToast(error?.message === "missing_key" ? "请先输入解密密钥" : "本地解密失败，请稍后重试");
      return;
    }
    const anchor = document.createElement("a");
    anchor.href = targetURL;
    anchor.rel = "noreferrer";
    anchor.download = body.dataset.fileName || "";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    downloadDialog?.close();
  }
  one("[data-download]")?.addEventListener("click", () => {
    if (fileSize >= 50 * 1024 * 1024) openDialog(downloadDialog);
    else void startDownload();
  });
  one("[data-confirm-download]")?.addEventListener("click", () => void startDownload());

  let cachedImportURL = "";
  let cachedImportExpiresAt = 0;
  async function requestImportURL() {
    if (cachedImportURL && cachedImportExpiresAt > Date.now() + 5_000) return cachedImportURL;
    const response = await fetch(importEndpoint, {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error("import_unavailable");
    const payload = await response.json();
    const expiresAt = Date.parse(payload.expiresAt);
    if (typeof payload.importURL !== "string" || !payload.importURL.startsWith("https://")
        || !Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
      throw new Error("invalid_import_url");
    }
    if (usesClientEncryption && !activeKeyToken) throw new Error("missing_key");
    cachedImportURL = usesClientEncryption
      ? `${payload.importURL}#k=${activeKeyToken}`
      : payload.importURL;
    cachedImportExpiresAt = expiresAt;
    return cachedImportURL;
  }

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) {
      cachedImportURL = "";
      cachedImportExpiresAt = 0;
    }
  });

  const installDialog = one("[data-install-dialog]");
  one("[data-open-primuse]")?.addEventListener("click", async () => {
    if (/MicroMessenger/i.test(navigator.userAgent)) {
      await copyText(currentShareURL(), "链接已复制，请在系统浏览器中打开");
      return;
    }
    try {
      const importURL = await requestImportURL();
      let hidden = document.hidden;
      const visibility = () => { hidden = document.hidden; };
      document.addEventListener("visibilitychange", visibility, { once: true });
      window.location.href = `primuse://import-share?url=${encodeURIComponent(importURL)}`;
      window.setTimeout(() => {
        document.removeEventListener("visibilitychange", visibility);
        if (!hidden && !document.hidden) openDialog(installDialog);
      }, 1200);
    } catch {
      showToast("暂时无法创建导入凭证，请稍后重试");
    }
  });
  one("[data-copy-import]")?.addEventListener("click", async () => {
    try {
      await copyText(await requestImportURL(), "导入链接已复制，10 分钟内有效");
    } catch {
      showToast("暂时无法创建导入凭证，请稍后重试");
    }
  });

  const qrDialog = one("[data-qr-dialog]");
  const qrHost = one("[data-qr-host]");
  try {
    if (qrHost) qrHost.textContent = new URL(canonicalURL).host;
  } catch { /* keep the configured host label */ }
  let qrReady = false;
  if (usesClientEncryption && window.location.hash) {
    void unlockEncryptedShare(window.location.href).catch(() => {});
  }
  for (const button of all("[data-show-qr]")) {
    button.addEventListener("click", () => {
      try {
        if (usesClientEncryption && !activeKeyToken) {
          decryptionCard?.scrollIntoView({ behavior: "smooth", block: "center" });
          keyInput?.focus();
          showToast("请先输入解密密钥");
          return;
        }
        if (!qrReady) {
          renderQR(one("[data-qr-canvas]"), currentShareURL());
          qrReady = true;
        }
        openDialog(qrDialog);
      } catch {
        showToast("二维码生成失败，请改用复制链接");
      }
    });
  }
  one("[data-save-qr]")?.addEventListener("click", () => {
    const canvas = one("[data-qr-canvas]");
    if (!canvas) return;
    const anchor = document.createElement("a");
    anchor.href = canvas.toDataURL("image/png");
    anchor.download = "primuse-share-qr.png";
    anchor.click();
  });
  one("[data-print-qr]")?.addEventListener("click", () => window.print());

  const passwordForm = one("[data-password-form]");
  const passwordInput = one("#share-password");
  const passwordMessage = one("#password-message");
  const unlockButton = one("[data-unlock]");
  const unlockLabel = one("[data-unlock-label]");
  let retryCountdownActive = false;
  one("[data-toggle-password]")?.addEventListener("click", (event) => {
    if (!passwordInput) return;
    const revealing = passwordInput.type === "password";
    passwordInput.type = revealing ? "text" : "password";
    event.currentTarget.textContent = revealing ? "隐藏" : "显示";
    event.currentTarget.setAttribute("aria-label", revealing ? "隐藏密码" : "显示密码");
  });

  function setRetryCountdown(seconds) {
    if (!unlockButton || !passwordMessage) return;
    let remaining = Math.max(1, Number(seconds) || 60);
    retryCountdownActive = true;
    unlockButton.disabled = true;
    passwordMessage.className = "form-message error";
    const tick = () => {
      const minutes = Math.floor(remaining / 60);
      const rest = String(remaining % 60).padStart(2, "0");
      passwordMessage.textContent = `尝试次数过多，请在 ${minutes}:${rest} 后重试。`;
      if (remaining <= 0) {
        retryCountdownActive = false;
        unlockButton.disabled = false;
        passwordMessage.textContent = "可以重新尝试。";
        passwordMessage.className = "form-message";
        return;
      }
      remaining -= 1;
      window.setTimeout(tick, 1000);
    };
    tick();
  }

  if (body.dataset.retryAfter) setRetryCountdown(body.dataset.retryAfter);
  passwordForm?.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!passwordInput?.value || unlockButton?.disabled) return;
    unlockButton.dataset.loading = "true";
    unlockButton.disabled = true;
    if (unlockLabel) unlockLabel.textContent = "验证中…";
    try {
      const response = await fetch(passwordForm.action, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
        },
        body: new URLSearchParams({ password: passwordInput.value }),
      });
      if (response.ok) {
        window.location.replace(canonicalURL || window.location.href);
        return;
      }
      if (response.status === 429) {
        setRetryCountdown(response.headers.get("Retry-After") || 60);
        return;
      }
      passwordMessage.textContent = "密码不正确，请检查后重试。";
      passwordMessage.className = "form-message error";
      one(".password-field")?.classList.add("error");
      window.setTimeout(() => one(".password-field")?.classList.remove("error"), 360);
    } catch {
      passwordMessage.textContent = "网络似乎断开了，请检查连接后重试。";
      passwordMessage.className = "form-message error";
    } finally {
      unlockButton.dataset.loading = "false";
      if (!retryCountdownActive) unlockButton.disabled = false;
      if (unlockLabel) unlockLabel.textContent = "解锁";
    }
  });

  function renderQR(canvas, value) {
    if (!(canvas instanceof HTMLCanvasElement) || !value) throw new Error("qr_unavailable");
    const matrix = makeQR(value);
    const context = canvas.getContext("2d", { alpha: false });
    const quiet = 4;
    const top = 34;
    const available = 884;
    const moduleCount = matrix.length + quiet * 2;
    const cell = Math.floor(available / moduleCount);
    const qrSize = cell * moduleCount;
    const left = Math.floor((1024 - qrSize) / 2);
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, 1024, 1024);
    context.fillStyle = "#091018";
    for (let row = 0; row < matrix.length; row += 1) {
      for (let column = 0; column < matrix.length; column += 1) {
        if (matrix[row][column]) {
          context.fillRect(left + (column + quiet) * cell, top + (row + quiet) * cell, cell, cell);
        }
      }
    }
    let host = "share.soundisle.com";
    try { host = new URL(value).host; } catch { /* keep fallback */ }
    context.fillStyle = "#091018";
    context.font = "600 28px -apple-system, BlinkMacSystemFont, sans-serif";
    context.textAlign = "center";
    context.fillText(host, 512, 982);
  }

  const QR_BLOCKS_M = {
    1: [[1, 16, 10]], 2: [[1, 28, 16]], 3: [[1, 44, 26]],
    4: [[2, 32, 18]], 5: [[2, 43, 24]], 6: [[4, 27, 16]],
    7: [[4, 31, 18]], 8: [[2, 38, 22], [2, 39, 22]],
    9: [[3, 36, 22], [2, 37, 22]], 10: [[4, 43, 26], [1, 44, 26]],
  };
  const QR_ALIGN = {
    1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30],
    6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42],
    9: [6, 26, 46], 10: [6, 28, 50],
  };

  const gfExp = new Uint8Array(512);
  const gfLog = new Uint8Array(256);
  let gfValue = 1;
  for (let index = 0; index < 255; index += 1) {
    gfExp[index] = gfValue;
    gfLog[gfValue] = index;
    gfValue <<= 1;
    if (gfValue & 0x100) gfValue ^= 0x11d;
  }
  for (let index = 255; index < 512; index += 1) gfExp[index] = gfExp[index - 255];

  function gfMultiply(left, right) {
    return left && right ? gfExp[gfLog[left] + gfLog[right]] : 0;
  }

  function multiplyPolynomial(left, right) {
    const result = new Uint8Array(left.length + right.length - 1);
    for (let i = 0; i < left.length; i += 1) {
      for (let j = 0; j < right.length; j += 1) result[i + j] ^= gfMultiply(left[i], right[j]);
    }
    return result;
  }

  function reedSolomon(data, degree) {
    let generator = Uint8Array.of(1);
    for (let index = 0; index < degree; index += 1) {
      generator = multiplyPolynomial(generator, Uint8Array.of(1, gfExp[index]));
    }
    const result = new Uint8Array(data.length + degree);
    result.set(data);
    for (let index = 0; index < data.length; index += 1) {
      const factor = result[index];
      if (!factor) continue;
      for (let j = 0; j < generator.length; j += 1) result[index + j] ^= gfMultiply(generator[j], factor);
    }
    return result.slice(data.length);
  }

  function appendBits(bits, value, length) {
    for (let index = length - 1; index >= 0; index -= 1) bits.push((value >>> index) & 1);
  }

  function makeCodewords(value) {
    const bytes = new TextEncoder().encode(value);
    let version = 0;
    let blockSpec;
    for (let candidate = 1; candidate <= 10; candidate += 1) {
      const spec = QR_BLOCKS_M[candidate];
      const capacity = spec.reduce((sum, [count, data]) => sum + count * data, 0) * 8;
      const required = 4 + (candidate < 10 ? 8 : 16) + bytes.length * 8;
      if (required <= capacity) {
        version = candidate;
        blockSpec = spec;
        break;
      }
    }
    if (!version) throw new Error("qr_value_too_long");
    const dataCapacity = blockSpec.reduce((sum, [count, data]) => sum + count * data, 0);
    const bits = [];
    appendBits(bits, 0b0100, 4);
    appendBits(bits, bytes.length, version < 10 ? 8 : 16);
    for (const byte of bytes) appendBits(bits, byte, 8);
    const remaining = dataCapacity * 8 - bits.length;
    appendBits(bits, 0, Math.min(4, remaining));
    while (bits.length % 8) bits.push(0);
    const data = [];
    for (let index = 0; index < bits.length; index += 8) {
      let byte = 0;
      for (let offset = 0; offset < 8; offset += 1) byte = (byte << 1) | bits[index + offset];
      data.push(byte);
    }
    for (let pad = 0; data.length < dataCapacity; pad += 1) data.push(pad % 2 ? 0x11 : 0xec);

    const dataBlocks = [];
    const errorBlocks = [];
    let cursor = 0;
    for (const [count, dataCount, errorCount] of blockSpec) {
      for (let block = 0; block < count; block += 1) {
        const chunk = Uint8Array.from(data.slice(cursor, cursor + dataCount));
        cursor += dataCount;
        dataBlocks.push(chunk);
        errorBlocks.push(reedSolomon(chunk, errorCount));
      }
    }
    const interleaved = [];
    const maxData = Math.max(...dataBlocks.map((block) => block.length));
    const maxError = Math.max(...errorBlocks.map((block) => block.length));
    for (let index = 0; index < maxData; index += 1) {
      for (const block of dataBlocks) if (index < block.length) interleaved.push(block[index]);
    }
    for (let index = 0; index < maxError; index += 1) {
      for (const block of errorBlocks) if (index < block.length) interleaved.push(block[index]);
    }
    return { version, codewords: interleaved };
  }

  function bchDigit(value) {
    let digits = 0;
    while (value) { digits += 1; value >>>= 1; }
    return digits;
  }

  function bchTypeInfo(value) {
    let remainder = value << 10;
    const generator = 0x537;
    while (bchDigit(remainder) - bchDigit(generator) >= 0) {
      remainder ^= generator << (bchDigit(remainder) - bchDigit(generator));
    }
    return ((value << 10) | remainder) ^ 0x5412;
  }

  function bchVersion(value) {
    let remainder = value << 12;
    const generator = 0x1f25;
    while (bchDigit(remainder) - bchDigit(generator) >= 0) {
      remainder ^= generator << (bchDigit(remainder) - bchDigit(generator));
    }
    return (value << 12) | remainder;
  }

  function maskBit(mask, row, column) {
    const product = row * column;
    switch (mask) {
      case 0: return (row + column) % 2 === 0;
      case 1: return row % 2 === 0;
      case 2: return column % 3 === 0;
      case 3: return (row + column) % 3 === 0;
      case 4: return (Math.floor(row / 2) + Math.floor(column / 3)) % 2 === 0;
      case 5: return product % 2 + product % 3 === 0;
      case 6: return (product % 2 + product % 3) % 2 === 0;
      default: return (product % 3 + (row + column) % 2) % 2 === 0;
    }
  }

  function buildMatrix(version, codewords, mask) {
    const size = 17 + version * 4;
    const modules = Array.from({ length: size }, () => Array(size).fill(null));
    const probe = (top, left) => {
      for (let row = -1; row <= 7; row += 1) {
        if (top + row < 0 || top + row >= size) continue;
        for (let column = -1; column <= 7; column += 1) {
          if (left + column < 0 || left + column >= size) continue;
          modules[top + row][left + column] = row >= 0 && row <= 6 && column >= 0 && column <= 6
            && (row === 0 || row === 6 || column === 0 || column === 6 || (row >= 2 && row <= 4 && column >= 2 && column <= 4));
        }
      }
    };
    probe(0, 0);
    probe(size - 7, 0);
    probe(0, size - 7);

    for (const row of QR_ALIGN[version]) {
      for (const column of QR_ALIGN[version]) {
        if (modules[row][column] !== null) continue;
        for (let deltaRow = -2; deltaRow <= 2; deltaRow += 1) {
          for (let deltaColumn = -2; deltaColumn <= 2; deltaColumn += 1) {
            modules[row + deltaRow][column + deltaColumn] = Math.max(Math.abs(deltaRow), Math.abs(deltaColumn)) !== 1;
          }
        }
      }
    }

    for (let index = 8; index < size - 8; index += 1) {
      if (modules[index][6] === null) modules[index][6] = index % 2 === 0;
      if (modules[6][index] === null) modules[6][index] = index % 2 === 0;
    }

    const format = bchTypeInfo(mask);
    for (let index = 0; index < 15; index += 1) {
      const dark = ((format >>> index) & 1) === 1;
      if (index < 6) modules[index][8] = dark;
      else if (index < 8) modules[index + 1][8] = dark;
      else modules[size - 15 + index][8] = dark;
      if (index < 8) modules[8][size - index - 1] = dark;
      else if (index < 9) modules[8][7] = dark;
      else modules[8][15 - index - 1] = dark;
    }
    modules[size - 8][8] = true;

    if (version >= 7) {
      const versionBits = bchVersion(version);
      for (let index = 0; index < 18; index += 1) {
        const dark = ((versionBits >>> index) & 1) === 1;
        modules[Math.floor(index / 3)][index % 3 + size - 11] = dark;
        modules[index % 3 + size - 11][Math.floor(index / 3)] = dark;
      }
    }

    let row = size - 1;
    let direction = -1;
    let byteIndex = 0;
    let bitIndex = 7;
    for (let column = size - 1; column > 0; column -= 2) {
      if (column === 6) column -= 1;
      while (true) {
        for (let offset = 0; offset < 2; offset += 1) {
          const targetColumn = column - offset;
          if (modules[row][targetColumn] !== null) continue;
          let dark = byteIndex < codewords.length && ((codewords[byteIndex] >>> bitIndex) & 1) === 1;
          if (maskBit(mask, row, targetColumn)) dark = !dark;
          modules[row][targetColumn] = dark;
          bitIndex -= 1;
          if (bitIndex < 0) { byteIndex += 1; bitIndex = 7; }
        }
        row += direction;
        if (row < 0 || row >= size) {
          row -= direction;
          direction = -direction;
          break;
        }
      }
    }
    return modules;
  }

  function matrixPenalty(modules) {
    const size = modules.length;
    let penalty = 0;
    const scoreRuns = (values) => {
      let run = 1;
      for (let index = 1; index <= values.length; index += 1) {
        if (index < values.length && values[index] === values[index - 1]) run += 1;
        else { if (run >= 5) penalty += 3 + run - 5; run = 1; }
      }
      const sequence = values.map(Number).join("");
      penalty += (sequence.match(/10111010000/g) || []).length * 40;
      penalty += (sequence.match(/00001011101/g) || []).length * 40;
    };
    for (let row = 0; row < size; row += 1) scoreRuns(modules[row]);
    for (let column = 0; column < size; column += 1) scoreRuns(modules.map((row) => row[column]));
    let dark = 0;
    for (let row = 0; row < size; row += 1) {
      for (let column = 0; column < size; column += 1) {
        if (modules[row][column]) dark += 1;
        if (row + 1 < size && column + 1 < size) {
          const value = modules[row][column];
          if (modules[row + 1][column] === value && modules[row][column + 1] === value && modules[row + 1][column + 1] === value) penalty += 3;
        }
      }
    }
    penalty += Math.floor(Math.abs((dark * 100) / (size * size) - 50) / 5) * 10;
    return penalty;
  }

  function makeQR(value) {
    const encoded = makeCodewords(value);
    let best;
    let bestPenalty = Infinity;
    for (let mask = 0; mask < 8; mask += 1) {
      const candidate = buildMatrix(encoded.version, encoded.codewords, mask);
      const penalty = matrixPenalty(candidate);
      if (penalty < bestPenalty) { best = candidate; bestPenalty = penalty; }
    }
    return best;
  }
})();
