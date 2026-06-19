package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

type fakeStore struct{ pingErr error }

func (f fakeStore) Ping(context.Context) error { return f.pingErr }
func (f fakeStore) WorkerLastSeen(context.Context) (time.Time, bool, error) {
	return time.Now(), true, nil
}

func TestHealthzOK(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	RegisterHealth(r, fakeStore{})
	w := httptest.NewRecorder()
	req, _ := http.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d body=%s", w.Code, w.Body.String())
	}
}

func TestHealthzDBDown(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	RegisterHealth(r, fakeStore{pingErr: context.DeadlineExceeded})
	w := httptest.NewRecorder()
	req, _ := http.NewRequest(http.MethodGet, "/healthz", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d", w.Code)
	}
}
