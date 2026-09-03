package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
)

const (
	defaultChunkSize       = int64(4 * 1024 * 1024)
	defaultMaximumFileSize = int64(20 * 1024 * 1024 * 1024)
	defaultMaximumTTL      = 30 * 24 * time.Hour
	defaultUploadTTL       = 24 * time.Hour
	passwordIterations     = 210_000
	maximumJSONBytes       = int64(64 * 1024)
	defaultShortCodeTTL    = 24 * time.Hour
	shortCodeRetryLimit    = 16
	clientEncryptionMode   = "client-aes-256-gcm-chunks-v1"
	maximumManifestBytes   = int64(8 * 1024)
	e2eePolicyRequired     = "required"
	e2eePolicyOptional     = "optional"
	e2eePolicyDisabled     = "disabled"
)

type config struct {
	listenAddress                  string
	dataDirectory                  string
	publicBaseURL                  string
	adminToken                     string
	masterKey                      []byte
	chunkSize                      int64
	maximumFileSize                int64
	maximumTTL                     time.Duration
	uploadTTL                      time.Duration
	publicRequestsPerMinute        int
	shortCodePeerRequestsPerMinute int
	shortCodeRequestsPerMinute     int
	shortCodeFailuresPerWindow     int
	shortCodeFailureWindow         time.Duration
	shortCodeMaximumTTL            time.Duration
	maximumPublicStreams           int
	maximumUploads                 int
	e2eePolicy                     string
}

type shareMetadata struct {
	Version         int        `json:"version"`
	ID              string     `json:"id"`
	PublicTokenHash string     `json:"publicTokenHash"`
	ControlHash     string     `json:"controlHash"`
	FileName        string     `json:"fileName"`
	ContentType     string     `json:"contentType"`
	Size            int64      `json:"size"`
	ChunkSize       int64      `json:"chunkSize"`
	CreatedAt       time.Time  `json:"createdAt"`
	ExpiresAt       *time.Time `json:"expiresAt,omitempty"`
	UploadExpiresAt time.Time  `json:"uploadExpiresAt"`
	CompletedAt     time.Time  `json:"completedAt,omitempty"`
	RevokedAt       time.Time  `json:"revokedAt,omitempty"`
	DataDeletedAt   time.Time  `json:"dataDeletedAt,omitempty"`
	ETag            string     `json:"etag"`
	PasswordSalt    string     `json:"passwordSalt,omitempty"`
	PasswordHash    string     `json:"passwordHash,omitempty"`
	Title           string     `json:"title,omitempty"`
	Artist          string     `json:"artist,omitempty"`
	Album           string     `json:"album,omitempty"`
	AudioFormat     string     `json:"audioFormat,omitempty"`
	Quality         string     `json:"quality,omitempty"`
	DurationSeconds float64    `json:"durationSeconds,omitempty"`
	AllowPlayback   *bool      `json:"allowPlayback,omitempty"`
	AllowDownload   *bool      `json:"allowDownload,omitempty"`
	AllowImport     *bool      `json:"allowImport,omitempty"`
	ShortCode       bool       `json:"shortCode,omitempty"`
	Permanent       bool       `json:"permanent"`
	EncryptionMode  string     `json:"encryptionMode,omitempty"`
}

func (m *shareMetadata) complete() bool { return !m.CompletedAt.IsZero() }
func (m *shareMetadata) revoked() bool  { return !m.RevokedAt.IsZero() }
func (m *shareMetadata) activeAt(now time.Time) bool {
	return m.Permanent || m.ExpiresAt != nil && m.ExpiresAt.After(now)
}

func formattedExpiration(expiresAt *time.Time) *string {
	if expiresAt == nil {
		return nil
	}
	value := expiresAt.UTC().Format(time.RFC3339)
	return &value
}

type createUploadRequest struct {
	EncryptionMode  string  `json:"encryptionMode,omitempty"`
	FileName        string  `json:"fileName"`
	ContentType     string  `json:"contentType"`
	Size            int64   `json:"size"`
	ExpiresAt       string  `json:"expiresAt,omitempty"`
	Password        string  `json:"password,omitempty"`
	Title           string  `json:"title,omitempty"`
	Artist          string  `json:"artist,omitempty"`
	Album           string  `json:"album,omitempty"`
	AudioFormat     string  `json:"audioFormat,omitempty"`
	Quality         string  `json:"quality,omitempty"`
	DurationSeconds float64 `json:"durationSeconds,omitempty"`
	AllowPlayback   *bool   `json:"allowPlayback,omitempty"`
	AllowDownload   *bool   `json:"allowDownload,omitempty"`
	AllowImport     *bool   `json:"allowImport,omitempty"`
	LinkType        string  `json:"linkType,omitempty"`
	ShortCodeLength int     `json:"shortCodeLength,omitempty"`
}

type createUploadResponse struct {
	ShareID        string  `json:"shareID"`
	UploadToken    string  `json:"uploadToken"`
	PublicURL      string  `json:"publicURL"`
	ChunkSize      int64   `json:"chunkSize"`
	ExpiresAt      *string `json:"expiresAt,omitempty"`
	Permanent      bool    `json:"permanent"`
	AccessCode     string  `json:"accessCode,omitempty"`
	EncryptionMode string  `json:"encryptionMode,omitempty"`
}

type completeUploadResponse struct {
	ShareID   string  `json:"shareID"`
	ExpiresAt *string `json:"expiresAt,omitempty"`
	Permanent bool    `json:"permanent"`
}

type relayServer struct {
	configuration config
	block         cipher.AEAD
	now           func() time.Time

	mu           sync.RWMutex
	byID         map[string]*shareMetadata
	byPublicHash map[string]*shareMetadata
	shareLocks   map[string]*sync.RWMutex

	publicSlots        chan struct{}
	uploadSlots        chan struct{}
	rateMu             sync.Mutex
	rateWindows        map[string]*rateWindow
	rateCleaned        time.Time
	ticketMu           sync.Mutex
	shortCodeGenerator func(int) (string, error)
}

type rateWindow struct {
	startedAt time.Time
	count     int
}

