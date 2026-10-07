package httpapi

import (
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// routeLabel converte o padrão do ServeMux ("POST /users") em um label estável ("/users").
// Rotas não encontradas viram "unmatched" (evita explosão de cardinalidade).
func routeLabel(pattern string) string {
	if pattern == "" {
		return "unmatched"
	}
	if _, path, ok := strings.Cut(pattern, " "); ok {
		return path
	}
	return pattern
}

// instrument aplica recuperação de panic, métricas e log de acesso (sem corpo, sem dados sensíveis).
func (s *Server) instrument(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		s.metrics.inFlight.Inc()

		defer func() {
			s.metrics.inFlight.Dec()
			if p := recover(); p != nil {
				s.log.Error("panic recuperado", "panic", p, "method", r.Method, "path", r.URL.Path)
				if rec.status == http.StatusOK {
					writeError(rec, http.StatusInternalServerError, "internal_error", "erro interno")
				}
			}
			// r.Pattern é preenchido pelo ServeMux durante next.ServeHTTP.
			route := routeLabel(r.Pattern)
			elapsed := time.Since(start)
			s.metrics.requests.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
			s.metrics.duration.WithLabelValues(r.Method, route).Observe(elapsed.Seconds())
			s.log.LogAttrs(r.Context(), slog.LevelInfo, "request",
				slog.String("method", r.Method),
				slog.String("route", route),
				slog.Int("status", rec.status),
				slog.Duration("duration", elapsed),
			)
		}()

		next.ServeHTTP(rec, r)
	})
}
