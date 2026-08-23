package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

var scopePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

func main() {
	addr := flag.String("addr", "127.0.0.1:8787", "HTTP listen address")
	runtimeDir := flag.String("runtime-dir", envOr("XDG_RUNTIME_DIR", filepath.Join(os.TempDir(), fmt.Sprintf("runtime-%d", os.Getuid()))), "directory containing agentd sockets")
	staticDir := flag.String("static-dir", "../web/dist", "built web app directory")
	flag.Parse()
	if !isLoopbackAddress(*addr) {
		log.Fatalf("refusing non-loopback listen address %q; expose the bridge through Tailscale Serve", *addr)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /scopes", scopesHandler(*runtimeDir))
	mux.HandleFunc("GET /ws", websocketHandler(*runtimeDir))
	mux.Handle("/", spaHandler(*staticDir))

	server := &http.Server{Addr: *addr, Handler: logRequests(mux), ReadHeaderTimeout: 5 * time.Second}
	log.Printf("cockpit bridge listening on http://%s", *addr)
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func isLoopbackAddress(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
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
	return func(w http.ResponseWriter, _ *http.Request) {
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
	CheckOrigin: func(r *http.Request) bool {
		return r.Header.Get("Origin") == "" || strings.HasPrefix(r.Header.Get("Origin"), "https://") || strings.HasPrefix(r.Header.Get("Origin"), "http://127.0.0.1") || strings.HasPrefix(r.Header.Get("Origin"), "http://localhost")
	},
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
		log.Printf("%s %s", r.Method, r.URL.RequestURI())
		next.ServeHTTP(w, r)
	})
}
