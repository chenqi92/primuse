package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
)

const primuseAppStoreURL = "https://apps.apple.com/app/id6761675450"

var supportedWebLocales = map[string]struct{}{
	"en": {}, "de": {}, "fr": {}, "ja": {}, "ko": {}, "zh-Hans": {}, "zh-Hant": {},
}

type embeddedWebCatalog struct {
	Keys    []string            `json:"keys"`
	Locales map[string][]string `json:"locales"`
}

var (
	webCatalogOnce sync.Once
	webCatalogData map[string]map[string]string
	webCatalogErr  error
)

func loadWebCatalog() (map[string]map[string]string, error) {
	webCatalogOnce.Do(func() {
		data, err := shareWebFiles.ReadFile("web/i18n.json")
		if err != nil {
			webCatalogErr = fmt.Errorf("read web localization catalog: %w", err)
			return
		}
		var catalog embeddedWebCatalog
		if err := json.Unmarshal(data, &catalog); err != nil {
			webCatalogErr = fmt.Errorf("decode web localization catalog: %w", err)
			return
		}
		seen := make(map[string]struct{}, len(catalog.Keys))
		for _, key := range catalog.Keys {
			if key == "" {
				webCatalogErr = fmt.Errorf("web localization catalog contains an empty key")
				return
			}
			if _, exists := seen[key]; exists {
				webCatalogErr = fmt.Errorf("web localization catalog contains duplicate key %q", key)
				return
			}
			seen[key] = struct{}{}
		}
		webCatalogData = make(map[string]map[string]string, len(supportedWebLocales))
		for locale := range supportedWebLocales {
			values, exists := catalog.Locales[locale]
			if !exists || len(values) != len(catalog.Keys) {
				webCatalogErr = fmt.Errorf("web localization catalog locale %q has %d values for %d keys", locale, len(values), len(catalog.Keys))
				return
			}
			messages := make(map[string]string, len(catalog.Keys))
			for index, key := range catalog.Keys {
				messages[key] = values[index]
			}
			webCatalogData[locale] = messages
		}
	})
	return webCatalogData, webCatalogErr
}

func webLocaleAndMessages(r *http.Request) (string, map[string]string, error) {
	catalog, err := loadWebCatalog()
	if err != nil {
		return "", nil, err
	}
	locale := requestWebLocale(r)
	return locale, catalog[locale], nil
}

func requestWebLocale(r *http.Request) string {
	if requested := normalizeWebLocale(r.URL.Query().Get("lang")); requested != "" {
		return requested
	}
	type preference struct {
		locale  string
		quality float64
		index   int
	}
	preferences := make([]preference, 0, 4)
	for index, entry := range strings.Split(r.Header.Get("Accept-Language"), ",") {
		parts := strings.Split(entry, ";")
		locale := normalizeWebLocale(strings.TrimSpace(parts[0]))
		if locale == "" {
			continue
		}
		quality := 1.0
		for _, parameter := range parts[1:] {
			name, value, found := strings.Cut(strings.TrimSpace(parameter), "=")
			if !found || !strings.EqualFold(name, "q") {
				continue
			}
			parsed, parseErr := strconv.ParseFloat(value, 64)
			if parseErr != nil {
				quality = 0
			} else {
				quality = parsed
			}
		}
		if quality > 0 {
			preferences = append(preferences, preference{locale: locale, quality: quality, index: index})
		}
	}
	sort.SliceStable(preferences, func(left, right int) bool {
		if preferences[left].quality == preferences[right].quality {
			return preferences[left].index < preferences[right].index
		}
		return preferences[left].quality > preferences[right].quality
	})
	if len(preferences) > 0 {
		return preferences[0].locale
	}
	return "en"
}

func normalizeWebLocale(value string) string {
	normalized := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(value), "_", "-"))
	if normalized == "" || normalized == "*" {
		return ""
	}
	if normalized == "zh-hant" || strings.HasPrefix(normalized, "zh-hant-") ||
		strings.HasPrefix(normalized, "zh-tw") || strings.HasPrefix(normalized, "zh-hk") || strings.HasPrefix(normalized, "zh-mo") {
		return "zh-Hant"
	}
	if normalized == "zh" || normalized == "zh-hans" || strings.HasPrefix(normalized, "zh-hans-") ||
		strings.HasPrefix(normalized, "zh-cn") || strings.HasPrefix(normalized, "zh-sg") || strings.HasPrefix(normalized, "zh-my") {
		return "zh-Hans"
	}
	base, _, _ := strings.Cut(normalized, "-")
	if _, supported := supportedWebLocales[base]; supported {
		return base
	}
	return ""
}

func localizedWebText(messages map[string]string, key string, replacements ...string) string {
	value := messages[key]
	for index := 0; index+1 < len(replacements); index += 2 {
		value = strings.ReplaceAll(value, "{"+replacements[index]+"}", replacements[index+1])
	}
	return value
}

func explicitLanguagePath(path string, r *http.Request) string {
	requested := normalizeWebLocale(r.URL.Query().Get("lang"))
	if requested == "" {
		return path
	}
	return path + "?lang=" + url.QueryEscape(requested)
}

func setWebLanguageHeaders(headers http.Header, locale string) {
	headers.Set("Content-Language", locale)
	values := make(map[string]struct{})
	for _, value := range strings.Split(headers.Get("Vary"), ",") {
		value = strings.TrimSpace(value)
		if value != "" {
			values[value] = struct{}{}
		}
	}
	values["Accept-Language"] = struct{}{}
	ordered := make([]string, 0, len(values))
	for value := range values {
		ordered = append(ordered, value)
	}
	sort.Strings(ordered)
	headers.Set("Vary", strings.Join(ordered, ", "))
}
