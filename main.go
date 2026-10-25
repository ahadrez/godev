package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"strings"
)

// SecretStatus describes the demo secret mounted by the Secrets Store CSI
// driver. Only a masked preview is ever exposed to the page.
type SecretStatus struct {
	Loaded bool
	Masked string
	Length int
	Source string
	Error  string
}

// readSecret re-reads the mounted secret on every request so a rotated
// version shows up without a restart (the CSI driver updates the file).
func readSecret(path string) SecretStatus {
	s := SecretStatus{Source: path}
	data, err := os.ReadFile(path)
	if err != nil {
		s.Error = "secret not mounted"
		return s
	}
	value := strings.TrimSpace(string(data))
	s.Loaded = true
	s.Length = len(value)
	s.Masked = mask(value)
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

	tmpl := template.Must(template.ParseFiles("public/index.html"))

	// Render index.html from public/ folder with the current environment
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		data := struct {
			Env    string
			Secret SecretStatus
		}{Env: env, Secret: readSecret(secretFile)}
		if err := tmpl.Execute(w, data); err != nil {
			http.Error(w, "failed to render page", http.StatusInternalServerError)
		}
	})

	// Serve static assets from public/
	fs := http.FileServer(http.Dir("public/"))
	http.Handle("/static/", http.StripPrefix("/static/", fs))

	fmt.Printf("Started server on http://localhost:8080 (APP_ENV=%s, SECRET_FILE=%s)\n", env, secretFile)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
