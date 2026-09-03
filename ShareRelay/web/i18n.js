(function () {
  "use strict";

  const supported = new Set(["en", "de", "fr", "ja", "ko", "zh-Hans", "zh-Hant"]);

  function normalizedLocale(value) {
    const raw = String(value || "").replaceAll("_", "-").toLowerCase();
    if (raw === "zh-hant" || raw.startsWith("zh-hant-") || /^zh-(tw|hk|mo)(?:-|$)/.test(raw)) {
      return "zh-Hant";
    }
    if (raw === "zh" || raw === "zh-hans" || raw.startsWith("zh-hans-") || /^zh-(cn|sg|my)(?:-|$)/.test(raw)) {
      return "zh-Hans";
    }
    const base = raw.split("-")[0];
    return supported.has(base) ? base : "en";
  }

  function interpolate(value, replacements) {
    return Object.entries(replacements || {}).reduce(
      (result, [key, replacement]) => result.replaceAll(`{${key}}`, String(replacement)),
      value,
    );
  }

  const locale = normalizedLocale(document.documentElement.lang);
  window.PrimuseI18nReady = fetch("/i18n.json?v=20260903.1", {
    cache: "force-cache",
    credentials: "same-origin",
  }).then(async (response) => {
    if (!response.ok) throw new Error("catalog_unavailable");
    const catalog = await response.json();
    const keys = Array.isArray(catalog.keys) ? catalog.keys : [];
    const english = catalog.locales?.en;
    const selected = catalog.locales?.[locale];
    if (!Array.isArray(english) || !Array.isArray(selected)
        || english.length !== keys.length || selected.length !== keys.length) {
      throw new Error("catalog_invalid");
    }
    const englishMap = Object.fromEntries(keys.map((key, index) => [key, english[index]]));
    const selectedMap = Object.fromEntries(keys.map((key, index) => [key, selected[index]]));
    return {
      locale,
      t(key, replacements) {
        return interpolate(selectedMap[key] ?? englishMap[key] ?? key, replacements);
      },
    };
  });
})();
