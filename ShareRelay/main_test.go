package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testAdminToken = "test-admin-token-with-more-than-thirty-two-characters"

func TestEncryptedUploadSupportsHeadRangeSeekRestartExpiryAndSecretBoundary(t *testing.T) {
	fixedNow := time.Date(2026, 9, 2, 8, 0, 0, 0, time.UTC)
	configuration := testConfig(t)
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()

	media := bytes.Repeat([]byte("real-media-window-0123456789"), 900)
	creation := createAndUpload(t, endpoint.URL, server, media, "夜航 / Live.flac", "audio/flac", "", fixedNow.Add(2*time.Hour))
	publicPath := mustPublicPath(t, creation.PublicURL)

	head := performRequest(t, http.MethodHead, endpoint.URL+publicPath, nil, nil)
	if head.StatusCode != http.StatusOK {
		t.Fatalf("HEAD status = %d", head.StatusCode)
	}
	if head.Header.Get("Accept-Ranges") != "bytes" || head.Header.Get("Content-Length") != strconv.Itoa(len(media)) {
		t.Fatalf("unexpected HEAD headers: %#v", head.Header)
	}
	if !strings.Contains(head.Header.Get("Content-Disposition"), "filename*=UTF-8''") {
		t.Fatalf("Unicode filename is missing from Content-Disposition: %q", head.Header.Get("Content-Disposition"))
	}
	if head.Header.Get("Cache-Control") != "private, no-store, max-age=0" {
		t.Fatalf("unsafe cache policy: %q", head.Header.Get("Cache-Control"))
	}
	head.Body.Close()

	rangeResponse := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, map[string]string{"Range": "bytes=177-1308"})
	assertResponseBytes(t, rangeResponse, http.StatusPartialContent, media[177:1309])
	if rangeResponse.Header.Get("Content-Range") != "bytes 177-1308/"+strconv.Itoa(len(media)) {
		t.Fatalf("unexpected Content-Range: %q", rangeResponse.Header.Get("Content-Range"))
	}

	suffixResponse := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, map[string]string{"Range": "bytes=-257"})
	assertResponseBytes(t, suffixResponse, http.StatusPartialContent, media[len(media)-257:])

	invalidRange := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, map[string]string{"Range": "bytes=999999-1000000"})
	if invalidRange.StatusCode != http.StatusRequestedRangeNotSatisfiable || invalidRange.Header.Get("Content-Range") != "bytes */"+strconv.Itoa(len(media)) {
		t.Fatalf("invalid range status=%d content-range=%q", invalidRange.StatusCode, invalidRange.Header.Get("Content-Range"))
	}
	invalidRange.Body.Close()

	publicToken := strings.TrimPrefix(publicPath, "/s/")
	assertStorageOmitsSecrets(t, configuration.dataDirectory, []string{
		testAdminToken,
		creation.UploadToken,
		publicToken,
		"smb://cqNas/private/music.flac",
		"source-password",
	})
	assertChunksAreEncrypted(t, configuration.dataDirectory, creation.ShareID, media)
	metadataPath := filepath.Join(configuration.dataDirectory, "metadata", creation.ShareID+".json")
	legacyData, err := os.ReadFile(metadataPath)
	if err != nil {
		t.Fatal(err)
	}
	var legacyMetadata map[string]any
	if err := json.Unmarshal(legacyData, &legacyMetadata); err != nil {
		t.Fatal(err)
	}
	legacyMetadata["version"] = float64(2)
	delete(legacyMetadata, "permanent")
	legacyData, err = json.Marshal(legacyMetadata)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(metadataPath, legacyData, 0o600); err != nil {
		t.Fatalf("failed to prepare legacy metadata: %v", err)
	}

	// A fresh process reconstructs the hashed public index from disk. The source
	// is no longer involved, so a completed share remains seekable while it is up.
	restarted := mustRelayServer(t, configuration, fixedNow.Add(15*time.Minute))
	restartedEndpoint := httptest.NewServer(restarted.routes())
	defer restartedEndpoint.Close()
	restartedRange := performRequest(t, http.MethodGet, restartedEndpoint.URL+publicPath, nil, map[string]string{"Range": "bytes=4097-8193"})
	assertResponseBytes(t, restartedRange, http.StatusPartialContent, media[4097:8194])

	restarted.now = func() time.Time { return fixedNow.Add(3 * time.Hour) }
	expired := performRequest(t, http.MethodHead, restartedEndpoint.URL+publicPath, nil, nil)
	if expired.StatusCode != http.StatusGone {
		t.Fatalf("expired status = %d", expired.StatusCode)
	}
	expired.Body.Close()
	restarted.cleanupExpired()
	if _, err := os.Stat(filepath.Join(configuration.dataDirectory, "chunks", creation.ShareID)); !os.IsNotExist(err) {
		t.Fatalf("expired chunks still exist: %v", err)
	}
}

