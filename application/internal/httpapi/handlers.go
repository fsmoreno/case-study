// Package httpapi expõe a API REST, health checks e métricas.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/crypto/bcrypt"

	"estuda-api/internal/store"
)

const (
	maxBodyBytes    = 1 << 16 // 64 KiB
	defaultLimit    = 20
	maxLimit        = 100
	maxNameLen      = 100
	maxEmailLen     = 255
	minPasswordLen  = 8
	maxPasswordLen  = 72 // limite do bcrypt (bytes)
	readyzTimeout   = 2 * time.Second
	requestDBTimout = 5 * time.Second
)

type Server struct {
	store    store.Store
	metrics  *Metrics
	log      *slog.Logger
	hashCost int
	draining atomic.Bool
}

func NewServer(st store.Store, m *Metrics, log *slog.Logger, hashCost int) *Server {
	return &Server{store: st, metrics: m, log: log, hashCost: hashCost}
}

// SetDraining faz o /readyz responder 503 (usado no início do shutdown gracioso).
func (s *Server) SetDraining() { s.draining.Store(true) }

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /users", s.createUser)
	mux.HandleFunc("GET /users", s.listUsers)
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.metrics.Registry, promhttp.HandlerOpts{}))
	return s.instrument(mux)
}

type createUserRequest struct {
	Name     string `json:"name"`
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (s *Server) createUser(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()

	var req createUserRequest
	if err := dec.Decode(&req); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "payload_too_large", "corpo da requisição muito grande")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_payload", "JSON inválido")
		return
	}

	name := strings.TrimSpace(req.Name)
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if msg := validate(name, email, req.Password); msg != "" {
		writeError(w, http.StatusBadRequest, "invalid_payload", msg)
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), s.hashCost)
	if err != nil {
		s.log.Error("falha ao gerar hash", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "erro interno")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), requestDBTimout)
	defer cancel()
	u, err := s.store.CreateUser(ctx, name, email, string(hash))
	switch {
	case errors.Is(err, store.ErrEmailExists):
		writeError(w, http.StatusConflict, "email_already_exists", "email já cadastrado")
	case err != nil:
		s.metrics.dbErrors.WithLabelValues("create_user").Inc()
		s.log.Error("falha ao criar usuário", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "erro interno")
	default:
		writeJSON(w, http.StatusCreated, u)
	}
}

func (s *Server) listUsers(w http.ResponseWriter, r *http.Request) {
	limit, err := intParam(r, "limit", defaultLimit)
	if err != nil || limit < 1 || limit > maxLimit {
		writeError(w, http.StatusBadRequest, "invalid_query", "limit deve estar entre 1 e "+strconv.Itoa(maxLimit))
		return
	}
	offset, err := intParam(r, "offset", 0)
	if err != nil || offset < 0 {
		writeError(w, http.StatusBadRequest, "invalid_query", "offset deve ser >= 0")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), requestDBTimout)
	defer cancel()
	users, err := s.store.ListUsers(ctx, limit, offset)
	if err != nil {
		s.metrics.dbErrors.WithLabelValues("list_users").Inc()
		s.log.Error("falha ao listar usuários", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "erro interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"data": users, "limit": limit, "offset": offset})
}

// healthz: liveness. Não toca o banco de propósito (falha de DB não deve reiniciar o pod).
func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz: readiness. Depende do banco e fica 503 durante o shutdown para drenar o tráfego.
func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	if s.draining.Load() {
		writeError(w, http.StatusServiceUnavailable, "draining", "encerrando")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readyzTimeout)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		s.log.Warn("readyz: banco indisponível", "error", err)
		writeError(w, http.StatusServiceUnavailable, "db_unavailable", "banco indisponível")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func validate(name, email, password string) string {
	switch {
	case name == "" || utf8.RuneCountInString(name) > maxNameLen:
		return "name é obrigatório (até 100 caracteres)"
	case email == "" || len(email) > maxEmailLen:
		return "email é obrigatório (até 255 caracteres)"
	case !validEmail(email):
		return "email inválido"
	case len(password) < minPasswordLen || len(password) > maxPasswordLen:
		return "password deve ter entre 8 e 72 bytes"
	}
	return ""
}

func validEmail(s string) bool {
	a, err := mail.ParseAddress(s)
	return err == nil && a.Address == s
}

func intParam(r *http.Request, key string, def int) (int, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return def, nil
	}
	return strconv.Atoi(v)
}

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	var b errorBody
	b.Error.Code, b.Error.Message = code, msg
	writeJSON(w, status, b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