func main() {
	configuration, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	server, err := newRelayServer(configuration)
	if err != nil {
		log.Fatal(err)
	}
	server.cleanupExpired()

	httpServer := &http.Server{
		Addr:              configuration.listenAddress,
		Handler:           server.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    32 * 1024,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
	}()
	go server.cleanupLoop(httpServer.RegisterOnShutdown)

	log.Printf("Primuse Share Relay listening on %s", configuration.listenAddress)
	err = httpServer.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func loadConfig() (config, error) {
	c := config{
		listenAddress:                  envOrDefault("PRIMUSE_RELAY_LISTEN_ADDR", ":8787"),
		dataDirectory:                  envOrDefault("PRIMUSE_RELAY_DATA_DIR", "/data"),
		publicBaseURL:                  strings.TrimRight(os.Getenv("PRIMUSE_RELAY_PUBLIC_BASE_URL"), "/"),
		adminToken:                     os.Getenv("PRIMUSE_RELAY_ADMIN_TOKEN"),
		chunkSize:                      envInt64("PRIMUSE_RELAY_CHUNK_SIZE", defaultChunkSize),
		maximumFileSize:                envInt64("PRIMUSE_RELAY_MAX_FILE_BYTES", defaultMaximumFileSize),
		maximumTTL:                     time.Duration(envInt64("PRIMUSE_RELAY_MAX_TTL_SECONDS", int64(defaultMaximumTTL/time.Second))) * time.Second,
		uploadTTL:                      time.Duration(envInt64("PRIMUSE_RELAY_UPLOAD_TTL_SECONDS", int64(defaultUploadTTL/time.Second))) * time.Second,
		publicRequestsPerMinute:        int(envInt64("PRIMUSE_RELAY_PUBLIC_REQUESTS_PER_MINUTE", 600)),
		shortCodePeerRequestsPerMinute: int(envInt64("PRIMUSE_RELAY_SHORT_CODE_PEER_REQUESTS_PER_MINUTE", 60)),
		shortCodeRequestsPerMinute:     int(envInt64("PRIMUSE_RELAY_SHORT_CODE_REQUESTS_PER_MINUTE", 60)),
		shortCodeFailuresPerWindow:     int(envInt64("PRIMUSE_RELAY_SHORT_CODE_FAILURES_PER_WINDOW", 5)),
		shortCodeFailureWindow:         time.Duration(envInt64("PRIMUSE_RELAY_SHORT_CODE_FAILURE_WINDOW_SECONDS", 600)) * time.Second,
		shortCodeMaximumTTL:            time.Duration(envInt64("PRIMUSE_RELAY_SHORT_CODE_MAX_TTL_SECONDS", int64(defaultShortCodeTTL/time.Second))) * time.Second,
		maximumPublicStreams:           int(envInt64("PRIMUSE_RELAY_MAX_PUBLIC_STREAMS", 32)),
		maximumUploads:                 int(envInt64("PRIMUSE_RELAY_MAX_UPLOADS", 4)),
		e2eePolicy:                     envOrDefault("PRIMUSE_RELAY_E2EE_POLICY", e2eePolicyRequired),
	}
	key, err := base64.StdEncoding.DecodeString(os.Getenv("PRIMUSE_RELAY_MASTER_KEY"))
	if err != nil || len(key) != 32 {
		return config{}, errors.New("PRIMUSE_RELAY_MASTER_KEY must be a base64-encoded 32-byte key")
	}
	c.masterKey = key
	if len(c.adminToken) < 32 {
		return config{}, errors.New("PRIMUSE_RELAY_ADMIN_TOKEN must contain at least 32 characters")
	}
	if err := validatePublicBaseURL(c.publicBaseURL, os.Getenv("PRIMUSE_RELAY_ALLOW_INSECURE_PUBLIC_URL") == "true"); err != nil {
		return config{}, err
	}
	if c.chunkSize < 256*1024 || c.chunkSize > 32*1024*1024 {
		return config{}, errors.New("PRIMUSE_RELAY_CHUNK_SIZE must be between 256 KiB and 32 MiB")
	}
	if c.maximumFileSize <= 0 || c.maximumTTL <= 0 || c.uploadTTL <= 0 ||
		c.publicRequestsPerMinute <= 0 || c.shortCodePeerRequestsPerMinute <= 0 ||
		c.shortCodeRequestsPerMinute <= 0 ||
		c.shortCodeFailuresPerWindow <= 0 || c.shortCodeFailureWindow <= 0 ||
		c.shortCodeMaximumTTL <= 0 || c.shortCodeMaximumTTL > c.maximumTTL ||
		c.maximumPublicStreams <= 0 || c.maximumUploads <= 0 {
		return config{}, errors.New("relay limits must be positive")
	}
	if c.e2eePolicy != e2eePolicyRequired && c.e2eePolicy != e2eePolicyOptional && c.e2eePolicy != e2eePolicyDisabled {
		return config{}, errors.New("PRIMUSE_RELAY_E2EE_POLICY must be required, optional, or disabled")
	}
	return c, nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func envInt64(name string, fallback int64) int64 {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return fallback
	}
	return parsed
}

func validatePublicBaseURL(raw string, allowInsecure bool) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("PRIMUSE_RELAY_PUBLIC_BASE_URL must be an absolute URL without credentials, query, or fragment")
	}
	if parsed.Scheme != "https" && !(allowInsecure && parsed.Scheme == "http") {
		return errors.New("PRIMUSE_RELAY_PUBLIC_BASE_URL must use HTTPS")
	}
	if !isPublicHost(parsed.Hostname()) {
		return errors.New("PRIMUSE_RELAY_PUBLIC_BASE_URL must use a public host")
	}
	return nil
}

func isPublicHost(rawHost string) bool {
	host := strings.ToLower(strings.TrimSuffix(rawHost, "."))
	if host == "" || strings.Contains(host, "%") || host == "localhost" ||
		strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") ||
		strings.HasSuffix(host, ".lan") || strings.HasSuffix(host, ".internal") ||
		strings.HasSuffix(host, ".home.arpa") {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		if ipv4 := ip.To4(); ipv4 != nil {
			return isPublicIPv4(ipv4)
		}
		return ip.IsGlobalUnicast() && !ip.IsPrivate() &&
			!(len(ip) == net.IPv6len && ip[0] == 0x20 && ip[1] == 0x01 && ip[2] == 0x0d && ip[3] == 0xb8)
	}
	return strings.Contains(host, ".") && !isAlternateNumericHost(host)
}

func isAlternateNumericHost(host string) bool {
	labels := strings.Split(host, ".")
	if len(labels) == 0 {
		return false
	}
	for _, label := range labels {
		if label == "" {
			return true
		}
		digits := label
		isDigit := func(r rune) bool { return r >= '0' && r <= '9' }
		if strings.HasPrefix(label, "0x") {
			digits = strings.TrimPrefix(label, "0x")
			isDigit = func(r rune) bool {
				return r >= '0' && r <= '9' || r >= 'a' && r <= 'f'
			}
		}
		if digits == "" {
			return false
		}
		for _, r := range digits {
			if !isDigit(r) {
				return false
			}
		}
	}
	return true
}

func isPublicIPv4(ip net.IP) bool {
	first, second, third := ip[0], ip[1], ip[2]
	if first >= 224 {
		return false
	}
	switch first {
	case 0, 10, 127:
		return false
	case 100:
		return second < 64 || second > 127
	case 169:
		return second != 254
	case 172:
		return second < 16 || second > 31
	case 192:
		if second == 0 || second == 168 || (second == 88 && third == 99) {
			return false
		}
		return true
	case 198:
		if second == 18 || second == 19 || second == 51 && third == 100 {
			return false
		}
		return true
	case 203:
		return !(second == 0 && third == 113)
	default:
		return true
	}
}

