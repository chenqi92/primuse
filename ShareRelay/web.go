package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
)

const (
	shareSessionDuration = 30 * time.Minute
	importTicketDuration = 10 * time.Minute
	passwordAttempts     = 5
	maximumFormBytes     = int64(2 * 1024)
)

//go:embed web/* web/icons/*.svg
var shareWebFiles embed.FS

var webIconNames = map[string]struct{}{
	"link.svg":       {},
	"lock.svg":       {},
	"more-horiz.svg": {},
	"pause.svg":      {},
	"play.svg":       {},
	"qr-code.svg":    {},
	"share-ios.svg":  {},
	"sound-high.svg": {},
	"xmark.svg":      {},
}

type importTicket struct {
	Version   int       `json:"version"`
	ShareID   string    `json:"shareID"`
	ExpiresAt time.Time `json:"expiresAt"`
	UsedAt    time.Time `json:"usedAt,omitempty"`
}

func boolPointerOrDefault(value *bool, fallback bool) *bool {
	if value != nil {
		copy := *value
		return &copy
	}
	copy := fallback
	return &copy
}

func metadataPermission(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}
	return *value
}

func sanitizeDisplayText(value string, maximumRunes int) string {
	value = strings.TrimSpace(value)
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, value)
	runes := []rune(value)
	if len(runes) > maximumRunes {
		value = string(runes[:maximumRunes])
	}
	return value
}

func prefersHTML(r *http.Request) bool {
	if r.Method != http.MethodGet || r.Header.Get("Range") != "" {
		return false
	}
	return r.Header.Get("Sec-Fetch-Mode") == "navigate" ||
		strings.Contains(strings.ToLower(r.Header.Get("Accept")), "text/html")
}

