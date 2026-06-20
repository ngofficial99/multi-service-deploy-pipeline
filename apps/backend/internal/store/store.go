package store

import (
	"context"
	"database/sql"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
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
	pool      *pgxpool.Pool   // primary: all writes + migrations
	readPools []*pgxpool.Pool // optional read replicas (reads round-robin)
	rr        atomic.Uint32   // round-robin cursor
	dsn       string
}

// newPool builds a connection pool with a bounded size so that scaling the
// backend horizontally cannot exhaust Cloud SQL connections. With N instances
// the DB sees at most N * DB_MAX_CONNS connections — the cap that makes
// "min=20, max=100" safe. (Pair with PgBouncer at very high N — see README.)
func newPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = int32(envInt("DB_MAX_CONNS", 10))
	cfg.MinConns = int32(envInt("DB_MIN_CONNS", 0))
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.MaxConnLifetime = 30 * time.Minute
	return pgxpool.NewWithConfig(ctx, cfg)
}

func New(ctx context.Context, dsn string) (*Store, error) {
	primary, err := newPool(ctx, dsn)
	if err != nil {
		return nil, err
	}
	s := &Store{pool: primary, dsn: dsn}

	// Optional read replicas: comma-separated DSNs in READ_DATABASE_URLS.
	// Reads (List/Get) round-robin across them; writes always hit the primary.
	// This is what lets the data tier serve read-heavy 100k traffic by adding
	// replicas. Empty => all reads go to the primary (single-DB demo default).
	for _, rdsn := range splitNonEmpty(os.Getenv("READ_DATABASE_URLS"), ",") {
		rp, err := newPool(ctx, strings.TrimSpace(rdsn))
		if err != nil {
			return nil, err
		}
		s.readPools = append(s.readPools, rp)
	}
	return s, nil
}

// reader returns the pool to use for read queries: a replica (round-robin) if
// any are configured, otherwise the primary.
func (s *Store) reader() *pgxpool.Pool {
	n := len(s.readPools)
	if n == 0 {
		return s.pool
	}
	i := int(s.rr.Add(1)-1) % n
	return s.readPools[i]
}

func splitNonEmpty(s, sep string) []string {
	out := []string{}
	for _, p := range strings.Split(s, sep) {
		if strings.TrimSpace(p) != "" {
			out = append(out, p)
		}
	}
	return out
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func (s *Store) Close() {
	s.pool.Close()
	for _, rp := range s.readPools {
		rp.Close()
	}
}

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
	rows, err := s.reader().Query(ctx,
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
	err := s.reader().QueryRow(ctx,
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