func newRelayServer(c config) (*relayServer, error) {
	block, err := aes.NewCipher(c.masterKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	for _, directory := range []string{
		filepath.Join(c.dataDirectory, "metadata"),
		filepath.Join(c.dataDirectory, "chunks"),
		filepath.Join(c.dataDirectory, "manifests"),
		filepath.Join(c.dataDirectory, "tickets"),
		filepath.Join(c.dataDirectory, "short-code-reservations"),
	} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, err
		}
	}
	s := &relayServer{
		configuration:      c,
		block:              aead,
		now:                time.Now,
		byID:               make(map[string]*shareMetadata),
		byPublicHash:       make(map[string]*shareMetadata),
		shareLocks:         make(map[string]*sync.RWMutex),
		publicSlots:        make(chan struct{}, c.maximumPublicStreams),
		uploadSlots:        make(chan struct{}, c.maximumUploads),
		rateWindows:        make(map[string]*rateWindow),
		shortCodeGenerator: randomNumericCode,
	}
	if err := s.loadMetadata(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *relayServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("HEAD /healthz", s.handleHealth)
	mux.HandleFunc("GET /.well-known/primuse-share", s.handleCapabilities)
	mux.HandleFunc("HEAD /.well-known/primuse-share", s.handleCapabilities)
	mux.HandleFunc("POST /v1/uploads", s.handleCreateUpload)
	mux.HandleFunc("PUT /v1/uploads/{id}/manifest", s.handleUploadManifest)
	mux.HandleFunc("PUT /v1/uploads/{id}/chunks/{index}", s.handleUploadChunk)
	mux.HandleFunc("POST /v1/uploads/{id}/complete", s.handleCompleteUpload)
	mux.HandleFunc("DELETE /v1/shares/{id}", s.handleRevokeShare)
	mux.HandleFunc("GET /s/{token}", s.handlePublicShare)
	mux.HandleFunc("HEAD /s/{token}", s.handlePublicShare)
	mux.HandleFunc("POST /s/{token}/auth", s.handleShareAuthentication)
	mux.HandleFunc("GET /s/{token}/manifest", s.handleEncryptedManifest)
	mux.HandleFunc("HEAD /s/{token}/manifest", s.handleEncryptedManifest)
	mux.HandleFunc("GET /s/{token}/chunks/{index}", s.handleEncryptedChunk)
	mux.HandleFunc("HEAD /s/{token}/chunks/{index}", s.handleEncryptedChunk)
	mux.HandleFunc("GET /s/{token}/media", s.handleShareMedia)
	mux.HandleFunc("HEAD /s/{token}/media", s.handleShareMedia)
	mux.HandleFunc("GET /s/{token}/download", s.handleShareDownload)
	mux.HandleFunc("HEAD /s/{token}/download", s.handleShareDownload)
	mux.HandleFunc("POST /s/{token}/import", s.handleCreateImportTicket)
	mux.HandleFunc("GET /i/{token}", s.handleImportTicket)
	mux.HandleFunc("HEAD /i/{token}", s.handleImportTicket)
	mux.HandleFunc("GET /share.css", s.handleWebAsset)
	mux.HandleFunc("GET /share.js", s.handleWebAsset)
	mux.HandleFunc("GET /fallback-cover.webp", s.handleWebAsset)
	mux.HandleFunc("GET /icons/{name}", s.handleWebAsset)
	return s.securityHeaders(s.requestLog(mux))
}

func (s *relayServer) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		w.Header().Set("X-Robots-Tag", "noindex, nofollow, noarchive")
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (s *relayServer) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := s.now()
		wrapped := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(wrapped, r)
		// Deliberately omit the path, query, headers, filenames, and peer address.
		log.Printf("request method=%s status=%d duration_ms=%d", r.Method, wrapped.status, s.now().Sub(started).Milliseconds())
	})
}

func (s *relayServer) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *relayServer) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"protocolVersion":          4,
		"clientSideEncryption":     s.configuration.e2eePolicy,
		"supportedEncryptionModes": []string{clientEncryptionMode},
	})
}

func (s *relayServer) handleCreateUpload(w http.ResponseWriter, r *http.Request) {
	if !constantTokenEqual(bearerToken(r), s.configuration.adminToken) {
		writeProblem(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if !s.acquire(s.uploadSlots, w) {
		return
	}
	defer s.release(s.uploadSlots)

	var request createUploadRequest
	if err := decodeJSON(w, r, &request); err != nil {
		return
	}
	usesClientEncryption := request.EncryptionMode == clientEncryptionMode
	if request.EncryptionMode != "" && !usesClientEncryption {
		writeProblem(w, http.StatusBadRequest, "unsupported_encryption_mode")
		return
	}
	if s.configuration.e2eePolicy == e2eePolicyRequired && !usesClientEncryption {
		writeProblem(w, http.StatusBadRequest, "encryption_required")
		return
	}
	if s.configuration.e2eePolicy == e2eePolicyDisabled && usesClientEncryption {
		writeProblem(w, http.StatusBadRequest, "client_encryption_disabled")
		return
	}
	if usesClientEncryption {
		request.FileName = ""
		request.ContentType = "application/octet-stream"
		request.Title = ""
		request.Artist = ""
		request.Album = ""
		request.AudioFormat = ""
		request.Quality = ""
		request.DurationSeconds = 0
	} else {
		request.FileName = sanitizeFileName(request.FileName)
		request.ContentType = sanitizeContentType(request.ContentType)
		request.Title = sanitizeDisplayText(request.Title, 160)
		request.Artist = sanitizeDisplayText(request.Artist, 160)
		request.Album = sanitizeDisplayText(request.Album, 160)
		request.AudioFormat = sanitizeDisplayText(request.AudioFormat, 32)
		request.Quality = sanitizeDisplayText(request.Quality, 80)
	}
	if (!usesClientEncryption && request.FileName == "") || request.Size <= 0 || request.Size > s.configuration.maximumFileSize {
		writeProblem(w, http.StatusBadRequest, "invalid_media")
		return
	}
	if len(request.Password) > 128 {
		writeProblem(w, http.StatusBadRequest, "invalid_password")
		return
	}
	if request.DurationSeconds < 0 || request.DurationSeconds > 7*24*60*60 {
		writeProblem(w, http.StatusBadRequest, "invalid_media")
		return
	}
	linkType := request.LinkType
	if linkType == "" {
		linkType = "long"
	}
	shortCode := linkType == "short"
	permanent := linkType == "permanent"
	if linkType != "long" && !shortCode && !permanent {
		writeProblem(w, http.StatusBadRequest, "invalid_link_type")
		return
	}
	if shortCode {
		if request.ShortCodeLength == 0 {
			request.ShortCodeLength = 6
		}
		if request.ShortCodeLength < 4 || request.ShortCodeLength > 6 {
			writeProblem(w, http.StatusBadRequest, "invalid_short_code_length")
			return
		}
	} else if request.ShortCodeLength != 0 {
		writeProblem(w, http.StatusBadRequest, "invalid_short_code_length")
		return
	}

	now := s.now().UTC()
	var expiresAt *time.Time
	if permanent {
		if request.ExpiresAt != "" {
			writeProblem(w, http.StatusBadRequest, "invalid_expiration")
			return
		}
	} else {
		value := now.Add(7 * 24 * time.Hour)
		if shortCode {
			value = now.Add(time.Hour)
		}
		if request.ExpiresAt != "" {
			parsed, err := time.Parse(time.RFC3339, request.ExpiresAt)
			if err != nil {
				writeProblem(w, http.StatusBadRequest, "invalid_expiration")
				return
			}
			value = parsed.UTC()
		}
		maximumExpiration := now.Add(s.configuration.maximumTTL)
		if shortCode {
			maximumExpiration = now.Add(s.configuration.shortCodeMaximumTTL)
		}
		if !value.After(now) || value.After(maximumExpiration) {
			writeProblem(w, http.StatusBadRequest, "invalid_expiration")
			return
		}
		expiresAt = &value
	}

	id, err := randomToken(18)
	if err != nil {
		writeProblem(w, http.StatusInternalServerError, "entropy_unavailable")
		return
	}
	uploadToken, err := randomToken(32)
	if err != nil {
		writeProblem(w, http.StatusInternalServerError, "entropy_unavailable")
		return
	}
	publicToken := ""
	if shortCode {
		publicToken, err = s.reserveShortCode(request.ShortCodeLength, id, *expiresAt)
	} else {
		publicToken, err = randomToken(32)
	}
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, "public_identifier_unavailable")
		return
	}
	reservedShortCodeHash := ""
	if shortCode {
		reservedShortCodeHash = tokenHash(publicToken)
	}
	etagToken, err := randomToken(18)
	if err != nil {
		if reservedShortCodeHash != "" {
			s.releaseShortCodeReservation(reservedShortCodeHash)
		}
		writeProblem(w, http.StatusInternalServerError, "entropy_unavailable")
		return
	}

	metadataVersion := 3
	if usesClientEncryption {
		metadataVersion = 4
	}
	metadata := &shareMetadata{
		Version:         metadataVersion,
		ID:              id,
		PublicTokenHash: tokenHash(publicToken),
		ControlHash:     tokenHash(uploadToken),
		FileName:        request.FileName,
		ContentType:     request.ContentType,
		Size:            request.Size,
		ChunkSize:       s.configuration.chunkSize,
		CreatedAt:       now,
		ExpiresAt:       expiresAt,
		UploadExpiresAt: now.Add(s.configuration.uploadTTL),
		ETag:            `"` + etagToken + `"`,
		Title:           request.Title,
		Artist:          request.Artist,
		Album:           request.Album,
		AudioFormat:     request.AudioFormat,
		Quality:         request.Quality,
		DurationSeconds: request.DurationSeconds,
		AllowPlayback:   boolPointerOrDefault(request.AllowPlayback, true),
		AllowDownload:   boolPointerOrDefault(request.AllowDownload, true),
		AllowImport:     boolPointerOrDefault(request.AllowImport, true),
		ShortCode:       shortCode,
		Permanent:       permanent,
		EncryptionMode:  request.EncryptionMode,
	}
	if request.Password != "" {
		salt := make([]byte, 16)
		if _, err := rand.Read(salt); err != nil {
			if reservedShortCodeHash != "" {
				s.releaseShortCodeReservation(reservedShortCodeHash)
			}
			writeProblem(w, http.StatusInternalServerError, "entropy_unavailable")
			return
		}
		metadata.PasswordSalt = base64.RawStdEncoding.EncodeToString(salt)
		metadata.PasswordHash = base64.RawStdEncoding.EncodeToString(pbkdf2SHA256([]byte(request.Password), salt, passwordIterations, 32))
	}
	if err := s.persistMetadata(metadata); err != nil {
		if reservedShortCodeHash != "" {
			s.releaseShortCodeReservation(reservedShortCodeHash)
		}
		writeProblem(w, http.StatusInternalServerError, "storage_unavailable")
		return
	}
	s.mu.Lock()
	s.byID[metadata.ID] = metadata
	s.byPublicHash[metadata.PublicTokenHash] = metadata
	s.shareLocks[metadata.ID] = &sync.RWMutex{}
	s.mu.Unlock()

	response := createUploadResponse{
		ShareID:        id,
		UploadToken:    uploadToken,
		PublicURL:      s.configuration.publicBaseURL + "/s/" + publicToken,
		ChunkSize:      metadata.ChunkSize,
		ExpiresAt:      formattedExpiration(expiresAt),
		Permanent:      permanent,
		EncryptionMode: request.EncryptionMode,
	}
	if shortCode {
		response.AccessCode = publicToken
	}
	writeJSON(w, http.StatusCreated, response)
}