func TestPasswordProtectionAndRevocation(t *testing.T) {
	fixedNow := time.Date(2026, 9, 2, 9, 0, 0, 0, time.UTC)
	configuration := testConfig(t)
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()

	media := bytes.Repeat([]byte{0x00, 0x11, 0x22, 0x33, 0x44}, 1_500)
	creation := createAndUpload(t, endpoint.URL, server, media, "测试音频.mp3", "audio/mpeg", "correct horse", fixedNow.Add(time.Hour))
	publicPath := mustPublicPath(t, creation.PublicURL)

	missing := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, nil)
	if missing.StatusCode != http.StatusUnauthorized || !strings.HasPrefix(missing.Header.Get("WWW-Authenticate"), "Basic ") {
		t.Fatalf("missing password status=%d auth=%q", missing.StatusCode, missing.Header.Get("WWW-Authenticate"))
	}
	missing.Body.Close()

	wrongRequest, _ := http.NewRequest(http.MethodGet, endpoint.URL+publicPath, nil)
	wrongRequest.SetBasicAuth("listener", "wrong")
	wrong, err := http.DefaultClient.Do(wrongRequest)
	if err != nil {
		t.Fatal(err)
	}
	if wrong.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong password status = %d", wrong.StatusCode)
	}
	wrong.Body.Close()

	correctRequest, _ := http.NewRequest(http.MethodGet, endpoint.URL+publicPath, nil)
	correctRequest.SetBasicAuth("listener", "correct horse")
	correct, err := http.DefaultClient.Do(correctRequest)
	if err != nil {
		t.Fatal(err)
	}
	assertResponseBytes(t, correct, http.StatusOK, media)

	revoke := performRequest(t, http.MethodDelete, endpoint.URL+"/v1/shares/"+creation.ShareID, nil, map[string]string{
		"Authorization": "Bearer " + creation.UploadToken,
	})
	if revoke.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke status = %d", revoke.StatusCode)
	}
	revoke.Body.Close()

	afterRevoke := performRequest(t, http.MethodHead, endpoint.URL+publicPath, nil, nil)
	if afterRevoke.StatusCode != http.StatusGone {
		t.Fatalf("revoked share status = %d", afterRevoke.StatusCode)
	}
	afterRevoke.Body.Close()
	if _, err := os.Stat(filepath.Join(configuration.dataDirectory, "chunks", creation.ShareID)); !os.IsNotExist(err) {
		t.Fatalf("revoked chunks still exist: %v", err)
	}

	adminCreation := createAndUpload(
		t,
		endpoint.URL,
		server,
		[]byte("operator-cleanup"),
		"cleanup.ogg",
		"audio/ogg",
		"",
		fixedNow.Add(time.Hour),
	)
	adminRevoke := performRequest(
		t,
		http.MethodDelete,
		endpoint.URL+"/v1/shares/"+adminCreation.ShareID,
		nil,
		map[string]string{"Authorization": "Bearer " + testAdminToken},
	)
	if adminRevoke.StatusCode != http.StatusNoContent {
		t.Fatalf("administrator revoke status = %d", adminRevoke.StatusCode)
	}
	adminRevoke.Body.Close()
}

