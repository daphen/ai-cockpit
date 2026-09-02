package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestScopesHandlerReportsOrchestratorHolder(t *testing.T) {
	runtimeDir := t.TempDir()
	holderFile := filepath.Join(t.TempDir(), "orchestrator-holder")
	if err := os.WriteFile(holderFile, []byte("lovable\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(runtimeDir, "agentd-lovable.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	response := httptest.NewRecorder()
	scopesHandler(runtimeDir, holderFile).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/scopes", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d", response.Code)
	}
	if got := response.Header().Get("X-Cockpit-Orchestrator"); got != "lovable" {
		t.Fatalf("holder = %q", got)
	}
}

func TestUploadHandler(t *testing.T) {
	runtimeDir := t.TempDir()
	uploadDir := t.TempDir()
	listener, err := net.Listen("unix", filepath.Join(runtimeDir, "agentd-work.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	request := httptest.NewRequest(http.MethodPost, "/upload?scope=work", bytes.NewBufferString("png bytes"))
	request.Header.Set("Content-Type", "image/png")
	response := httptest.NewRecorder()
	uploadHandler(runtimeDir, uploadDir).ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %q", response.Code, response.Body.String())
	}
	var result struct {
		Path string `json:"path"`
		Size int64  `json:"size"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(result.Path) != uploadDir || filepath.Ext(result.Path) != ".png" || result.Size != 9 {
		t.Fatalf("unexpected result: %+v", result)
	}
	data, err := os.ReadFile(result.Path)
	if err != nil || string(data) != "png bytes" {
		t.Fatalf("stored data = %q, err = %v", data, err)
	}
	info, err := os.Stat(result.Path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("stored mode = %v", info.Mode().Perm())
	}
}

func TestUploadHandlerRejectsInvalidInput(t *testing.T) {
	runtimeDir := t.TempDir()
	uploadDir := t.TempDir()
	listener, err := net.Listen("unix", filepath.Join(runtimeDir, "agentd-work.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	for name, test := range map[string]struct {
		scope       string
		contentType string
		body        string
		want        int
	}{
		"invalid scope": {"../work", "image/png", "x", http.StatusBadRequest},
		"missing scope": {"personal", "image/png", "x", http.StatusBadGateway},
		"bad type":      {"work", "image/heic", "x", http.StatusUnsupportedMediaType},
		"empty":         {"work", "image/png", "", http.StatusBadRequest},
	} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/upload?scope="+test.scope, strings.NewReader(test.body))
			request.Header.Set("Content-Type", test.contentType)
			response := httptest.NewRecorder()
			uploadHandler(runtimeDir, uploadDir).ServeHTTP(response, request)
			if response.Code != test.want {
				t.Fatalf("status = %d, want %d", response.Code, test.want)
			}
		})
	}
}
