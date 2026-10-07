// Package config carrega a configuração exclusivamente de variáveis de ambiente.
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	HTTPAddr      string
	DBHost        string
	DBPort        string
	DBName        string
	DBUser        string
	DBPassword    string
	DBMaxOpen     int
	DBMaxIdle     int
	ShutdownDelay time.Duration // tempo com /readyz=503 antes de encerrar, para o LB/Service tirar o pod da rotação
}

func Load() (Config, error) {
	c := Config{
		HTTPAddr:   env("HTTP_ADDR", ":8080"),
		DBHost:     env("DB_HOST", "localhost"),
		DBPort:     env("DB_PORT", "3306"),
		DBName:     os.Getenv("DB_NAME"),
		DBUser:     os.Getenv("DB_USER"),
		DBPassword: os.Getenv("DB_PASSWORD"),
	}
	var err error
	if c.DBMaxOpen, err = envInt("DB_MAX_OPEN_CONNS", 10); err != nil {
		return c, err
	}
	if c.DBMaxIdle, err = envInt("DB_MAX_IDLE_CONNS", 5); err != nil {
		return c, err
	}
	delay, err := envInt("SHUTDOWN_DELAY_SECONDS", 5)
	if err != nil {
		return c, err
	}
	c.ShutdownDelay = time.Duration(delay) * time.Second

	for name, v := range map[string]string{"DB_NAME": c.DBName, "DB_USER": c.DBUser, "DB_PASSWORD": c.DBPassword} {
		if v == "" {
			return c, fmt.Errorf("variável obrigatória ausente: %s", name)
		}
	}
	return c, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) (int, error) {
	v := os.Getenv(key)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("%s inválida: %q", key, v)
	}
	return n, nil
}
