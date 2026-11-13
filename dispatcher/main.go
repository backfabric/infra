// The dispatcher: the A2A front door for agent tasks (ADR 0028).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	configPath := flag.String("config", "/etc/dispatcher/config.json", "configuration file (README.md)")
	flag.Parse()
	if err := run(*configPath); err != nil {
		slog.Error("dispatcher failed", "error", err)
		os.Exit(1)
	}
}

func run(configPath string) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg, err := LoadConfig(configPath)
	if err != nil {
		return err
	}
	audit, err := NewAuditor(ctx, cfg.Audit)
	if err != nil {
		return fmt.Errorf("audit: %w", err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := audit.Shutdown(ctx); err != nil {
			slog.Error("audit: flushing events failed", "error", err)
		}
	}()
	auth, err := NewAuthenticator(ctx, cfg.Issuers)
	if err != nil {
		return err
	}
	store, err := OpenStore(ctx)
	if err != nil {
		return fmt.Errorf("database: %w", err)
	}
	defer store.Close()
	handler, err := NewServer(cfg, auth, store, audit)
	if err != nil {
		return err
	}

	server := &http.Server{
		Addr:    cfg.Listen,
		Handler: handler,
		// A request (at most maxRequestBytes) is read within these, so a
		// slow or idle peer cannot hold connections.
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       2 * time.Minute,
		// Every call answers from the record within this. A call that
		// waits longer (blocking SendMessage, later) extends its own
		// deadline with http.ResponseController.SetWriteDeadline.
		WriteTimeout: time.Minute,
	}
	served := make(chan error, 1)
	go func() { served <- server.ListenAndServe() }()
	slog.Info("serving", "listen", cfg.Listen, "agents", len(cfg.Agents))
	select {
	case err := <-served:
		return err
	case <-ctx.Done():
	}
	slog.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
