package config

import (
	"fmt"
	"os"
)

// Config is loaded purely from environment so that secrets are injected by the
// reconciler at deploy time (Secret Manager -> 0600 env file), never baked in.
type Config struct {
	Port        string
	DatabaseURL string
}

func Load() (Config, error) {
	c := Config{
		Port:        getenv("PORT", "8080"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL is required")
	}
	return c, nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
