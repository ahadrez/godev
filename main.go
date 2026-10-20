package main

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
)

func main() {
	// Environment name shown in the page heading, e.g. development, test, production
	env := os.Getenv("APP_ENV")
	if env == "" {
		env = "development"
	}

	tmpl := template.Must(template.ParseFiles("public/index.html"))

	// Render index.html from public/ folder with the current environment
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if err := tmpl.Execute(w, struct{ Env string }{Env: env}); err != nil {
			http.Error(w, "failed to render page", http.StatusInternalServerError)
		}
	})

	// Serve static assets from public/
	fs := http.FileServer(http.Dir("public/"))
	http.Handle("/static/", http.StripPrefix("/static/", fs))

	fmt.Printf("Started server on http://localhost:8080 (APP_ENV=%s)\n", env)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
