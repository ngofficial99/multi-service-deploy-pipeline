package store

import (
	"context"
	"database/sql"
	"os"
	"strconv"
	"time"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/hanomi/backend/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// Lead is a demo request submitted via the "Try Hanomi" form.
type Lead struct {
	ID           int64      `json:"id"`
	FirstName    string     `json:"first_name"`
	Phone        string     `json:"phone"`
	Email        string     `json:"email"`
	Company      string     `json:"company"`
	Status       string     `json:"status"`
	InviteSent   bool       `json:"invite_sent"`
	InviteSentAt *time.Time `json:"invite_sent_at"`
	Error        *string    `json:"error"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

type Store struct {
	pool *pgxpool.Pool
	dsn  string
}

func New(ctx context.Context, dsn string) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	// Bound the per-instance pool so that scaling the backend horizontally does
	// NOT exhaust Cloud SQL's max_connections. With N instances the DB sees at
	// most N * DB_MAX_CONNS connections, so this cap is what makes "min=20,
	// max=100" safe. Tune DB_MAX_CONNS against the DB tier's connection limit
	// (and/or front the DB with PgBouncer — see README scaling notes).
	cfg.MaxConns = int32(envInt("DB_MAX_CONNS", 10))
	cfg.MinConns = int32(envInt("DB_MIN_CONNS", 0))
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.MaxConnLifetime = 30 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &Store{pool: pool, dsn: dsn}, nil
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func (s *Store) Close() { s.pool.Close() }

// Migrate runs embedded migrations. Called on deploy BEFORE serving traffic;
// fail-closed so a bad migration aborts the deploy.
func (s *Store) Migrate() error {
	src, err := iofs.New(migrations.FS, ".")
	if err != nil {
		return err
	}
	sqlDB, err := sql.Open("pgx", s.dsn)
	if err != nil {
		return err
	}
	defer sqlDB.Close()
	driver, err := postgres.WithInstance(sqlDB, &postgres.Config{})
	if err != nil {
		return err
	}
	m, err := migrate.NewWithInstance("iofs", src, "postgres", driver)
	if err != nil {
		return err
	}
	if err := m.Up(); err != nil && err != migrate.ErrNoChange {
		return err
	}
	return nil
}

func (s *Store) CreateLead(ctx context.Context, firstName, phone, email, company string) (Lead, error) {
	var l Lead
	err := s.pool.QueryRow(ctx,
		`INSERT INTO leads (first_name, phone, email, company) VALUES ($1, $2, $3, $4)
		 RETURNING id, first_name, phone, email, company, status, invite_sent, invite_sent_at, error, created_at, updated_at`,
		firstName, phone, email, company).
		Scan(&l.ID, &l.FirstName, &l.Phone, &l.Email, &l.Company, &l.Status, &l.InviteSent, &l.InviteSentAt, &l.Error, &l.CreatedAt, &l.UpdatedAt)
	return l, err
}

func (s *Store) ListLeads(ctx context.Context) ([]Lead, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, first_name, phone, email, company, status, invite_sent, invite_sent_at, error, created_at, updated_at
		 FROM leads ORDER BY id DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Lead{}
	for rows.Next() {
		var l Lead
		if err := rows.Scan(&l.ID, &l.FirstName, &l.Phone, &l.Email, &l.Company, &l.Status, &l.InviteSent, &l.InviteSentAt, &l.Error, &l.CreatedAt, &l.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

func (s *Store) GetLead(ctx context.Context, id int64) (Lead, error) {
	var l Lead
	err := s.pool.QueryRow(ctx,
		`SELECT id, first_name, phone, email, company, status, invite_sent, invite_sent_at, error, created_at, updated_at
		 FROM leads WHERE id=$1`, id).
		Scan(&l.ID, &l.FirstName, &l.Phone, &l.Email, &l.Company, &l.Status, &l.InviteSent, &l.InviteSentAt, &l.Error, &l.CreatedAt, &l.UpdatedAt)
	return l, err
}

// Ping checks DB connectivity (used by /healthz).
func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

// WorkerLastSeen returns the freshest worker heartbeat time, or false if none.
func (s *Store) WorkerLastSeen(ctx context.Context) (time.Time, bool, error) {
	var ts sql.NullTime
	err := s.pool.QueryRow(ctx,
		`SELECT max(last_seen) FROM worker_heartbeat`).Scan(&ts)
	if err != nil {
		return time.Time{}, false, err
	}
	if !ts.Valid {
		return time.Time{}, false, nil
	}
	return ts.Time, true, nil
}