func TestPermanentShareSurvivesRestartAndFarFutureUntilRevoked(t *testing.T) {
	fixedNow := time.Date(2026, 9, 3, 7, 0, 0, 0, time.UTC)
	configuration := testConfig(t)
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())

	media := bytes.Repeat([]byte("permanent-encrypted-media"), 2_048)
	creation := createAndUploadWithRequest(t, endpoint.URL, server, media, createUploadRequest{
		FileName: "永久分享.flac", ContentType: "audio/flac", Size: int64(len(media)),
		LinkType: "permanent",
	})
	endpoint.Close()
	if !creation.Permanent || creation.ExpiresAt != nil || creation.AccessCode != "" {
		t.Fatalf("unexpected permanent response: %#v", creation)
	}
	publicPath := mustPublicPath(t, creation.PublicURL)
	publicToken := strings.TrimPrefix(publicPath, "/s/")
	if !validOpaqueID(publicToken) || validShortCode(publicToken) {
		t.Fatalf("permanent link did not use a high-entropy public token: %q", publicToken)
	}

	restarted := mustRelayServer(t, configuration, fixedNow.AddDate(100, 0, 0))
	restartedEndpoint := httptest.NewServer(restarted.routes())
	defer restartedEndpoint.Close()
	farFuture := performRequest(t, http.MethodGet, restartedEndpoint.URL+publicPath, nil, nil)
	assertResponseBytes(t, farFuture, http.StatusOK, media)
	page := performRequest(t, http.MethodGet, restartedEndpoint.URL+publicPath, nil, map[string]string{
		"Accept": "text/html", "Sec-Fetch-Mode": "navigate",
	})
	pageBody, _ := io.ReadAll(page.Body)
	page.Body.Close()
	if page.StatusCode != http.StatusOK || !strings.Contains(string(pageBody), "永久有效（直到分享者撤销）") {
		t.Fatalf("permanent page status=%d body=%s", page.StatusCode, pageBody)
	}

	revoke := performRequest(t, http.MethodDelete, restartedEndpoint.URL+"/v1/shares/"+creation.ShareID, nil, map[string]string{
		"Authorization": "Bearer " + creation.UploadToken,
	})
	if revoke.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke permanent status = %d", revoke.StatusCode)
	}
	revoke.Body.Close()
	afterRevoke := performRequest(t, http.MethodHead, restartedEndpoint.URL+publicPath, nil, nil)
	if afterRevoke.StatusCode != http.StatusGone {
		t.Fatalf("revoked permanent share status = %d", afterRevoke.StatusCode)
	}
	afterRevoke.Body.Close()
	if _, err := os.Stat(filepath.Join(configuration.dataDirectory, "chunks", creation.ShareID)); !os.IsNotExist(err) {
		t.Fatalf("revoked permanent chunks still exist: %v", err)
	}
}

