(() => {
  "use strict";

  const body = document.body;
  const canonicalURL = body.dataset.canonicalUrl;
  const mediaURL = body.dataset.mediaUrl;
  const downloadURL = body.dataset.downloadUrl;
  const importEndpoint = body.dataset.importUrl;
  const fileSize = Number(body.dataset.fileSize || 0);
  const title = body.dataset.title || "Primuse 音乐分享";

  const one = (selector, root = document) => root.querySelector(selector);
  const all = (selector, root = document) => [...root.querySelectorAll(selector)];

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
    button.addEventListener("click", () => copyText(canonicalURL));
  }

  for (const button of all("[data-share]")) {
    button.addEventListener("click", async () => {
      if (navigator.share) {
        try {
          await navigator.share({ title, text: `来自 Primuse 的音乐分享：${title}`, url: canonicalURL });
          return;
        } catch (error) {
          if (error?.name === "AbortError") return;
        }
      }
      await copyText(canonicalURL, "当前浏览器不支持系统分享，链接已复制");
    });
  }

  const privacyDialog = one("[data-privacy-dialog]");
  for (const button of all("[data-privacy]")) {
    button.addEventListener("click", () => openDialog(privacyDialog));
  }

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

  async function togglePlayback() {
    if (!audio || !mediaURL) return;
    if (!audioLoaded) {
      setPlayerState("loading");
      audio.src = mediaURL;
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
  });

  const downloadDialog = one("[data-download-dialog]");
  function startDownload() {
    if (!downloadURL) return;
    const anchor = document.createElement("a");
    anchor.href = downloadURL;
    anchor.rel = "noreferrer";
    anchor.download = body.dataset.fileName || "";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    downloadDialog?.close();
  }
  one("[data-download]")?.addEventListener("click", () => {
    if (fileSize >= 50 * 1024 * 1024) openDialog(downloadDialog);
    else startDownload();
  });
  one("[data-confirm-download]")?.addEventListener("click", startDownload);

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
    cachedImportURL = payload.importURL;
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
      await copyText(canonicalURL, "链接已复制，请在系统浏览器中打开");
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
  for (const button of all("[data-show-qr]")) {
    button.addEventListener("click", () => {
      try {
        if (!qrReady) {
          renderQR(one("[data-qr-canvas]"), canonicalURL);
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
