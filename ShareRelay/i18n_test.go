package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestWebLocalizationCatalogRendersEverySupportedLocale(t *testing.T) {
	catalog, err := loadWebCatalog()
	if err != nil {
		t.Fatal(err)
	}
	locales := []string{"en", "de", "fr", "ja", "ko", "zh-Hans", "zh-Hant"}
	for _, locale := range locales {
		t.Run(locale, func(t *testing.T) {
			messages := catalog[locale]
			if len(messages) == 0 {
				t.Fatalf("locale %q has no messages", locale)
			}
			for key, value := range messages {
				optionalEmptyFragment := key == "FILE_ABOUT_SUFFIX" || key == "LARGE_FILE_SUFFIX"
				if strings.TrimSpace(value) == "" && !optionalEmptyFragment {
					t.Fatalf("locale %q has an empty value for %q", locale, key)
				}
			}

			request := httptest.NewRequest(http.MethodGet, "https://share.example/s/missing?lang="+locale, nil)
			response := httptest.NewRecorder()
			(&relayServer{}).renderUnavailablePage(response, request, http.StatusGone)
			body := response.Body.String()
			if response.Code != http.StatusGone {
				t.Fatalf("status = %d", response.Code)
			}
			if response.Header().Get("Content-Language") != locale {
				t.Fatalf("Content-Language = %q", response.Header().Get("Content-Language"))
			}
			if !strings.Contains(strings.ToLower(response.Header().Get("Vary")), "accept-language") {
				t.Fatalf("Vary = %q", response.Header().Get("Vary"))
			}
			if !strings.Contains(body, `lang="`+locale+`"`) ||
				!strings.Contains(body, messages["UNAVAILABLE_TITLE"]) || strings.Contains(body, "{{") {
				t.Fatalf("locale %q did not render a complete localized page", locale)
			}
		})
	}
}

func TestWebLocaleNegotiationAndExplicitLanguagePaths(t *testing.T) {
	tests := []struct {
		name     string
		url      string
		header   string
		expected string
	}{
		{name: "default", url: "https://share.example/s/id", expected: "en"},
		{name: "weighted header", url: "https://share.example/s/id", header: "ja;q=0.4, fr-FR;q=0.9", expected: "fr"},
		{name: "traditional Chinese region", url: "https://share.example/s/id", header: "zh-TW", expected: "zh-Hant"},
		{name: "query overrides header", url: "https://share.example/s/id?lang=de-DE", header: "zh-CN", expected: "de"},
		{name: "unsupported query falls back to header", url: "https://share.example/s/id?lang=es", header: "ko-KR", expected: "ko"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, test.url, nil)
			request.Header.Set("Accept-Language", test.header)
			if locale := requestWebLocale(request); locale != test.expected {
				t.Fatalf("locale = %q, want %q", locale, test.expected)
			}
		})
	}

	request := httptest.NewRequest(http.MethodPost, "https://share.example/s/id?lang=zh-TW", nil)
	if path := explicitLanguagePath("/s/id/auth", request); path != "/s/id/auth?lang=zh-Hant" {
		t.Fatalf("relative localized path = %q", path)
	}
	if path := explicitLanguagePath("https://share.example/s/id", request); path != "https://share.example/s/id?lang=zh-Hant" {
		t.Fatalf("absolute localized path = %q", path)
	}
}