func TestBrowserPagePermissionsAndOneTimeImport(t *testing.T) {
	fixedNow := time.Date(2026, 9, 2, 9, 30, 0, 0, time.UTC)
	configuration := testConfig(t)
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()

	media := bytes.Repeat([]byte("designed-share-media"), 2_048)
	allowPlayback, allowDownload, allowImport := true, false, true
	creation := createAndUploadWithRequest(t, endpoint.URL, server, media, createUploadRequest{
		FileName:        "陈默寻 - 夜航西飞.flac",
		ContentType:     "audio/flac",
		Size:            int64(len(media)),
		ExpiresAt:       fixedNow.Add(time.Hour).Format(time.RFC3339),
		Title:           "夜航西飞 <Live>",
		Artist:          "陈默寻",
		Album:           "潮汐纪年",
		AudioFormat:     "FLAC",
		Quality:         "24bit/96kHz",
		DurationSeconds: 242,
		AllowPlayback:   &allowPlayback,
		AllowDownload:   &allowDownload,
		AllowImport:     &allowImport,
	})
	publicPath := mustPublicPath(t, creation.PublicURL)

	page := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, map[string]string{
		"Accept":         "text/html",
		"Sec-Fetch-Mode": "navigate",
	})
	pageBody, _ := io.ReadAll(page.Body)
	page.Body.Close()
	if page.StatusCode != http.StatusOK || !strings.Contains(page.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("page status=%d content-type=%q", page.StatusCode, page.Header.Get("Content-Type"))
	}
	pageHTML := string(pageBody)
	for _, expected := range []string{
		"夜航西飞 &lt;Live&gt;",
		"陈默寻 · 《潮汐纪年》",
		"data-download hidden",
		`data-media-url="` + publicPath + `/media"`,
		`data-download-url="` + publicPath + `/download"`,
		`data-import-url="` + publicPath + `/import"`,
		`data-file-size="` + strconv.FormatInt(int64(len(media)), 10) + `"`,
	} {
		if !strings.Contains(pageHTML, expected) {
			t.Fatalf("share page missing %q", expected)
		}
	}
	if strings.Contains(pageHTML, "<audio src=") {
		t.Fatal("share page eagerly loads audio")
	}

	icon := performRequest(t, http.MethodGet, endpoint.URL+"/icons/play.svg", nil, nil)
	iconBody, _ := io.ReadAll(icon.Body)
	icon.Body.Close()
	if icon.StatusCode != http.StatusOK || icon.Header.Get("Content-Type") != "image/svg+xml" ||
		!bytes.Contains(iconBody, []byte("<svg")) {
		t.Fatalf("icon status=%d content-type=%q", icon.StatusCode, icon.Header.Get("Content-Type"))
	}
	unknownIcon := performRequest(t, http.MethodGet, endpoint.URL+"/icons/LICENSE.txt", nil, nil)
	if unknownIcon.StatusCode != http.StatusNotFound {
		t.Fatalf("unexpected icon asset status = %d", unknownIcon.StatusCode)
	}
	unknownIcon.Body.Close()

	playable := performRequest(t, http.MethodGet, endpoint.URL+publicPath+"/media", nil, map[string]string{
		"Range": "bytes=20-79",
	})
	assertResponseBytes(t, playable, http.StatusPartialContent, media[20:80])

	forbiddenDownload := performRequest(t, http.MethodGet, endpoint.URL+publicPath+"/download", nil, nil)
	if forbiddenDownload.StatusCode != http.StatusForbidden {
		t.Fatalf("download status = %d", forbiddenDownload.StatusCode)
	}
	forbiddenDownload.Body.Close()

	ticketResponse := performRequest(t, http.MethodPost, endpoint.URL+publicPath+"/import", nil, map[string]string{
		"Accept": "application/json",
	})
	if ticketResponse.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(ticketResponse.Body)
		t.Fatalf("ticket status=%d body=%s", ticketResponse.StatusCode, body)
	}
	var ticket struct {
		ImportURL string `json:"importURL"`
	}
	if err := json.NewDecoder(ticketResponse.Body).Decode(&ticket); err != nil {
		t.Fatal(err)
	}
	ticketResponse.Body.Close()
	importPath := mustImportPath(t, ticket.ImportURL)
	imported := performRequest(t, http.MethodGet, endpoint.URL+importPath, nil, nil)
	if !strings.HasPrefix(imported.Header.Get("Content-Disposition"), "attachment;") {
		t.Fatalf("import disposition = %q", imported.Header.Get("Content-Disposition"))
	}
	assertResponseBytes(t, imported, http.StatusOK, media)
	reused := performRequest(t, http.MethodGet, endpoint.URL+importPath, nil, nil)
	if reused.StatusCode != http.StatusGone {
		t.Fatalf("reused ticket status = %d", reused.StatusCode)
	}
	reused.Body.Close()
}

