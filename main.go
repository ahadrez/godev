package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strings"
)

// SecretStatus describes the demo secret mounted by the Secrets Store CSI
// driver. Only a masked preview and a fingerprint are exposed by default;
// the full value is included only when ALLOW_REVEAL=true (demo mode).
type SecretStatus struct {
	Loaded      bool   `json:"loaded"`
	Masked      string `json:"masked"`
	Length      int    `json:"length"`
	Fingerprint string `json:"fingerprint"` // sha256 prefix: changes on rotation, never reveals the value
	Source      string `json:"source"`
	Resource    string `json:"resource,omitempty"` // GCP resource name, e.g. projects/x/secrets/y
	Error       string `json:"error,omitempty"`
	Value       string `json:"value,omitempty"` // only populated when reveal is allowed
}

// readSecret re-reads the mounted secret on every call so a rotated version
// shows up without a restart (the CSI driver updates the file in place).
func readSecret(path, resource string, reveal bool) SecretStatus {
	s := SecretStatus{Source: path, Resource: resource}
	data, err := os.ReadFile(path)
	if err != nil {
		s.Error = "secret not mounted"
		return s
	}
	value := strings.TrimSpace(string(data))
	sum := sha256.Sum256([]byte(value))
	s.Loaded = true
	s.Length = len(value)
	s.Masked = mask(value)
	s.Fingerprint = hex.EncodeToString(sum[:])[:12]
	if reveal {
		s.Value = value
	}
	return s
}

// mask keeps the first and last two characters of the secret and hides the
// rest, enough to prove the value arrived without printing it.
func mask(v string) string {
	if len(v) <= 4 {
		return strings.Repeat("•", len(v))
	}
	return v[:2] + strings.Repeat("•", len(v)-4) + v[len(v)-2:]
}

func main() {
	// Environment name shown in the page heading, e.g. development, test, production
	env := os.Getenv("APP_ENV")
	if env == "" {
		env = "development"
	}

	// Path of the secret file mounted by the Secrets Store CSI driver
	secretFile := os.Getenv("SECRET_FILE")
	if secretFile == "" {
		secretFile = "/var/secrets/godev-demo"
	}

	// GCP resource name shown as provenance (display only)
	secretResource := os.Getenv("SECRET_RESOURCE")

	// Demo mode: allow the page's hold-to-reveal button. Off by default so
	// the pattern stays production-safe (the value never leaves the pod).
	allowReveal := os.Getenv("ALLOW_REVEAL") == "true"

	tmpl := template.Must(template.ParseFiles("public/index.html"))

	// Render index.html from public/ folder with the current environment
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		data := struct {
			Env         string
			Secret      SecretStatus
			AllowReveal bool
		}{Env: env, Secret: readSecret(secretFile, secretResource, false), AllowReveal: allowReveal}
		if err := tmpl.Execute(w, data); err != nil {
			http.Error(w, "failed to render page", http.StatusInternalServerError)
		}
	})

	// Live status for the page's polling JS. Includes the raw value only
	// when ALLOW_REVEAL=true.
	http.HandleFunc("/api/secret", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(readSecret(secretFile, secretResource, allowReveal))
	})

	// Serve static assets from public/
	fs := http.FileServer(http.Dir("public/"))
	http.Handle("/static/", http.StripPrefix("/static/", fs))

	fmt.Printf("Started server on http://localhost:8080 (APP_ENV=%s, SECRET_FILE=%s, ALLOW_REVEAL=%v)\n", env, secretFile, allowReveal)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
