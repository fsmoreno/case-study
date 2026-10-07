package config

import (
	"testing"
	"time"
)

// setRequired define as variáveis obrigatórias; t.Setenv restaura o ambiente ao fim de cada teste.
func setRequired(t *testing.T) {
	t.Helper()
	t.Setenv("DB_NAME", "estuda")
	t.Setenv("DB_USER", "estuda")
	t.Setenv("DB_PASSWORD", "segredo-de-teste")
}

func TestLoadDefaults(t *testing.T) {
	setRequired(t)

	c, err := Load()
	if err != nil {
		t.Fatalf("Load() erro inesperado: %v", err)
	}
	if c.HTTPAddr != ":8080" || c.DBHost != "localhost" || c.DBPort != "3306" {
		t.Errorf("padrões inesperados: %+v", c)
	}
	if c.DBMaxOpen != 10 || c.DBMaxIdle != 5 {
		t.Errorf("pool padrão inesperado: open=%d idle=%d", c.DBMaxOpen, c.DBMaxIdle)
	}
	if c.ShutdownDelay != 5*time.Second {
		t.Errorf("ShutdownDelay = %v, esperado 5s", c.ShutdownDelay)
	}
}

func TestLoadOverrides(t *testing.T) {
	setRequired(t)
	t.Setenv("HTTP_ADDR", ":9090")
	t.Setenv("DB_HOST", "floci")
	t.Setenv("DB_PORT", "7001")
	t.Setenv("DB_MAX_OPEN_CONNS", "20")
	t.Setenv("SHUTDOWN_DELAY_SECONDS", "0")

	c, err := Load()
	if err != nil {
		t.Fatalf("Load() erro inesperado: %v", err)
	}
	if c.HTTPAddr != ":9090" || c.DBHost != "floci" || c.DBPort != "7001" || c.DBMaxOpen != 20 {
		t.Errorf("valores não aplicados: %+v", c)
	}
	if c.ShutdownDelay != 0 {
		t.Errorf("ShutdownDelay = %v, esperado 0", c.ShutdownDelay)
	}
}

func TestLoadRequiredMissing(t *testing.T) {
	for _, missing := range []string{"DB_NAME", "DB_USER", "DB_PASSWORD"} {
		t.Run(missing, func(t *testing.T) {
			setRequired(t)
			t.Setenv(missing, "")
			if _, err := Load(); err == nil {
				t.Fatalf("esperava erro com %s ausente", missing)
			}
		})
	}
}

func TestLoadInvalidNumbers(t *testing.T) {
	for _, tc := range []struct{ key, value string }{
		{"DB_MAX_OPEN_CONNS", "abc"},
		{"DB_MAX_IDLE_CONNS", "-1"},
		{"SHUTDOWN_DELAY_SECONDS", "1.5"},
	} {
		t.Run(tc.key, func(t *testing.T) {
			setRequired(t)
			t.Setenv(tc.key, tc.value)
			if _, err := Load(); err == nil {
				t.Fatalf("esperava erro para %s=%q", tc.key, tc.value)
			}
		})
	}
}