func TestPasswordBrowserSessionDoesNotDiscloseMetadata(t *testing.T) {
	fixedNow := time.Date(2026, 9, 2, 9, 45, 0, 0, time.UTC)
	configuration := testConfig(t)
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()

	media := bytes.Repeat([]byte("private-browser-media"), 1_024)
	creation := createAndUploadWithRequest(t, endpoint.URL, server, media, createUploadRequest{
		FileName:    "私密歌曲.mp3",
		ContentType: "audio/mpeg",
		Size:        int64(len(media)),
		ExpiresAt:   fixedNow.Add(time.Hour).Format(time.RFC3339),
		Password:    "海屋2026",
		Title:       "不可提前泄露的标题",
	})
	publicPath := mustPublicPath(t, creation.PublicURL)

	locked := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, map[string]string{
		"Accept":         "text/html",
		"Sec-Fetch-Mode": "navigate",
	})
	lockedBody, _ := io.ReadAll(locked.Body)
	locked.Body.Close()
	if locked.StatusCode != http.StatusOK || strings.Contains(string(lockedBody), "不可提前泄露") || strings.Contains(string(lockedBody), "私密歌曲") {
		t.Fatalf("locked page leaked metadata or failed: status=%d", locked.StatusCode)
	}
	if locked.Header.Get("WWW-Authenticate") != "" {
		t.Fatal("browser password page triggered Basic authentication")
	}

	wrong := performRequest(t, http.MethodPost, endpoint.URL+publicPath+"/auth", []byte("password=wrong"), map[string]string{
		"Accept":       "application/json",
		"Content-Type": "application/x-www-form-urlencoded",
	})
	if wrong.StatusCode != http.StatusUnauthorized || wrong.Header.Get("WWW-Authenticate") != "" {
		t.Fatalf("wrong password status=%d auth=%q", wrong.StatusCode, wrong.Header.Get("WWW-Authenticate"))
	}
	wrong.Body.Close()

	correctBody := url.Values{"password": {"海屋2026"}}.Encode()
	unlocked := performRequest(t, http.MethodPost, endpoint.URL+publicPath+"/auth", []byte(correctBody), map[string]string{
		"Accept":       "application/json",
		"Content-Type": "application/x-www-form-urlencoded",
	})
	if unlocked.StatusCode != http.StatusOK {
		t.Fatalf("unlock status = %d", unlocked.StatusCode)
	}
	cookie := unlocked.Header.Get("Set-Cookie")
	unlocked.Body.Close()
	if !strings.Contains(cookie, "HttpOnly") || !strings.Contains(cookie, "SameSite=Strict") || strings.Contains(cookie, "海屋2026") {
		t.Fatalf("unsafe session cookie %q", cookie)
	}
	session := strings.SplitN(cookie, ";", 2)[0]
	privatePage := performRequest(t, http.MethodGet, endpoint.URL+publicPath, nil, map[string]string{
		"Accept":         "text/html",
		"Sec-Fetch-Mode": "navigate",
		"Cookie":         session,
	})
	privateBody, _ := io.ReadAll(privatePage.Body)
	privatePage.Body.Close()
	if privatePage.StatusCode != http.StatusOK || !strings.Contains(string(privateBody), "不可提前泄露的标题") {
		t.Fatalf("private page status=%d", privatePage.StatusCode)
	}
	privateMedia := performRequest(t, http.MethodGet, endpoint.URL+publicPath+"/media", nil, map[string]string{
		"Cookie": session,
	})
	assertResponseBytes(t, privateMedia, http.StatusOK, media)
}

