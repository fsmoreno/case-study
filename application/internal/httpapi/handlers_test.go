package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"

	"estuda-api/internal/store"
)

type fakeStore struct {
	users     []store.User
	hashes    []string
	createErr error
	listErr   error
	pingErr   error
}

func (f *fakeStore) CreateUser(_ context.Context, name, email, hash string) (store.User, error) {
	if f.createErr != nil {
		return store.User{}, f.createErr
	}
	u := store.User{ID: int64(len(f.users) + 1), Name: name, Email: email, CreatedAt: time.Now().UTC()}
	f.users = append(f.users, u)
	f.hashes = append(f.hashes, hash)
	return u, nil
}

func (f *fakeStore) ListUsers(_ context.Context, limit, offset int) ([]store.User, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	return f.users, nil
}

func (f *fakeStore) Ping(context.Context) error { return f.pingErr }

func newTestServer(fs *fakeStore) (*Server, http.Handler) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := NewServer(fs, NewMetrics(), log, bcrypt.MinCost)
	return s, s.Handler()
}

func do(h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var b errorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &b); err != nil {
		t.Fatalf("corpo de erro inválido: %v (%s)", err, rec.Body.String())
	}
	return b.Error.Code
}

func TestCreateUser(t *testing.T) {
	fs := &fakeStore{}
	_, h := newTestServer(fs)

	rec := do(h, "POST", "/users", `{"name":"João Silva","email":"Joao@Example.com","password":"senha-segura"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, esperado 201 (%s)", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "senha-segura") || strings.Contains(rec.Body.String(), "password") {
		t.Fatalf("a resposta não pode conter a senha: %s", rec.Body.String())
	}
	if got := fs.users[0].Email; got != "joao@example.com" {
		t.Errorf("email deveria ser normalizado para minúsculas, veio %q", got)
	}
	if fs.hashes[0] == "senha-segura" || bcrypt.CompareHashAndPassword([]byte(fs.hashes[0]), []byte("senha-segura")) != nil {
		t.Errorf("a senha deve ser armazenada como hash bcrypt válido")
	}
}

func TestCreateUserValidation(t *testing.T) {
	_, h := newTestServer(&fakeStore{})
	cases := map[string]string{
		"json inválido":      `{`,
		"campo desconhecido": `{"name":"A","email":"a@b.com","password":"12345678","admin":true}`,
		"sem nome":           `{"name":" ","email":"a@b.com","password":"12345678"}`,
		"email inválido":     `{"name":"A","email":"nao-e-email","password":"12345678"}`,
		"senha curta":        `{"name":"A","email":"a@b.com","password":"123"}`,
		"senha > 72 bytes":   `{"name":"A","email":"a@b.com","password":"` + strings.Repeat("x", 73) + `"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			rec := do(h, "POST", "/users", body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, esperado 400 (%s)", rec.Code, rec.Body.String())
			}
			if code := errorCode(t, rec); code != "invalid_payload" {
				t.Errorf("code = %q", code)
			}
		})
	}
}

func TestCreateUserBodyTooLarge(t *testing.T) {
	_, h := newTestServer(&fakeStore{})
	body := `{"name":"` + strings.Repeat("a", maxBodyBytes) + `"}`
	if rec := do(h, "POST", "/users", body); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, esperado 413", rec.Code)
	}
}

func TestCreateUserDuplicateEmail(t *testing.T) {
	_, h := newTestServer(&fakeStore{createErr: store.ErrEmailExists})
	rec := do(h, "POST", "/users", `{"name":"A","email":"a@b.com","password":"12345678"}`)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d, esperado 409", rec.Code)
	}
}

func TestCreateUserInternalErrorDoesNotLeakDetails(t *testing.T) {
	_, h := newTestServer(&fakeStore{createErr: errors.New("dial tcp 10.0.0.5:3306: connection refused")})
	rec := do(h, "POST", "/users", `{"name":"A","email":"a@b.com","password":"12345678"}`)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, esperado 500", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "10.0.0.5") {
		t.Fatalf("detalhe interno vazou na resposta: %s", rec.Body.String())
	}
}

func TestListUsers(t *testing.T) {
	fs := &fakeStore{users: []store.User{{ID: 1, Name: "A", Email: "a@b.com"}}}
	_, h := newTestServer(fs)

	rec := do(h, "GET", "/users?limit=10&offset=0", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "password") {
		t.Fatalf("a listagem não pode expor senha: %s", rec.Body.String())
	}
	for _, q := range []string{"?limit=0", "?limit=101", "?limit=abc", "?offset=-1"} {
		if rec := do(h, "GET", "/users"+q, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, esperado 400", q, rec.Code)
		}
	}
}

func TestHealthAndReadiness(t *testing.T) {
	fs := &fakeStore{}
	s, h := newTestServer(fs)

	if rec := do(h, "GET", "/healthz", ""); rec.Code != http.StatusOK {
		t.Errorf("healthz = %d", rec.Code)
	}
	if rec := do(h, "GET", "/readyz", ""); rec.Code != http.StatusOK {
		t.Errorf("readyz = %d", rec.Code)
	}

	fs.pingErr = errors.New("db down")
	if rec := do(h, "GET", "/healthz", ""); rec.Code != http.StatusOK {
		t.Errorf("healthz não deve depender do banco, veio %d", rec.Code)
	}
	if rec := do(h, "GET", "/readyz", ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz com banco fora = %d, esperado 503", rec.Code)
	}

	fs.pingErr = nil
	s.SetDraining()
	if rec := do(h, "GET", "/readyz", ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("readyz em shutdown = %d, esperado 503", rec.Code)
	}
}

func TestMetricsUseRoutePatternNotRawPath(t *testing.T) {
	_, h := newTestServer(&fakeStore{})
	do(h, "GET", "/users", "")
	do(h, "GET", "/rota-que-nao-existe-123", "")

	body := do(h, "GET", "/metrics", "").Body.String()
	for _, want := range []string{
		`http_requests_total{method="GET",route="/users",status="200"} 1`,
		`route="unmatched"`,
		`http_request_duration_seconds_bucket`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("métricas não contêm %q", want)
		}
	}
	if strings.Contains(body, "rota-que-nao-existe-123") {
		t.Errorf("path bruto não pode virar label (cardinalidade)")
	}
}