func (s *relayServer) handleUploadManifest(w http.ResponseWriter, r *http.Request) {
	if !s.acquire(s.uploadSlots, w) {
		return
	}
	defer s.release(s.uploadSlots)

	metadata := s.metadataByID(r.PathValue("id"))
	if metadata == nil || !s.authorizeControl(metadata, r) {
		writeProblem(w, http.StatusNotFound, "not_found")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.Lock()
	defer shareLock.Unlock()
	if metadata.EncryptionMode != clientEncryptionMode {
		writeProblem(w, http.StatusConflict, "manifest_not_supported")
		return
	}
	if metadata.complete() || metadata.revoked() || !metadata.UploadExpiresAt.After(s.now()) {
		writeProblem(w, http.StatusConflict, "upload_closed")
		return
	}
	manifest, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maximumManifestBytes+1))
	if err != nil || int64(len(manifest)) <= int64(s.block.NonceSize()+s.block.Overhead()) || int64(len(manifest)) > maximumManifestBytes {
		writeProblem(w, http.StatusBadRequest, "invalid_manifest")
		return
	}
	if err := atomicWrite(s.manifestPath(metadata.ID), manifest, 0o600); err != nil {
		writeProblem(w, http.StatusInternalServerError, "storage_unavailable")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *relayServer) handleUploadChunk(w http.ResponseWriter, r *http.Request) {
	if !s.acquire(s.uploadSlots, w) {
		return
	}
	defer s.release(s.uploadSlots)

	metadata := s.metadataByID(r.PathValue("id"))
	if metadata == nil || !s.authorizeControl(metadata, r) {
		writeProblem(w, http.StatusNotFound, "not_found")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.Lock()
	defer shareLock.Unlock()
	if metadata.complete() || metadata.revoked() || !metadata.UploadExpiresAt.After(s.now()) {
		writeProblem(w, http.StatusConflict, "upload_closed")
		return
	}
	index, err := strconv.ParseInt(r.PathValue("index"), 10, 64)
	if err != nil || index < 0 {
		writeProblem(w, http.StatusBadRequest, "invalid_chunk")
		return
	}
	expectedStart := index * metadata.ChunkSize
	if expectedStart >= metadata.Size {
		writeProblem(w, http.StatusBadRequest, "invalid_chunk")
		return
	}
	expectedLength := min64(metadata.ChunkSize, metadata.Size-expectedStart)
	start, end, total, ok := parseContentRange(r.Header.Get("Content-Range"))
	if !ok || start != expectedStart || end-start+1 != expectedLength || total != metadata.Size {
		writeProblem(w, http.StatusBadRequest, "invalid_content_range")
		return
	}
	expectedBodyLength := expectedLength
	if metadata.EncryptionMode == clientEncryptionMode {
		expectedBodyLength += int64(s.block.NonceSize() + s.block.Overhead())
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, expectedBodyLength))
	if err != nil || int64(len(body)) != expectedBodyLength {
		writeProblem(w, http.StatusBadRequest, "invalid_chunk_size")
		return
	}
	encrypted := body
	if metadata.EncryptionMode != clientEncryptionMode {
		encrypted, err = s.encryptChunk(metadata, index, body)
		if err != nil {
			writeProblem(w, http.StatusInternalServerError, "encryption_failed")
			return
		}
	}
	if err := s.persistChunk(metadata.ID, index, encrypted); err != nil {
		writeProblem(w, http.StatusInternalServerError, "storage_unavailable")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *relayServer) handleCompleteUpload(w http.ResponseWriter, r *http.Request) {
	if !s.acquire(s.uploadSlots, w) {
		return
	}
	defer s.release(s.uploadSlots)

	metadata := s.metadataByID(r.PathValue("id"))
	if metadata == nil || !s.authorizeControl(metadata, r) {
		writeProblem(w, http.StatusNotFound, "not_found")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.Lock()
	defer shareLock.Unlock()
	if metadata.revoked() || !metadata.UploadExpiresAt.After(s.now()) {
		writeProblem(w, http.StatusConflict, "upload_closed")
		return
	}
	if !metadata.complete() {
		if metadata.EncryptionMode == clientEncryptionMode {
			info, err := os.Stat(s.manifestPath(metadata.ID))
			if err != nil || info.Size() <= int64(s.block.NonceSize()+s.block.Overhead()) || info.Size() > maximumManifestBytes {
				writeProblem(w, http.StatusConflict, "missing_manifest")
				return
			}
		}
		chunkCount := (metadata.Size + metadata.ChunkSize - 1) / metadata.ChunkSize
		for index := int64(0); index < chunkCount; index++ {
			expectedPlaintext := min64(metadata.ChunkSize, metadata.Size-index*metadata.ChunkSize)
			info, err := os.Stat(s.chunkPath(metadata.ID, index))
			if err != nil || info.Size() != expectedPlaintext+int64(s.block.NonceSize()+s.block.Overhead()) {
				writeProblem(w, http.StatusConflict, "missing_chunk")
				return
			}
		}
		metadata.CompletedAt = s.now().UTC()
		if err := s.persistMetadata(metadata); err != nil {
			metadata.CompletedAt = time.Time{}
			writeProblem(w, http.StatusInternalServerError, "storage_unavailable")
			return
		}
	}
	writeJSON(w, http.StatusOK, completeUploadResponse{
		ShareID:   metadata.ID,
		ExpiresAt: formattedExpiration(metadata.ExpiresAt),
		Permanent: metadata.Permanent,
	})
}

func (s *relayServer) handleRevokeShare(w http.ResponseWriter, r *http.Request) {
	metadata := s.metadataByID(r.PathValue("id"))
	if metadata == nil || (!s.authorizeControl(metadata, r) &&
		!constantTokenEqual(bearerToken(r), s.configuration.adminToken)) {
		writeProblem(w, http.StatusNotFound, "not_found")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.Lock()
	defer shareLock.Unlock()
	if !metadata.revoked() {
		metadata.RevokedAt = s.now().UTC()
		if err := s.persistMetadata(metadata); err != nil {
			metadata.RevokedAt = time.Time{}
			writeProblem(w, http.StatusInternalServerError, "storage_unavailable")
			return
		}
		_ = os.RemoveAll(filepath.Join(s.configuration.dataDirectory, "chunks", metadata.ID))
		_ = os.Remove(s.manifestPath(metadata.ID))
		metadata.DataDeletedAt = s.now().UTC()
		_ = s.persistMetadata(metadata)
		s.deactivateShortCode(metadata)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *relayServer) handlePublicShare(w http.ResponseWriter, r *http.Request) {
	if prefersHTML(r) {
		s.handleSharePage(w, r)
		return
	}
	s.servePublicMedia(w, r, false)
}

func (s *relayServer) handleShareMedia(w http.ResponseWriter, r *http.Request) {
	s.servePublicMedia(w, r, false)
}

func (s *relayServer) handleShareDownload(w http.ResponseWriter, r *http.Request) {
	s.servePublicMedia(w, r, true)
}

func (s *relayServer) handleEncryptedManifest(w http.ResponseWriter, r *http.Request) {
	metadata, unlock := s.authorizedEncryptedShare(w, r)
	if metadata == nil {
		return
	}
	defer unlock()
	manifest, err := os.ReadFile(s.manifestPath(metadata.ID))
	if err != nil || int64(len(manifest)) <= int64(s.block.NonceSize()+s.block.Overhead()) || int64(len(manifest)) > maximumManifestBytes {
		writeProblem(w, http.StatusServiceUnavailable, "storage_unavailable")
		return
	}
	w.Header().Set("Cache-Control", "private, no-store, max-age=0")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(len(manifest)))
	w.Header().Set("X-Primuse-Encryption-Mode", clientEncryptionMode)
	w.Header().Set("X-Primuse-Share-ID", metadata.ID)
	w.Header().Set("X-Primuse-Plaintext-Size", strconv.FormatInt(metadata.Size, 10))
	w.Header().Set("X-Primuse-Chunk-Size", strconv.FormatInt(metadata.ChunkSize, 10))
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(manifest)
}

func (s *relayServer) handleEncryptedChunk(w http.ResponseWriter, r *http.Request) {
	metadata, unlock := s.authorizedEncryptedShare(w, r)
	if metadata == nil {
		return
	}
	defer unlock()
	if !metadataPermission(metadata.AllowPlayback, true) &&
		!metadataPermission(metadata.AllowDownload, true) &&
		!metadataPermission(metadata.AllowImport, true) {
		writeProblem(w, http.StatusForbidden, "media_access_disabled")
		return
	}
	index, err := strconv.ParseInt(r.PathValue("index"), 10, 64)
	chunkCount := (metadata.Size + metadata.ChunkSize - 1) / metadata.ChunkSize
	if err != nil || index < 0 || index >= chunkCount {
		writeProblem(w, http.StatusNotFound, "not_found")
		return
	}
	expectedPlaintext := min64(metadata.ChunkSize, metadata.Size-index*metadata.ChunkSize)
	expectedEncrypted := expectedPlaintext + int64(s.block.NonceSize()+s.block.Overhead())
	chunk, err := os.ReadFile(s.chunkPath(metadata.ID, index))
	if err != nil || int64(len(chunk)) != expectedEncrypted {
		writeProblem(w, http.StatusServiceUnavailable, "storage_unavailable")
		return
	}
	w.Header().Set("Cache-Control", "private, no-store, max-age=0")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(len(chunk)))
	w.Header().Set("X-Primuse-Chunk-Index", strconv.FormatInt(index, 10))
	if r.Method == http.MethodHead {
		return
	}
	_, _ = w.Write(chunk)
}

func (s *relayServer) authorizedEncryptedShare(w http.ResponseWriter, r *http.Request) (*shareMetadata, func()) {
	if !s.allowPublicRequest(r) {
		w.Header().Set("Retry-After", "60")
		writeProblem(w, http.StatusTooManyRequests, "rate_limited")
		return nil, func() {}
	}
	if !s.acquire(s.publicSlots, w) {
		return nil, func() {}
	}
	releaseSlot := true
	release := func() {
		if releaseSlot {
			s.release(s.publicSlots)
			releaseSlot = false
		}
	}
	metadata := s.metadataByPublicToken(r.PathValue("token"))
	if metadata == nil {
		release()
		s.recordShortCodeFailure(r, r.PathValue("token"))
		writeProblem(w, http.StatusGone, "unavailable")
		return nil, func() {}
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.RLock()
	if !s.shareIsActive(metadata) {
		shareLock.RUnlock()
		release()
		writeProblem(w, http.StatusGone, "unavailable")
		return nil, func() {}
	}
	if metadata.EncryptionMode != clientEncryptionMode {
		shareLock.RUnlock()
		release()
		writeProblem(w, http.StatusConflict, "client_decryption_not_available")
		return nil, func() {}
	}
	if metadata.PasswordHash != "" && !verifyPassword(metadata, r) && !s.verifyShareSession(metadata, r.PathValue("token"), r) {
		shareLock.RUnlock()
		release()
		w.Header().Set("WWW-Authenticate", `Basic realm="Primuse Share", charset="UTF-8"`)
		writeProblem(w, http.StatusUnauthorized, "password_required")
		return nil, func() {}
	}
	return metadata, func() {
		shareLock.RUnlock()
		release()
	}
}

func (s *relayServer) servePublicMedia(w http.ResponseWriter, r *http.Request, attachment bool) {
	if !s.allowPublicRequest(r) {
		w.Header().Set("Retry-After", "60")
		writeProblem(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if !s.acquire(s.publicSlots, w) {
		return
	}
	defer s.release(s.publicSlots)

	metadata := s.metadataByPublicToken(r.PathValue("token"))
	if metadata == nil {
		s.recordShortCodeFailure(r, r.PathValue("token"))
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	shareLock := s.lockForShare(metadata.ID)
	shareLock.RLock()
	defer shareLock.RUnlock()
	if !metadata.complete() || metadata.revoked() {
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	if !metadata.activeAt(s.now()) || !metadata.DataDeletedAt.IsZero() {
		writeProblem(w, http.StatusGone, "unavailable")
		return
	}
	if metadata.PasswordHash != "" && !verifyPassword(metadata, r) && !s.verifyShareSession(metadata, r.PathValue("token"), r) {
		if r.Header.Get("Authorization") != "" {
			s.recordShortCodeFailure(r, r.PathValue("token"))
		}
		w.Header().Set("WWW-Authenticate", `Basic realm="Primuse Share", charset="UTF-8"`)
		writeProblem(w, http.StatusUnauthorized, "password_required")
		return
	}
	if attachment && !metadataPermission(metadata.AllowDownload, true) {
		writeProblem(w, http.StatusForbidden, "download_disabled")
		return
	}
	if !attachment && !metadataPermission(metadata.AllowPlayback, true) {
		writeProblem(w, http.StatusForbidden, "playback_disabled")
		return
	}
	if metadata.EncryptionMode == clientEncryptionMode {
		writeProblem(w, http.StatusConflict, "client_decryption_required")
		return
	}
	s.serveMetadataMedia(w, r, metadata, attachment)
}

func (s *relayServer) serveMetadataMedia(w http.ResponseWriter, r *http.Request, metadata *shareMetadata, attachment bool) {

	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Cache-Control", "private, no-store, max-age=0")
	w.Header().Set("Content-Type", metadata.ContentType)
	w.Header().Set("Content-Disposition", contentDispositionMode(metadata.FileName, attachment))
	w.Header().Set("ETag", metadata.ETag)
	w.Header().Set("Last-Modified", metadata.CompletedAt.UTC().Format(http.TimeFormat))
	if r.Header.Get("If-None-Match") == metadata.ETag && r.Header.Get("Range") == "" {
		w.WriteHeader(http.StatusNotModified)
		return
	}

	start, end, partial, valid := requestedRange(r.Header.Get("Range"), metadata.Size)
	if r.Header.Get("If-Range") != "" && r.Header.Get("If-Range") != metadata.ETag {
		start, end, partial, valid = 0, metadata.Size-1, false, true
	}
	if !valid {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", metadata.Size))
		writeProblem(w, http.StatusRequestedRangeNotSatisfiable, "invalid_range")
		return
	}
	w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	if partial {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, metadata.Size))
		w.WriteHeader(http.StatusPartialContent)
	}
	if r.Method == http.MethodHead {
		return
	}
	if err := s.writeRange(w, r.Context(), metadata, start, end); err != nil {
		return
	}
}

func (s *relayServer) writeRange(w io.Writer, ctx context.Context, metadata *shareMetadata, start, end int64) error {
	firstChunk := start / metadata.ChunkSize
	lastChunk := end / metadata.ChunkSize
	for index := firstChunk; index <= lastChunk; index++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		encrypted, err := os.ReadFile(s.chunkPath(metadata.ID, index))
		if err != nil {
			return err
		}
		plaintext, err := s.decryptChunk(metadata, index, encrypted)
		if err != nil {
			return err
		}
		chunkStart := index * metadata.ChunkSize
		lower := max64(start-chunkStart, 0)
		upper := min64(end-chunkStart+1, int64(len(plaintext)))
		if lower >= upper {
			continue
		}
		if _, err := w.Write(plaintext[lower:upper]); err != nil {
			return err
		}
	}
	return nil
}

func (s *relayServer) encryptChunk(metadata *shareMetadata, index int64, plaintext []byte) ([]byte, error) {
	nonce := make([]byte, s.block.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	aad := []byte(metadata.ID + ":" + strconv.FormatInt(index, 10))
	return s.block.Seal(nonce, nonce, plaintext, aad), nil
}

func (s *relayServer) decryptChunk(metadata *shareMetadata, index int64, encrypted []byte) ([]byte, error) {
	if len(encrypted) < s.block.NonceSize()+s.block.Overhead() {
		return nil, errors.New("truncated encrypted chunk")
	}
	nonce := encrypted[:s.block.NonceSize()]
	ciphertext := encrypted[s.block.NonceSize():]
	aad := []byte(metadata.ID + ":" + strconv.FormatInt(index, 10))
	return s.block.Open(nil, nonce, ciphertext, aad)
}

func (s *relayServer) loadMetadata() error {
	entries, err := os.ReadDir(filepath.Join(s.configuration.dataDirectory, "metadata"))
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(s.configuration.dataDirectory, "metadata", entry.Name()))
		if err != nil {
			return err
		}
		var metadata shareMetadata
		if err := json.Unmarshal(data, &metadata); err != nil {
			return fmt.Errorf("invalid relay metadata file %s", entry.Name())
		}
		if err := s.validateLoadedMetadata(entry, &metadata); err != nil {
			return fmt.Errorf("invalid relay metadata file %s: %w", entry.Name(), err)
		}
		if _, duplicate := s.byPublicHash[metadata.PublicTokenHash]; duplicate {
			return fmt.Errorf("duplicate relay public token hash in %s", entry.Name())
		}
		copy := metadata
		s.byID[copy.ID] = &copy
		s.byPublicHash[copy.PublicTokenHash] = &copy
		s.shareLocks[copy.ID] = &sync.RWMutex{}
	}
	return nil
}

func (s *relayServer) validateLoadedMetadata(entry os.DirEntry, metadata *shareMetadata) error {
	if entry.Type()&os.ModeType != 0 || (metadata.Version != 1 && metadata.Version != 2 && metadata.Version != 3 && metadata.Version != 4) ||
		!validOpaqueID(metadata.ID) || entry.Name() != metadata.ID+".json" ||
		!validSHA256Hex(metadata.PublicTokenHash) || !validSHA256Hex(metadata.ControlHash) ||
		metadata.PublicTokenHash == metadata.ControlHash ||
		metadata.Size <= 0 || metadata.Size > s.configuration.maximumFileSize ||
		metadata.ChunkSize < 256*1024 || metadata.ChunkSize > 32*1024*1024 ||
		metadata.CreatedAt.IsZero() ||
		!metadata.UploadExpiresAt.After(metadata.CreatedAt) || !validETag(metadata.ETag) {
		return errors.New("unsafe or inconsistent fields")
	}
	if metadata.Version == 4 {
		if metadata.EncryptionMode != clientEncryptionMode || metadata.FileName != "" ||
			metadata.ContentType != "application/octet-stream" || metadata.Title != "" ||
			metadata.Artist != "" || metadata.Album != "" || metadata.AudioFormat != "" ||
			metadata.Quality != "" || metadata.DurationSeconds != 0 {
			return errors.New("encrypted metadata exposes presentation fields")
		}
	} else if metadata.EncryptionMode != "" || metadata.FileName == "" ||
		sanitizeFileName(metadata.FileName) != metadata.FileName ||
		sanitizeContentType(metadata.ContentType) != metadata.ContentType {
		return errors.New("invalid legacy media fields")
	}
	if metadata.Version < 3 && metadata.Permanent {
		return errors.New("legacy metadata cannot be permanent")
	}
	if metadata.Permanent {
		if metadata.ShortCode || metadata.ExpiresAt != nil {
			return errors.New("permanent metadata has an expiration or short code")
		}
	} else if metadata.ExpiresAt == nil || !metadata.ExpiresAt.After(metadata.CreatedAt) {
		return errors.New("expiring metadata is missing a valid expiration")
	}
	if metadata.ShortCode && metadata.ExpiresAt.Sub(metadata.CreatedAt) > s.configuration.shortCodeMaximumTTL {
		return errors.New("short code expiration exceeds configured maximum")
	}
	if metadata.Version >= 2 && metadata.Version < 4 && (sanitizeDisplayText(metadata.Title, 160) != metadata.Title ||
		sanitizeDisplayText(metadata.Artist, 160) != metadata.Artist ||
		sanitizeDisplayText(metadata.Album, 160) != metadata.Album ||
		sanitizeDisplayText(metadata.AudioFormat, 32) != metadata.AudioFormat ||
		sanitizeDisplayText(metadata.Quality, 80) != metadata.Quality ||
		metadata.DurationSeconds < 0 || metadata.DurationSeconds > 7*24*60*60) {
		return errors.New("invalid presentation fields")
	}
	if metadata.Version >= 2 && (metadata.AllowPlayback == nil ||
		metadata.AllowDownload == nil || metadata.AllowImport == nil) {
		return errors.New("missing permission fields")
	}
	if metadata.PasswordSalt == "" && metadata.PasswordHash == "" {
		return nil
	}
	salt, saltError := base64.RawStdEncoding.DecodeString(metadata.PasswordSalt)
	hash, hashError := base64.RawStdEncoding.DecodeString(metadata.PasswordHash)
	if saltError != nil || hashError != nil || len(salt) != 16 || len(hash) != 32 {
		return errors.New("invalid password verifier")
	}
	return nil
}

func validSHA256Hex(value string) bool {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func validETag(value string) bool {
	return len(value) > 2 && value[0] == '"' && value[len(value)-1] == '"' &&
		validOpaqueID(value[1:len(value)-1])
}

func (s *relayServer) persistMetadata(metadata *shareMetadata) error {
	data, err := json.Marshal(metadata)
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(s.configuration.dataDirectory, "metadata", metadata.ID+".json"), data, 0o600)
}

func (s *relayServer) persistChunk(id string, index int64, data []byte) error {
	directory := filepath.Join(s.configuration.dataDirectory, "chunks", id)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	return atomicWrite(s.chunkPath(id, index), data, 0o600)
}

func (s *relayServer) reserveShortCode(length int, shareID string, expiresAt time.Time) (string, error) {
	for attempt := 0; attempt < shortCodeRetryLimit; attempt++ {
		code, err := s.shortCodeGenerator(length)
		if err != nil {
			return "", err
		}
		if !validShortCode(code) || len(code) != length {
			return "", errors.New("short code generator returned invalid data")
		}
		hash := tokenHash(code)
		path := s.shortCodeReservationPath(hash)
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		payload, marshalError := json.Marshal(map[string]string{
			"shareID":   shareID,
			"expiresAt": expiresAt.UTC().Format(time.RFC3339),
		})
		if marshalError == nil {
			_, marshalError = file.Write(payload)
		}
		if marshalError == nil {
			marshalError = file.Sync()
		}
		closeError := file.Close()
		if marshalError != nil || closeError != nil {
			_ = os.Remove(path)
			if marshalError != nil {
				return "", marshalError
			}
			return "", closeError
		}
		return code, nil
	}
	return "", errors.New("short code collision limit reached")
}

func (s *relayServer) shortCodeReservationPath(publicTokenHash string) string {
	return filepath.Join(s.configuration.dataDirectory, "short-code-reservations", publicTokenHash+".json")
}

func (s *relayServer) releaseShortCodeReservation(publicTokenHash string) {
	if validSHA256Hex(publicTokenHash) {
		_ = os.Remove(s.shortCodeReservationPath(publicTokenHash))
	}
}

func (s *relayServer) deactivateShortCode(metadata *shareMetadata) {
	if metadata == nil || !metadata.ShortCode {
		return
	}
	s.releaseShortCodeReservation(metadata.PublicTokenHash)
	s.mu.Lock()
	delete(s.byPublicHash, metadata.PublicTokenHash)
	s.mu.Unlock()
}

func (s *relayServer) chunkPath(id string, index int64) string {
	return filepath.Join(s.configuration.dataDirectory, "chunks", id, strconv.FormatInt(index, 10)+".bin")
}

func (s *relayServer) manifestPath(id string) string {
	return filepath.Join(s.configuration.dataDirectory, "manifests", id+".bin")
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".relay-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, path)
}

func (s *relayServer) metadataByID(id string) *shareMetadata {
	if !validOpaqueID(id) {
		return nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.byID[id]
}

func (s *relayServer) metadataByPublicToken(token string) *shareMetadata {
	if !validPublicIdentifier(token) {
		return nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.byPublicHash[tokenHash(token)]
}

func (s *relayServer) lockForShare(id string) *sync.RWMutex {
	s.mu.RLock()
	lock := s.shareLocks[id]
	s.mu.RUnlock()
	if lock != nil {
		return lock
	}
	// Only persisted, validated IDs reach this fallback. It protects startup
	// recovery if a future metadata migration inserts an entry in two phases.
	s.mu.Lock()
	defer s.mu.Unlock()
	if lock = s.shareLocks[id]; lock == nil {
		lock = &sync.RWMutex{}
		s.shareLocks[id] = lock
	}
	return lock
}

func (s *relayServer) authorizeControl(metadata *shareMetadata, r *http.Request) bool {
	return constantTokenHashEqual(tokenHash(bearerToken(r)), metadata.ControlHash)
}

func (s *relayServer) acquire(slots chan struct{}, w http.ResponseWriter) bool {
	select {
	case slots <- struct{}{}:
		return true
	default:
		w.Header().Set("Retry-After", "2")
		writeProblem(w, http.StatusServiceUnavailable, "busy")
		return false
	}
}

func (s *relayServer) release(slots chan struct{}) { <-slots }

func (s *relayServer) allowPublicRequest(r *http.Request) bool {
	peer := requestPeer(r)
	if !s.consumeRateWindow("public:"+peer, s.configuration.publicRequestsPerMinute, time.Minute) {
		return false
	}
	code := r.PathValue("token")
	if !validShortCode(code) {
		return true
	}
	if !s.consumeRateWindow("short-peer:"+peer, s.configuration.shortCodePeerRequestsPerMinute, time.Minute) {
		return false
	}
	key := s.shortCodeRateKey(r, code)
	if s.rateWindowCount("short-failure:"+key, s.configuration.shortCodeFailureWindow) >= s.configuration.shortCodeFailuresPerWindow {
		return false
	}
	return s.consumeRateWindow("short-request:"+key, s.configuration.shortCodeRequestsPerMinute, time.Minute)
}

func requestPeer(r *http.Request) string {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		peer = r.RemoteAddr
	}
	return peer
}

func (s *relayServer) shortCodeRateKey(r *http.Request, code string) string {
	return requestPeer(r) + ":" + tokenHash(code)
}

func (s *relayServer) recordShortCodeFailure(r *http.Request, code string) {
	if !validShortCode(code) {
		return
	}
	_ = s.consumeRateWindow(
		"short-failure:"+s.shortCodeRateKey(r, code),
		s.configuration.shortCodeFailuresPerWindow,
		s.configuration.shortCodeFailureWindow,
	)
}

func (s *relayServer) clearShortCodeFailures(r *http.Request, code string) {
	if !validShortCode(code) {
		return
	}
	s.rateMu.Lock()
	delete(s.rateWindows, "short-failure:"+s.shortCodeRateKey(r, code))
	s.rateMu.Unlock()
}

func (s *relayServer) rateWindowCount(key string, duration time.Duration) int {
	now := s.now()
	s.rateMu.Lock()
	defer s.rateMu.Unlock()
	window := s.rateWindows[key]
	if window == nil || now.Sub(window.startedAt) >= duration {
		return 0
	}
	return window.count
}

func (s *relayServer) consumeRateWindow(key string, limit int, duration time.Duration) bool {
	now := s.now()
	s.rateMu.Lock()
	defer s.rateMu.Unlock()
	cleanupAfter := s.configuration.shortCodeFailureWindow
	if cleanupAfter < time.Minute {
		cleanupAfter = time.Minute
	}
	if s.rateCleaned.IsZero() || now.Sub(s.rateCleaned) >= time.Minute {
		for candidateKey, candidate := range s.rateWindows {
			if now.Sub(candidate.startedAt) >= cleanupAfter {
				delete(s.rateWindows, candidateKey)
			}
		}
		s.rateCleaned = now
	}
	window := s.rateWindows[key]
	if window == nil || now.Sub(window.startedAt) >= duration {
		s.rateWindows[key] = &rateWindow{startedAt: now, count: 1}
		return true
	}
	if window.count >= limit {
		return false
	}
	window.count++
	return true
}

func (s *relayServer) cleanupExpired() {
	now := s.now().UTC()
	s.mu.RLock()
	allMetadata := make([]*shareMetadata, 0, len(s.byID))
	for _, metadata := range s.byID {
		allMetadata = append(allMetadata, metadata)
	}
	s.mu.RUnlock()
	for _, metadata := range allMetadata {
		shareLock := s.lockForShare(metadata.ID)
		shareLock.Lock()
		shouldDelete := metadata.revoked() ||
			(metadata.complete() && !metadata.activeAt(now)) ||
			(!metadata.complete() && !metadata.UploadExpiresAt.After(now))
		if !shouldDelete {
			shareLock.Unlock()
			continue
		}
		if !metadata.DataDeletedAt.IsZero() {
			s.deactivateShortCode(metadata)
			shareLock.Unlock()
			continue
		}
		_ = os.RemoveAll(filepath.Join(s.configuration.dataDirectory, "chunks", metadata.ID))
		_ = os.Remove(s.manifestPath(metadata.ID))
		metadata.DataDeletedAt = now
		_ = s.persistMetadata(metadata)
		s.deactivateShortCode(metadata)
		shareLock.Unlock()
	}
	s.cleanupExpiredImportTickets(now)
}

func (s *relayServer) cleanupLoop(registerShutdown func(func())) {
	ticker := time.NewTicker(time.Hour)
	registerShutdown(ticker.Stop)
	for range ticker.C {
		s.cleanupExpired()
	}
}

func requestedRange(header string, total int64) (start, end int64, partial, valid bool) {
	if total <= 0 {
		return 0, 0, false, false
	}
	if header == "" {
		return 0, total - 1, false, true
	}
	if !strings.HasPrefix(header, "bytes=") || strings.Contains(header, ",") {
		return 0, 0, false, false
	}
	parts := strings.SplitN(strings.TrimPrefix(header, "bytes="), "-", 2)
	if len(parts) != 2 {
		return 0, 0, false, false
	}
	if parts[0] == "" {
		suffix, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || suffix <= 0 {
			return 0, 0, false, false
		}
		if suffix > total {
			suffix = total
		}
		return total - suffix, total - 1, true, true
	}
	start, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || start < 0 || start >= total {
		return 0, 0, false, false
	}
	end = total - 1
	if parts[1] != "" {
		end, err = strconv.ParseInt(parts[1], 10, 64)
		if err != nil || end < start {
			return 0, 0, false, false
		}
		if end >= total {
			end = total - 1
		}
	}
	return start, end, true, true
}

func parseContentRange(value string) (start, end, total int64, ok bool) {
	if !strings.HasPrefix(value, "bytes ") {
		return 0, 0, 0, false
	}
	parts := strings.SplitN(strings.TrimPrefix(value, "bytes "), "/", 2)
	if len(parts) != 2 {
		return 0, 0, 0, false
	}
	bounds := strings.SplitN(parts[0], "-", 2)
	if len(bounds) != 2 {
		return 0, 0, 0, false
	}
	start, err1 := strconv.ParseInt(bounds[0], 10, 64)
	end, err2 := strconv.ParseInt(bounds[1], 10, 64)
	total, err3 := strconv.ParseInt(parts[1], 10, 64)
	return start, end, total, err1 == nil && err2 == nil && err3 == nil && start >= 0 && end >= start && total > end
}

func sanitizeFileName(value string) string {
	value = strings.TrimSpace(value)
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == '/' || r == '\\' || r == ':' {
			return '_'
		}
		return r
	}, value)
	if len([]rune(value)) > 180 {
		value = string([]rune(value)[:180])
	}
	if value == "." || value == ".." {
		return ""
	}
	return value
}

func sanitizeContentType(value string) string {
	mediaType, _, err := mime.ParseMediaType(value)
	if err != nil || (!strings.HasPrefix(mediaType, "audio/") && !strings.HasPrefix(mediaType, "video/") && mediaType != "application/octet-stream") {
		return "application/octet-stream"
	}
	return mediaType
}

func contentDisposition(fileName string) string {
	return contentDispositionMode(fileName, false)
}

func contentDispositionMode(fileName string, attachment bool) string {
	ascii := strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e || r == '"' || r == '\\' {
			return '_'
		}
		return r
	}, fileName)
	if strings.Trim(ascii, "_") == "" {
		ascii = "media"
	}
	disposition := "inline"
	if attachment {
		disposition = "attachment"
	}
	return fmt.Sprintf("%s; filename=\"%s\"; filename*=UTF-8''%s", disposition, ascii, url.PathEscape(fileName))
}