func TestShortCodesUseAtomicCollisionRetriesStrictTTLAndScopedFailureLimits(t *testing.T) {
	fixedNow := time.Date(2026, 9, 3, 6, 0, 0, 0, time.UTC)
	configuration := testConfig(t)
	configuration.shortCodeRequestsPerMinute = 20
	configuration.shortCodeFailuresPerWindow = 2
	server := mustRelayServer(t, configuration, fixedNow)
	codes := []string{"123456", "123456", "654321"}
	server.shortCodeGenerator = func(length int) (string, error) {
		if length != 6 || len(codes) == 0 {
			t.Fatalf("unexpected short-code request length=%d remaining=%d", length, len(codes))
		}
		code := codes[0]
		codes = codes[1:]
		return code, nil
	}
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()

	first := createAndUploadWithRequest(t, endpoint.URL, server, []byte("first-short-share"), createUploadRequest{
		FileName: "first.mp3", ContentType: "audio/mpeg", Size: int64(len("first-short-share")),
		ExpiresAt: fixedNow.Add(time.Hour).Format(time.RFC3339), Password: "independent-password",
		LinkType: "short", ShortCodeLength: 6,
	})
	second := createAndUploadWithRequest(t, endpoint.URL, server, []byte("second-short-share"), createUploadRequest{
		FileName: "second.mp3", ContentType: "audio/mpeg", Size: int64(len("second-short-share")),
		ExpiresAt: fixedNow.Add(2 * time.Hour).Format(time.RFC3339), LinkType: "short", ShortCodeLength: 6,
	})
	if first.AccessCode != "123456" || second.AccessCode != "654321" {
		t.Fatalf("collision retry produced codes %q and %q", first.AccessCode, second.AccessCode)
	}
	if mustPublicPath(t, first.PublicURL) != "/s/123456" || mustPublicPath(t, second.PublicURL) != "/s/654321" {
		t.Fatalf("short-code URLs do not match their access codes")
	}
	if !validOpaqueID(first.ShareID) || !validOpaqueID(first.UploadToken) || first.ShareID == first.AccessCode || first.UploadToken == first.AccessCode {
		t.Fatal("short code replaced an internal high-entropy identifier")
	}
	assertStorageOmitsSecrets(t, configuration.dataDirectory, []string{"123456", "654321", "independent-password"})

	tooLongBody, _ := json.Marshal(createUploadRequest{
		FileName: "too-long.mp3", ContentType: "audio/mpeg", Size: 8,
		ExpiresAt: fixedNow.Add(24*time.Hour + time.Second).Format(time.RFC3339),
		LinkType:  "short", ShortCodeLength: 6,
	})
	tooLong := performRequest(t, http.MethodPost, endpoint.URL+"/v1/uploads", tooLongBody, map[string]string{
		"Authorization": "Bearer " + testAdminToken,
		"Content-Type":  "application/json",
	})
	if tooLong.StatusCode != http.StatusBadRequest {
		t.Fatalf("short code accepted overlong TTL: %d", tooLong.StatusCode)
	}
	tooLong.Body.Close()

	for attempt, expected := range []int{http.StatusGone, http.StatusGone, http.StatusTooManyRequests} {
		response := performRequest(t, http.MethodHead, endpoint.URL+"/s/000000", nil, nil)
		if response.StatusCode != expected {
			t.Fatalf("failure attempt %d status=%d want=%d", attempt+1, response.StatusCode, expected)
		}
		response.Body.Close()
	}

	server.now = func() time.Time { return fixedNow.Add(90 * time.Minute) }
	expiredShort := performRequest(t, http.MethodHead, endpoint.URL+mustPublicPath(t, first.PublicURL), nil, nil)
	if expiredShort.StatusCode != http.StatusGone {
		t.Fatalf("expired short code status=%d", expiredShort.StatusCode)
	}
	expiredShort.Body.Close()
}

func TestShortCodePeerLimitCannotBeBypassedByRotatingCodes(t *testing.T) {
	fixedNow := time.Date(2026, 9, 3, 8, 0, 0, 0, time.UTC)
	configuration := testConfig(t)
	configuration.shortCodePeerRequestsPerMinute = 2
	configuration.shortCodeRequestsPerMinute = 20
	configuration.shortCodeFailuresPerWindow = 20
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()

	for index, expected := range []int{http.StatusGone, http.StatusGone, http.StatusTooManyRequests} {
		code := fmt.Sprintf("%06d", index+1)
		response := performRequest(t, http.MethodHead, endpoint.URL+"/s/"+code, nil, nil)
		if response.StatusCode != expected {
			t.Fatalf("rotating code attempt %d status=%d want=%d", index+1, response.StatusCode, expected)
		}
		response.Body.Close()
	}
}

