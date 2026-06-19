package api

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/hanomi/backend/internal/store"
)

// HealthChecker is the subset of the store the health route needs.
type HealthChecker interface {
	Ping(context.Context) error
	WorkerLastSeen(context.Context) (time.Time, bool, error)
}

// RegisterHealth wires GET /healthz. 200 only if the DB is reachable.
// Worker freshness is reported but does NOT fail the backend's own health.
func RegisterHealth(r *gin.Engine, h HealthChecker) {
	r.GET("/healthz", func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if err := h.Ping(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"status": "db_unavailable"})
			return
		}
		workerOnline := false
		if ts, ok, err := h.WorkerLastSeen(ctx); err == nil && ok {
			workerOnline = time.Since(ts) < 60*time.Second
		}
		c.JSON(http.StatusOK, gin.H{"status": "ok", "worker_online": workerOnline})
	})
}

// RegisterLeads wires the demo-request ("Try Hanomi") endpoints.
func RegisterLeads(r *gin.Engine, s *store.Store) {
	r.POST("/leads", func(c *gin.Context) {
		var body struct {
			Name    string `json:"name" binding:"required"`
			Email   string `json:"email" binding:"required,email"`
			Company string `json:"company"`
			Message string `json:"message"`
		}
		if err := c.ShouldBindJSON(&body); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		company := optional(body.Company)
		message := optional(body.Message)
		l, err := s.CreateLead(c.Request.Context(), body.Name, body.Email, company, message)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusCreated, l)
	})
	r.GET("/leads", func(c *gin.Context) {
		ls, err := s.ListLeads(c.Request.Context())
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, ls)
	})
	r.GET("/leads/:id", func(c *gin.Context) {
		id, err := strconv.ParseInt(c.Param("id"), 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "bad id"})
			return
		}
		l, err := s.GetLead(c.Request.Context(), id)
		if err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "not found"})
			return
		}
		c.JSON(http.StatusOK, l)
	})
}

// optional turns an empty string into a nil pointer (for nullable columns).
func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