func bearerToken(r *http.Request) string {
	const prefix = "Bearer "
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(value, prefix))
}

func verifyPassword(metadata *shareMetadata, r *http.Request) bool {
	_, password, ok := r.BasicAuth()
	if !ok {
		return false
	}
	salt, err1 := base64.RawStdEncoding.DecodeString(metadata.PasswordSalt)
	expected, err2 := base64.RawStdEncoding.DecodeString(metadata.PasswordHash)
	if err1 != nil || err2 != nil {
		return false
	}
	actual := pbkdf2SHA256([]byte(password), salt, passwordIterations, len(expected))
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

func pbkdf2SHA256(password, salt []byte, iterations, keyLength int) []byte {
	hashLength := sha256.Size
	blocks := (keyLength + hashLength - 1) / hashLength
	result := make([]byte, 0, blocks*hashLength)
	for block := 1; block <= blocks; block++ {
		mac := hmac.New(sha256.New, password)
		mac.Write(salt)
		var counter [4]byte
		binary.BigEndian.PutUint32(counter[:], uint32(block))
		mac.Write(counter[:])
		u := mac.Sum(nil)
		t := append([]byte(nil), u...)
		for iteration := 1; iteration < iterations; iteration++ {
			mac = hmac.New(sha256.New, password)
			mac.Write(u)
			u = mac.Sum(nil)
			for index := range t {
				t[index] ^= u[index]
			}
		}
		result = append(result, t...)
	}
	return result[:keyLength]
}

func randomToken(byteCount int) (string, error) {
	data := make([]byte, byteCount)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func randomNumericCode(length int) (string, error) {
	if length < 4 || length > 6 {
		return "", errors.New("short code length must be between four and six digits")
	}
	maximum := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(length)), nil)
	value, err := rand.Int(rand.Reader, maximum)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%0*d", length, value.Int64()), nil
}

func tokenHash(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func constantTokenEqual(lhs, rhs string) bool {
	lhsHash := sha256.Sum256([]byte(lhs))
	rhsHash := sha256.Sum256([]byte(rhs))
	return subtle.ConstantTimeCompare(lhsHash[:], rhsHash[:]) == 1
}

func constantTokenHashEqual(lhsHash, rhsHash string) bool {
	return subtle.ConstantTimeCompare([]byte(lhsHash), []byte(rhsHash)) == 1
}

func validOpaqueID(value string) bool {
	if len(value) < 16 || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func validShortCode(value string) bool {
	if len(value) < 4 || len(value) > 6 {
		return false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func validPublicIdentifier(value string) bool {
	return validOpaqueID(value) || validShortCode(value)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, target any) error {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maximumJSONBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeProblem(w, http.StatusBadRequest, "invalid_json")
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeProblem(w, http.StatusBadRequest, "invalid_json")
		return errors.New("multiple JSON values")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeProblem(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

func min64(lhs, rhs int64) int64 {
	if lhs < rhs {
		return lhs
	}
	return rhs
}

func max64(lhs, rhs int64) int64 {
	if lhs > rhs {
		return lhs
	}
	return rhs
}