func TestPublicRateLimitAndConfigurationGuards(t *testing.T) {
	configuration := testConfig(t)
	configuration.publicRequestsPerMinute = 1
	fixedNow := time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)
	server := mustRelayServer(t, configuration, fixedNow)
	endpoint := httptest.NewServer(server.routes())
	defer endpoint.Close()
	creation := createAndUpload(t, endpoint.URL, server, []byte("1234567890"), "small.aac", "audio/aac", "", fixedNow.Add(time.Hour))
	publicPath := mustPublicPath(t, creation.PublicURL)

	first := performRequest(t, http.MethodHead, endpoint.URL+publicPath, nil, nil)
	first.Body.Close()
	second := performRequest(t, http.MethodHead, endpoint.URL+publicPath, nil, nil)
	if first.StatusCode != http.StatusOK || second.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("rate statuses = %d, %d", first.StatusCode, second.StatusCode)
	}
	second.Body.Close()

	for _, invalid := range []string{
		"http://share.example",
		"https://user:secret@share.example",
		"https://share.example/path?token=secret",
		"https://localhost",
		"https://nas",
		"https://music.local",
		"https://127.0.0.1",
		"https://10.0.0.8",
		"https://100.64.0.1",
		"https://192.168.50.23",
		"https://198.18.0.1",
		"https://192.0.2.1",
		"https://198.51.100.1",
		"https://203.0.113.1",
		"https://0x7f000001",
		"https://0x7f.0.0.1",
		"https://[::1]",
		"https://[fd00::1]",
		"https://[2001:db8::1]",
	} {
		if err := validatePublicBaseURL(invalid, false); err == nil {
			t.Fatalf("accepted invalid public base URL %q", invalid)
		}
	}
	for _, valid := range []string{
		"https://share.example",
		"https://8.8.8.8",
		"https://[2606:4700:4700::1111]",
	} {
		if err := validatePublicBaseURL(valid, false); err != nil {
			t.Fatalf("rejected valid public base URL %q: %v", valid, err)
		}
	}
}

func TestStartupRejectsUnsafePersistedMetadata(t *testing.T) {
	configuration := testConfig(t)
	_ = mustRelayServer(t, configuration, time.Now())
	unsafe := shareMetadata{
		Version:         1,
		ID:              "../../metadata",
		PublicTokenHash: strings.Repeat("a", 64),
		ControlHash:     strings.Repeat("b", 64),
	}
	data, err := json.Marshal(unsafe)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(configuration.dataDirectory, "metadata", "unsafe.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newRelayServer(configuration); err == nil {
		t.Fatal("relay accepted persisted path traversal metadata")
	}
}

func testConfig(t *testing.T) config {
	t.Helper()
	return config{
		listenAddress:                  ":0",
		dataDirectory:                  t.TempDir(),
		publicBaseURL:                  "https://share.example",
		adminToken:                     testAdminToken,
		masterKey:                      bytes.Repeat([]byte{0x42}, 32),
		chunkSize:                      256 * 1024,
		maximumFileSize:                64 * 1024 * 1024,
		maximumTTL:                     24 * time.Hour,
		uploadTTL:                      time.Hour,
		publicRequestsPerMinute:        600,
		shortCodePeerRequestsPerMinute: 60,
		shortCodeRequestsPerMinute:     60,
		shortCodeFailuresPerWindow:     5,
		shortCodeFailureWindow:         10 * time.Minute,
		shortCodeMaximumTTL:            24 * time.Hour,
		maximumPublicStreams:           8,
		maximumUploads:                 2,
	}
}

func mustRelayServer(t *testing.T, configuration config, now time.Time) *relayServer {
	t.Helper()
	server, err := newRelayServer(configuration)
	if err != nil {
		t.Fatal(err)
	}
	server.now = func() time.Time { return now }
	return server
}

func createAndUpload(
	t *testing.T,
	baseURL string,
	server *relayServer,
	media []byte,
	fileName string,
	contentType string,
	password string,
	expiresAt time.Time,
) createUploadResponse {
	t.Helper()
	return createAndUploadWithRequest(t, baseURL, server, media, createUploadRequest{
		FileName: fileName, ContentType: contentType, Size: int64(len(media)),
		ExpiresAt: expiresAt.Format(time.RFC3339), Password: password,
	})
}

