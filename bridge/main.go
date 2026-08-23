package main

import (
	"bufio"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

var scopePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

func main() {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Fatal(err)
	}
	addr := flag.String("addr", "127.0.0.1:8787", "HTTP listen address")
	runtimeDir := flag.String("runtime-dir", envOr("XDG_RUNTIME_DIR", filepath.Join(os.TempDir(), fmt.Sprintf("runtime-%d", os.Getuid()))), "directory containing agentd sockets")
	staticDir := flag.String("static-dir", "../web/dist", "built web app directory")
	tokenFile := flag.String("token-file", filepath.Join(home, ".config/cockpit/bridge-token"), "bearer token file")
	flag.Parse()
	if !isAllowedAddress(*addr) {
		log.Fatalf("refusing listen address %q; only loopback and routed 10.x addresses are allowed", *addr)
	}
	token, err := loadToken(*tokenFile)
	if err != nil {
		log.Fatalf("load bearer token: %v", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/scopes", requireToken(token, scopesHandler(*runtimeDir)))
	mux.Handle("/ws", requireToken(token, websocketHandler(*runtimeDir)))
	mux.Handle("/", spaHandler(*staticDir))

	server := &http.Server{Addr: *addr, Handler: logRequests(mux), ReadHeaderTimeout: 5 * time.Second}
	log.Printf("cockpit bridge listening on http://%s", *addr)
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func isAllowedAddress(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	v4 := ip.To4()
	return v4 != nil && v4[0] == 10
}

func loadToken(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err == nil {
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, err
		}
		return validateToken(data)
	}
	if !os.IsNotExist(err) {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	generated, err := generateToken()
	if err != nil {
		return nil, err
	}
	token, err := validateToken(generated)
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if os.IsExist(err) {
		return loadToken(path)
	}
	if err != nil {
		return nil, err
	}
	if _, err := file.Write(append(token, '\n')); err != nil {
		_ = file.Close()
		return nil, err
	}
	if err := file.Close(); err != nil {
		return nil, err
	}
	return token, nil
}

func generateToken() ([]byte, error) {
	commands := [][]string{
		{"openssl", "rand", "-hex", "32"},
		{"nix", "shell", "nixpkgs#openssl", "-c", "openssl", "rand", "-hex", "32"},
	}
	var lastErr error
	for _, command := range commands {
		output, err := exec.Command(command[0], command[1:]...).Output()
		if err == nil {
			return output, nil
		}
		lastErr = err
	}
	return nil, fmt.Errorf("openssl rand: %w", lastErr)
}

func validateToken(data []byte) ([]byte, error) {
	token := strings.TrimSpace(string(data))
	if matched, _ := regexp.MatchString(`^[0-9a-f]{64}$`, token); !matched {
		return nil, errors.New("token must be 64 lowercase hexadecimal characters")
	}
	return []byte(token), nil
}

func requireToken(token []byte, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		candidate := r.URL.Query().Get("token")
		if header := r.Header.Get("Authorization"); strings.HasPrefix(header, "Bearer ") {
			candidate = strings.TrimPrefix(header, "Bearer ")
		}
		if subtle.ConstantTimeCompare([]byte(candidate), token) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func sockets(runtimeDir string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(runtimeDir, "agentd-*.sock"))
	if err != nil {
		return nil, err
	}
	scopes := make([]string, 0, len(matches))
	for _, path := range matches {
		info, err := os.Stat(path)
		if err == nil && info.Mode()&os.ModeSocket != 0 {
			scopes = append(scopes, strings.TrimSuffix(strings.TrimPrefix(filepath.Base(path), "agentd-"), ".sock"))
		}
	}
	sort.Strings(scopes)
	return scopes, nil
}

func scopesHandler(runtimeDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		scopes, err := sockets(runtimeDir)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(scopes)
	}
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  64 * 1024,
	WriteBufferSize: 64 * 1024,
}

func websocketHandler(runtimeDir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		scope := r.URL.Query().Get("scope")
		if !scopePattern.MatchString(scope) {
			http.Error(w, "invalid scope", http.StatusBadRequest)
			return
		}
		path := filepath.Join(runtimeDir, "agentd-"+scope+".sock")
		unixConn, err := net.DialTimeout("unix", path, 2*time.Second)
		if err != nil {
			http.Error(w, "scope unavailable", http.StatusBadGateway)
			return
		}
		defer unixConn.Close()

		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()

		done := make(chan error, 2)
		go unixToWebSocket(ws, unixConn, done)
		go webSocketToUnix(ws, unixConn, done)
		<-done
	}
}

func unixToWebSocket(ws *websocket.Conn, unixConn net.Conn, done chan<- error) {
	scanner := bufio.NewScanner(unixConn)
	scanner.Buffer(make([]byte, 64*1024), 32*1024*1024)
	for scanner.Scan() {
		if err := ws.WriteMessage(websocket.TextMessage, scanner.Bytes()); err != nil {
			done <- err
			return
		}
	}
	done <- scanner.Err()
}

func webSocketToUnix(ws *websocket.Conn, unixConn net.Conn, done chan<- error) {
	for {
		kind, payload, err := ws.ReadMessage()
		if err != nil {
			done <- err
			return
		}
		if kind != websocket.TextMessage || len(payload) == 0 || len(payload) > 32*1024*1024 {
			continue
		}
		payload = append(bytesWithoutTrailingNewlines(payload), '\n')
		if _, err := unixConn.Write(payload); err != nil {
			done <- err
			return
		}
	}
}

func bytesWithoutTrailingNewlines(data []byte) []byte {
	for len(data) > 0 && (data[len(data)-1] == '\n' || data[len(data)-1] == '\r') {
		data = data[:len(data)-1]
	}
	return data
}

func spaHandler(root string) http.Handler {
	files := http.FileServer(http.Dir(root))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := filepath.Join(root, filepath.Clean(r.URL.Path))
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			files.ServeHTTP(w, r)
			return
		}
		index, err := os.Open(filepath.Join(root, "index.html"))
		if err != nil {
			if os.IsNotExist(err) {
				http.Error(w, "web app is not built", http.StatusServiceUnavailable)
				return
			}
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer index.Close()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		http.ServeContent(w, r, "index.html", time.Time{}, index)
	})
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.Path)
		next.ServeHTTP(w, r)
	})
}
