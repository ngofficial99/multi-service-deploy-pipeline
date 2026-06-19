package main

import (
	"context"
	"log"

	"github.com/gin-gonic/gin"
	"github.com/hanomi/backend/internal/api"
	"github.com/hanomi/backend/internal/config"
	"github.com/hanomi/backend/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	ctx := context.Background()
	s, err := store.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer s.Close()

	// Fail-closed migrations: abort startup if they fail.
	if err := s.Migrate(); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	r := gin.New()
	r.Use(gin.Recovery())
	api.RegisterHealth(r, s)
	api.RegisterLeads(r, s)

	log.Printf("backend listening on :%s", cfg.Port)
	if err := r.Run(":" + cfg.Port); err != nil {
		log.Fatalf("run: %v", err)
	}
}