func createAndUploadWithRequest(
	t *testing.T,
	baseURL string,
	server *relayServer,
	media []byte,
	request createUploadRequest,
) createUploadResponse {
	t.Helper()
	requestBody, _ := json.Marshal(request)
	response := performRequest(t, http.MethodPost, baseURL+"/v1/uploads", requestBody, map[string]string{
		"Authorization": "Bearer " + testAdminToken,
		"Content-Type":  "application/json",
	})
	if response.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("create status=%d body=%s", response.StatusCode, body)
	}
	var creation createUploadResponse
	if err := json.NewDecoder(response.Body).Decode(&creation); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()

	for index, offset := int64(0), int64(0); offset < int64(len(media)); index, offset = index+1, offset+creation.ChunkSize {
		end := min64(offset+creation.ChunkSize, int64(len(media)))
		chunk := media[offset:end]
		upload := performRequest(t, http.MethodPut, baseURL+"/v1/uploads/"+creation.ShareID+"/chunks/"+strconv.FormatInt(index, 10), chunk, map[string]string{
			"Authorization": "Bearer " + creation.UploadToken,
			"Content-Type":  "application/octet-stream",
			"Content-Range": "bytes " + strconv.FormatInt(offset, 10) + "-" + strconv.FormatInt(end-1, 10) + "/" + strconv.Itoa(len(media)),
		})
		if upload.StatusCode != http.StatusNoContent {
			body, _ := io.ReadAll(upload.Body)
			t.Fatalf("upload chunk %d status=%d body=%s", index, upload.StatusCode, body)
		}
		upload.Body.Close()
	}

	complete := performRequest(t, http.MethodPost, baseURL+"/v1/uploads/"+creation.ShareID+"/complete", nil, map[string]string{
		"Authorization": "Bearer " + creation.UploadToken,
	})
	if complete.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(complete.Body)
		t.Fatalf("complete status=%d body=%s", complete.StatusCode, body)
	}
	var completion completeUploadResponse
	if err := json.NewDecoder(complete.Body).Decode(&completion); err != nil {
		t.Fatal(err)
	}
	complete.Body.Close()
	sameExpiration := creation.ExpiresAt == nil && completion.ExpiresAt == nil ||
		creation.ExpiresAt != nil && completion.ExpiresAt != nil && *creation.ExpiresAt == *completion.ExpiresAt
	if completion.ShareID != creation.ShareID || completion.Permanent != creation.Permanent || !sameExpiration {
		t.Fatalf("completion lifetime does not match creation: create=%#v complete=%#v", creation, completion)
	}
	return creation
}

func performRequest(t *testing.T, method, rawURL string, body []byte, headers map[string]string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(method, rawURL, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func assertResponseBytes(t *testing.T, response *http.Response, expectedStatus int, expected []byte) {
	t.Helper()
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != expectedStatus || !bytes.Equal(body, expected) {
		t.Fatalf("status=%d length=%d want status=%d length=%d", response.StatusCode, len(body), expectedStatus, len(expected))
	}
}

func mustPublicPath(t *testing.T, raw string) string {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil || !strings.HasPrefix(parsed.Path, "/s/") {
		t.Fatalf("invalid public URL %q", raw)
	}
	return parsed.Path
}

func mustImportPath(t *testing.T, raw string) string {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil || !strings.HasPrefix(parsed.Path, "/i/") {
		t.Fatalf("invalid import URL %q", raw)
	}
	return parsed.Path
}

func assertStorageOmitsSecrets(t *testing.T, root string, secrets []string) {
	t.Helper()
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		for _, secret := range secrets {
			if bytes.Contains(data, []byte(secret)) {
				t.Fatalf("secret persisted in %s", filepath.Base(path))
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func assertChunksAreEncrypted(t *testing.T, root, shareID string, plaintext []byte) {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(root, "chunks", shareID))
	if err != nil {
		t.Fatal(err)
	}
	var stored []byte
	for _, entry := range entries {
		data, err := os.ReadFile(filepath.Join(root, "chunks", shareID, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		stored = append(stored, data...)
	}
	if bytes.Contains(stored, plaintext[:min64(128, int64(len(plaintext)))]) {
		t.Fatal("plaintext media window is visible in encrypted chunk storage")
	}
}
