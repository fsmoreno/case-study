package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/collectors"
	"golang.org/x/crypto/bcrypt"

	"estuda-api/internal/config"
	"estuda-api/internal/httpapi"
	"estuda-api/internal/store"
)

func main() {
	// Subcomando usado pelo HEALTHCHECK do Dockerfile (imagem distroless não tem shell nem curl).
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	os.Exit(run())
}

func run() int {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	cfg, err := config.Load()
	if err != nil {
		log.Error("configuração inválida", "error", err)
		return 1
	}

	db, err := store.Open(cfg.DBHost, cfg.DBPort, cfg.DBName, cfg.DBUser, cfg.DBPassword, cfg.DBMaxOpen, cfg.DBMaxIdle)
	if err != nil {
		log.Error("falha ao configurar o banco", "error", err)
		return 1
	}
	defer func() {
		if err := db.Close(); err != nil {
			log.Warn("falha ao fechar o pool do banco", "error", err)
		}
	}()

	metrics := httpapi.NewMetrics()
	metrics.Registry.MustRegister(collectors.NewDBStatsCollector(db, cfg.DBName))

	api := httpapi.NewServer(store.NewMySQL(db), metrics, log, bcrypt.DefaultCost)
	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 14,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("servidor iniciado", "addr", cfg.HTTPAddr)
		errCh <- srv.ListenAndServe()
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Error("servidor falhou", "error", err)
			return 1
		}
	case <-ctx.Done():
		// 1) readiness passa a 503 para o Service/LB parar de enviar tráfego;
		// 2) aguarda a propagação; 3) encerra aguardando requisições em andamento.
		log.Info("sinal recebido, iniciando shutdown", "delay", cfg.ShutdownDelay)
		api.SetDraining()
		time.Sleep(cfg.ShutdownDelay)

		shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Error("shutdown incompleto", "error", err)
			return 1
		}
	}
	log.Info("encerrado")
	return 0
}

func healthcheck() int {
	addr := os.Getenv("HTTP_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return 1
	}
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return 1
	}
	defer func() { _ = resp.Body.Close() }() // o healthcheck só usa o status; o erro de Close não muda o resultado
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