func (s *relayServer) handleWebAsset(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	allowed := name == "share.css" || name == "share.js" || name == "fallback-cover.webp"
	if strings.HasPrefix(name, "icons/") {
		_, allowed = webIconNames[strings.TrimPrefix(name, "icons/")]
	}
	if !allowed {
		http.NotFound(w, r)
		return
	}
	data, err := shareWebFiles.ReadFile("web/" + name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	contentType := mime.TypeByExtension(filepath.Ext(name))
	if name == "share.js" {
		contentType = "text/javascript; charset=utf-8"
	} else if strings.HasSuffix(name, ".svg") {
		contentType = "image/svg+xml"
	}
	if contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Header().Set("ETag", `"`+tokenHash(string(data))+`"`)
	if r.Header.Get("If-None-Match") == w.Header().Get("ETag") {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	http.ServeContent(w, r, name, time.Time{}, bytes.NewReader(data))
}

func (s *relayServer) handleSharePage(w http.ResponseWriter, r *http.Request) {
	if !s.allowPublicRequest(r) {
		w.Header().Set("Retry-After", "60")
		s.renderUnavailablePage(w, http.StatusTooManyRequests)
		return
	}
	metadata := s.metadataByPublicToken(r.PathValue("token"))
	if metadata == nil {
		s.recordShortCodeFailure(r, r.PathValue("token"))
		s.renderUnavailablePage(w, http.StatusGone)
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.RLock()
	defer shareLock.RUnlock()
	if !s.shareIsActive(metadata) {
		s.renderUnavailablePage(w, http.StatusGone)
		return
	}
	if metadata.PasswordHash != "" && !verifyPassword(metadata, r) &&
		!s.verifyShareSession(metadata, r.PathValue("token"), r) {
		s.renderPasswordPage(w, r.PathValue("token"), http.StatusOK, "", false, 0)
		return
	}
	s.renderSharePage(w, r.PathValue("token"), metadata)
}

func (s *relayServer) shareIsActive(metadata *shareMetadata) bool {
	return metadata != nil && metadata.complete() && !metadata.revoked() &&
		metadata.activeAt(s.now()) && metadata.DataDeletedAt.IsZero()
}

func (s *relayServer) renderSharePage(w http.ResponseWriter, publicToken string, metadata *shareMetadata) {
	title := metadata.Title
	if title == "" {
		title = strings.TrimSuffix(metadata.FileName, filepath.Ext(metadata.FileName))
	}
	if title == "" {
		title = "未命名音乐"
	}
	artistAlbum := metadata.Artist
	if metadata.Album != "" {
		album := "《" + metadata.Album + "》"
		if artistAlbum == "" {
			artistAlbum = album
		} else {
			artistAlbum += " · " + album
		}
	}
	if artistAlbum == "" {
		artistAlbum = "来自 Primuse 的音乐分享"
	}
	format := strings.ToUpper(metadata.AudioFormat)
	if format == "" {
		format = strings.TrimPrefix(strings.ToUpper(filepath.Ext(metadata.FileName)), ".")
	}
	technicalParts := make([]string, 0, 3)
	if format != "" {
		technicalParts = append(technicalParts, format)
	}
	if metadata.Quality != "" {
		technicalParts = append(technicalParts, metadata.Quality)
	}
	size := humanFileSize(metadata.Size)
	technicalParts = append(technicalParts, size)

	playback := metadataPermission(metadata.AllowPlayback, true)
	download := metadataPermission(metadata.AllowDownload, true)
	allowImport := metadataPermission(metadata.AllowImport, true)
	noteParts := make([]string, 0, 2)
	if !download {
		noteParts = append(noteParts, "分享者未开放下载")
	}
	if allowImport {
		noteParts = append(noteParts, "导入使用一次性短期凭证，不含密码")
	}
	expiresISO := ""
	expiresLabel := "永久有效（直到分享者撤销）"
	if metadata.ExpiresAt != nil {
		expiresISO = metadata.ExpiresAt.UTC().Format(time.RFC3339)
		expiresLabel = "有效至 " + metadata.ExpiresAt.UTC().Format("2006-01-02 15:04 UTC")
	}
	base := s.configuration.publicBaseURL + "/s/" + publicToken
	values := map[string]string{
		"TITLE":                     title,
		"SOCIAL_DESCRIPTION":        artistAlbum + " · " + strings.Join(technicalParts, " · "),
		"COVER_URL":                 s.configuration.publicBaseURL + "/fallback-cover.webp?v=20260903.3",
		"COVER_PATH":                "/fallback-cover.webp?v=20260903.3",
		"CANONICAL_URL":             base,
		"MEDIA_PATH":                "/s/" + publicToken + "/media",
		"DOWNLOAD_PATH":             "/s/" + publicToken + "/download",
		"IMPORT_PATH":               "/s/" + publicToken + "/import",
		"FILE_NAME":                 metadata.FileName,
		"FILE_SIZE_BYTES":           strconv.FormatInt(metadata.Size, 10),
		"SIZE":                      size,
		"ACCESS_LABEL":              map[bool]string{true: "已通过密码验证", false: "持有链接即可访问"}[metadata.PasswordHash != ""],
		"EXPIRES_ISO":               expiresISO,
		"EXPIRES_LABEL":             expiresLabel,
		"SESSION_HIDDEN":            map[bool]string{true: "", false: "hidden"}[metadata.PasswordHash != ""],
		"ARTIST_ALBUM":              artistAlbum,
		"FORMAT":                    format,
		"QUALITY":                   metadata.Quality,
		"FORMAT_HIDDEN":             hiddenUnless(format != ""),
		"QUALITY_HIDDEN":            hiddenUnless(metadata.Quality != ""),
		"PLAYBACK_HIDDEN":           hiddenUnless(playback),
		"IMPORT_HIDDEN":             hiddenUnless(allowImport),
		"DOWNLOAD_HIDDEN":           hiddenUnless(download),
		"PLAYBACK_PERMISSION_CLASS": deniedUnless(playback),
		"DOWNLOAD_PERMISSION_CLASS": deniedUnless(download),
		"IMPORT_PERMISSION_CLASS":   deniedUnless(allowImport),
		"PERMISSION_NOTE":           strings.Join(noteParts, " · "),
	}
	s.writeTemplate(w, "share.html", http.StatusOK, values)
}

func hiddenUnless(visible bool) string {
	if visible {
		return ""
	}
	return "hidden"
}

func deniedUnless(allowed bool) string {
	if allowed {
		return "allowed"
	}
	return "denied"
}

func humanFileSize(size int64) string {
	units := []string{"B", "KB", "MB", "GB", "TB"}
	value := float64(size)
	unit := 0
	for value >= 1024 && unit < len(units)-1 {
		value /= 1024
		unit++
	}
	if unit == 0 {
		return fmt.Sprintf("%d %s", size, units[unit])
	}
	return fmt.Sprintf("%.1f %s", value, units[unit])
}

func (s *relayServer) renderPasswordPage(
	w http.ResponseWriter,
	publicToken string,
	status int,
	message string,
	isError bool,
	retryAfter int,
) {
	values := map[string]string{
		"AUTH_PATH":     "/s/" + publicToken + "/auth",
		"RETRY_AFTER":   map[bool]string{true: strconv.Itoa(retryAfter), false: ""}[retryAfter > 0],
		"ERROR_CLASS":   map[bool]string{true: "error", false: ""}[isError],
		"MESSAGE_CLASS": map[bool]string{true: "error", false: ""}[isError],
		"MESSAGE":       message,
	}
	s.writeTemplate(w, "password.html", status, values)
}

func (s *relayServer) renderUnavailablePage(w http.ResponseWriter, status int) {
	s.writeTemplate(w, "unavailable.html", status, nil)
}

func (s *relayServer) writeTemplate(w http.ResponseWriter, name string, status int, values map[string]string) {
	data, err := shareWebFiles.ReadFile("web/" + name)
	if err != nil {
		writeProblem(w, http.StatusInternalServerError, "template_unavailable")
		return
	}
	page := string(data)
	for key, value := range values {
		page = strings.ReplaceAll(page, "{{"+key+"}}", html.EscapeString(value))
	}
	if strings.Contains(page, "{{") {
		writeProblem(w, http.StatusInternalServerError, "template_invalid")
		return
	}
	w.Header().Set("Cache-Control", "private, no-store, max-age=0")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self' data:; media-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
	w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
	w.Header().Set("Content-Length", strconv.Itoa(len(page)))
	w.WriteHeader(status)
	_, _ = io.WriteString(w, page)
}

func (s *relayServer) handleShareAuthentication(w http.ResponseWriter, r *http.Request) {
	publicToken := r.PathValue("token")
	if !s.allowPublicRequest(r) {
		s.authenticationFailure(w, r, publicToken, http.StatusTooManyRequests, "rate_limited", 60)
		return
	}
	metadata := s.metadataByPublicToken(publicToken)
	if metadata == nil {
		s.recordShortCodeFailure(r, publicToken)
		s.authenticationFailure(w, r, publicToken, http.StatusGone, "unavailable", 0)
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.RLock()
	defer shareLock.RUnlock()
	if !s.shareIsActive(metadata) {
		s.authenticationFailure(w, r, publicToken, http.StatusGone, "unavailable", 0)
		return
	}
	if !sameOriginRequest(r, s.configuration.publicBaseURL) {
		s.authenticationFailure(w, r, publicToken, http.StatusForbidden, "invalid_origin", 0)
		return
	}
	password, err := passwordFromForm(w, r)
	if err != nil {
		s.authenticationFailure(w, r, publicToken, http.StatusBadRequest, "invalid_password", 0)
		return
	}
	if metadata.PasswordHash != "" && !s.allowPasswordAttempt(r, metadata) {
		s.authenticationFailure(w, r, publicToken, http.StatusTooManyRequests, "rate_limited", 60)
		return
	}
	if metadata.PasswordHash != "" && !verifyPasswordValue(metadata, password) {
		s.recordShortCodeFailure(r, publicToken)
		s.authenticationFailure(w, r, publicToken, http.StatusUnauthorized, "password_required", 0)
		return
	}
	s.clearShortCodeFailures(r, publicToken)
	if metadata.PasswordHash != "" {
		http.SetCookie(w, s.shareSessionCookie(metadata, publicToken))
	}
	if strings.Contains(strings.ToLower(r.Header.Get("Accept")), "application/json") {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	w.Header().Set("Location", s.configuration.publicBaseURL+"/s/"+publicToken)
	w.WriteHeader(http.StatusSeeOther)
}

func (s *relayServer) authenticationFailure(
	w http.ResponseWriter,
	r *http.Request,
	publicToken string,
	status int,
	code string,
	retryAfter int,
) {
	if retryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	}
	if strings.Contains(strings.ToLower(r.Header.Get("Accept")), "application/json") {
		writeProblem(w, status, code)
		return
	}
	if status == http.StatusGone {
		s.renderUnavailablePage(w, http.StatusGone)
		return
	}
	message := "密码不正确，请检查后重试。"
	if status == http.StatusTooManyRequests {
		message = "尝试次数过多，请稍后重试。"
	}
	s.renderPasswordPage(w, publicToken, status, message, true, retryAfter)
}

func passwordFromForm(w http.ResponseWriter, r *http.Request) (string, error) {
	declared, _ := strconv.ParseInt(r.Header.Get("Content-Length"), 10, 64)
	if declared > maximumFormBytes {
		return "", errorsNewInvalidForm()
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maximumFormBytes))
	if err != nil {
		return "", err
	}
	values, err := url.ParseQuery(string(body))
	if err != nil {
		return "", err
	}
	password := values.Get("password")
	if len([]byte(password)) > 128 {
		return "", errorsNewInvalidForm()
	}
	return password, nil
}

func errorsNewInvalidForm() error { return fmt.Errorf("invalid form") }

func sameOriginRequest(r *http.Request, publicBaseURL string) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsedOrigin, err := url.Parse(origin)
	if err != nil {
		return false
	}
	publicURL, err := url.Parse(publicBaseURL)
	return err == nil && parsedOrigin.Scheme == publicURL.Scheme && parsedOrigin.Host == publicURL.Host
}

func verifyPasswordValue(metadata *shareMetadata, password string) bool {
	salt, err1 := base64.RawStdEncoding.DecodeString(metadata.PasswordSalt)
	expected, err2 := base64.RawStdEncoding.DecodeString(metadata.PasswordHash)
	if err1 != nil || err2 != nil || len(expected) != sha256.Size {
		return false
	}
	actual := pbkdf2SHA256([]byte(password), salt, passwordIterations, len(expected))
	return hmac.Equal(actual, expected)
}

func (s *relayServer) shareSessionCookie(metadata *shareMetadata, publicToken string) *http.Cookie {
	expiresAt := s.now().Add(shareSessionDuration)
	if !metadata.Permanent && metadata.ExpiresAt != nil && metadata.ExpiresAt.Before(expiresAt) {
		expiresAt = *metadata.ExpiresAt
	}
	expiresUnix := expiresAt.Unix()
	value := s.signShareSession(metadata, publicToken, expiresUnix)
	secure := strings.HasPrefix(s.configuration.publicBaseURL, "https://")
	return &http.Cookie{
		Name:     shareCookieName(metadata),
		Value:    strconv.FormatInt(expiresUnix, 10) + "." + value,
		Path:     "/s/" + publicToken,
		Expires:  expiresAt,
		MaxAge:   max(1, int(expiresAt.Sub(s.now()).Seconds())),
		Secure:   secure,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	}
}

func shareCookieName(metadata *shareMetadata) string {
	return "primuse_share_" + metadata.PublicTokenHash[:16]
}

func (s *relayServer) signShareSession(metadata *shareMetadata, publicToken string, expiresUnix int64) string {
	mac := hmac.New(sha256.New, s.configuration.masterKey)
	_, _ = io.WriteString(mac, metadata.ID+"\n"+tokenHash(publicToken)+"\n"+metadata.PasswordHash+"\n"+strconv.FormatInt(expiresUnix, 10))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *relayServer) verifyShareSession(metadata *shareMetadata, publicToken string, r *http.Request) bool {
	cookie, err := r.Cookie(shareCookieName(metadata))
	if err != nil {
		return false
	}
	parts := strings.Split(cookie.Value, ".")
	if len(parts) != 2 {
		return false
	}
	expiresUnix, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return false
	}
	now := s.now()
	expiresAt := time.Unix(expiresUnix, 0)
	if !expiresAt.After(now) || expiresAt.After(now.Add(shareSessionDuration+time.Minute)) ||
		(!metadata.Permanent && (metadata.ExpiresAt == nil || expiresAt.After(*metadata.ExpiresAt))) {
		return false
	}
	expected := s.signShareSession(metadata, publicToken, expiresUnix)
	return constantTokenEqual(parts[1], expected)
}

func (s *relayServer) allowPasswordAttempt(r *http.Request, metadata *shareMetadata) bool {
	key := "password:" + metadata.PublicTokenHash + ":" + requestPeer(r)
	return s.consumeRateWindow(key, passwordAttempts, time.Minute)
}

func (s *relayServer) handleCreateImportTicket(w http.ResponseWriter, r *http.Request) {
	if !s.allowPublicRequest(r) {
		w.Header().Set("Retry-After", "60")
		writeProblem(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if !sameOriginRequest(r, s.configuration.publicBaseURL) {
		writeProblem(w, http.StatusForbidden, "invalid_origin")
		return
	}
	metadata := s.metadataByPublicToken(r.PathValue("token"))
	if metadata == nil {
		s.recordShortCodeFailure(r, r.PathValue("token"))
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.RLock()
	defer shareLock.RUnlock()
	if !s.shareIsActive(metadata) {
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	if !metadataPermission(metadata.AllowImport, true) {
		writeProblem(w, http.StatusForbidden, "import_disabled")
		return
	}
	if metadata.PasswordHash != "" && !s.verifyShareSession(metadata, r.PathValue("token"), r) {
		writeProblem(w, http.StatusUnauthorized, "password_required")
		return
	}
	token, err := randomToken(32)
	if err != nil {
		writeProblem(w, http.StatusInternalServerError, "entropy_unavailable")
		return
	}
	expiresAt := s.now().Add(importTicketDuration).UTC()
	if !metadata.Permanent && metadata.ExpiresAt != nil && metadata.ExpiresAt.Before(expiresAt) {
		expiresAt = *metadata.ExpiresAt
	}
	ticket := importTicket{Version: 1, ShareID: metadata.ID, ExpiresAt: expiresAt}
	if err := s.persistImportTicket(token, &ticket); err != nil {
		writeProblem(w, http.StatusInternalServerError, "storage_unavailable")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{
		"importURL": s.configuration.publicBaseURL + "/i/" + token,
		"expiresAt": expiresAt.Format(time.RFC3339),
	})
}

func (s *relayServer) handleImportTicket(w http.ResponseWriter, r *http.Request) {
	if !s.allowPublicRequest(r) {
		w.Header().Set("Retry-After", "60")
		writeProblem(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if !s.acquire(s.publicSlots, w) {
		return
	}
	defer s.release(s.publicSlots)

	s.ticketMu.Lock()
	ticket, err := s.loadImportTicket(r.PathValue("token"))
	if err != nil || ticket.UsedAt.IsZero() == false || !ticket.ExpiresAt.After(s.now()) {
		s.ticketMu.Unlock()
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	if r.Method == http.MethodGet {
		ticket.UsedAt = s.now().UTC()
		if err := s.persistImportTicket(r.PathValue("token"), ticket); err != nil {
			s.ticketMu.Unlock()
			writeProblem(w, http.StatusServiceUnavailable, "storage_unavailable")
			return
		}
	}
	s.ticketMu.Unlock()
	metadata := s.metadataByID(ticket.ShareID)
	if metadata == nil {
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.RLock()
	defer shareLock.RUnlock()
	if !s.shareIsActive(metadata) || !metadataPermission(metadata.AllowImport, true) {
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	s.serveMetadataMedia(w, r, metadata, true)
}

func (s *relayServer) importTicketPath(token string) string {
	return filepath.Join(s.configuration.dataDirectory, "tickets", tokenHash(token)+".json")
}

func (s *relayServer) persistImportTicket(token string, ticket *importTicket) error {
	if !validOpaqueID(token) || !validOpaqueID(ticket.ShareID) || ticket.Version != 1 {
		return fmt.Errorf("invalid import ticket")
	}
	data, err := json.Marshal(ticket)
	if err != nil {
		return err
	}
	return atomicWrite(s.importTicketPath(token), data, 0o600)
}

func (s *relayServer) loadImportTicket(token string) (*importTicket, error) {
	if !validOpaqueID(token) {
		return nil, fmt.Errorf("invalid import ticket")
	}
	data, err := os.ReadFile(s.importTicketPath(token))
	if err != nil {
		return nil, err
	}
	var ticket importTicket
	if err := json.Unmarshal(data, &ticket); err != nil || ticket.Version != 1 || !validOpaqueID(ticket.ShareID) || ticket.ExpiresAt.IsZero() {
		return nil, fmt.Errorf("invalid import ticket")
	}
	return &ticket, nil
}

func (s *relayServer) cleanupExpiredImportTickets(now time.Time) {
	s.ticketMu.Lock()
	defer s.ticketMu.Unlock()
	directory := filepath.Join(s.configuration.dataDirectory, "tickets")
	entries, err := os.ReadDir(directory)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var ticket importTicket
		if json.Unmarshal(data, &ticket) != nil || !ticket.ExpiresAt.After(now) || !ticket.UsedAt.IsZero() {
			_ = os.Remove(path)
		}
	}
}
