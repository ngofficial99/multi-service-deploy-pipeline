package store

import (
	"context"
	"os"
	"testing"
)

// Requires DATABASE_URL pointing at a test Postgres (dev/docker-compose.yml).
func testDSN(t *testing.T) string {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	return dsn
}

func TestMigrateAndCreateLead(t *testing.T) {
	ctx := context.Background()
	s, err := New(ctx, testDSN(t))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer s.Close()
	if err := s.Migrate(); err != nil {
		t.Fatalf("Migrate: %v", err)
	}
	lead, err := s.CreateLead(ctx, "Jane", "(201) 555-0123", "jane@example.com", "Acme Corporation")
	if err != nil {
		t.Fatalf("CreateLead: %v", err)
	}
	if lead.ID == 0 || lead.Status != "pending" || lead.InviteSent {
		t.Fatalf("unexpected lead: %+v", lead)
	}
}
