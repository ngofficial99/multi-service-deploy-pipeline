package store

import (
	"context"
	"database/sql"
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
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	Company   *string   `json:"company"`
	Message   *string   `json:"message"`
	Status    string    `json:"status"`
	Error     *string   `json:"error"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Store struct {
	pool *pgxpool.Pool
	dsn  string
}

func New(ctx context.Context, dsn string) (*Store, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	return &Store{pool: pool, dsn: dsn}, nil
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

func (s *Store) CreateLead(ctx context.Context, name, email string, company, message *string) (Lead, error) {
	var l Lead
	err := s.pool.QueryRow(ctx,
		`INSERT INTO leads (name, email, company, message) VALUES ($1, $2, $3, $4)
		 RETURNING id, name, email, company, message, status, error, created_at, updated_at`,
		name, email, company, message).
		Scan(&l.ID, &l.Name, &l.Email, &l.Company, &l.Message, &l.Status, &l.Error, &l.CreatedAt, &l.UpdatedAt)
	return l, err
}

func (s *Store) ListLeads(ctx context.Context) ([]Lead, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, name, email, company, message, status, error, created_at, updated_at
		 FROM leads ORDER BY id DESC LIMIT 100`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Lead{}
	for rows.Next() {
		var l Lead
		if err := rows.Scan(&l.ID, &l.Name, &l.Email, &l.Company, &l.Message, &l.Status, &l.Error, &l.CreatedAt, &l.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

func (s *Store) GetLead(ctx context.Context, id int64) (Lead, error) {
	var l Lead
	err := s.pool.QueryRow(ctx,
		`SELECT id, name, email, company, message, status, error, created_at, updated_at
		 FROM leads WHERE id=$1`, id).
		Scan(&l.ID, &l.Name, &l.Email, &l.Company, &l.Message, &l.Status, &l.Error, &l.CreatedAt, &l.UpdatedAt)
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
