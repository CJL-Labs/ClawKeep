package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"claw-keep/keepd/internal/agent"
	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/crash"
	"claw-keep/keepd/internal/grpcserver"
	"claw-keep/keepd/internal/logcollector"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/monitor"
	"claw-keep/keepd/internal/notifier"
	"claw-keep/keepd/internal/orchestrator"
)

func main() {
	configPath := flag.String("config", config.DefaultConfigPath(), "path to config.toml")
	socketPath := flag.String("socket", defaultSocketPath(), "path to unix domain socket")
	simulateCrash := flag.Bool("simulate-crash", false, "run a synthetic crash workflow")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load config: %v\n", err)
		os.Exit(1)
	}

	logger, err := logging.New(cfg.Daemon.LogDir, cfg.Daemon.LogLevel)
	if err != nil {
		fmt.Fprintf(os.Stderr, "init logger: %v\n", err)
		os.Exit(1)
	}

	agents, err := agent.NewRegistry(cfg.Agent.Agents)
	if err != nil {
		logger.Error("agent registry init failed", "error", err.Error())
		os.Exit(1)
	}

	dispatcher, err := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, agents)
	if err != nil {
		logger.Error("agent dispatcher init failed", "error", err.Error())
		os.Exit(1)
	}

	notifyManager := notifier.NewManager(cfg.Notify, logger)
	store := crash.NewStore(cfg.Log.CrashArchiveDir, cfg.Log.MaxArchiveDays)
	configStore := config.NewStore(*configPath, cfg)

	orc := orchestrator.New(cfg, logger, store, dispatcher, notifyManager)
	collector, err := logcollector.New(cfg.Log, logger)
	if err != nil {
		logger.Error("log collector init failed", "error", err.Error())
		os.Exit(1)
	}
	mon := monitor.New(cfg.Monitor, logger)
	grpcServer := grpcserver.New(*socketPath, configStore, logger, orc, collector, notifyManager)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	logger.Info("keepd started", "config", *configPath, "default_agent", cfg.Agent.DefaultAgent)

	if *simulateCrash {
		report := crash.Report{
			ProcessName:    cfg.Monitor.ProcessName,
			PID:            4242,
			ExitCode:       1,
			CrashTime:      time.Now(),
			TailLogs:       []string{"panic: example failure", "service stopped unexpectedly"},
			ErrLogTail:     "panic: example failure",
			StderrSnapshot: "stacktrace omitted",
		}

		if err := orc.HandleCrash(ctx, report); err != nil {
			logger.Error("simulate crash failed", "error", err.Error())
			os.Exit(1)
		}
		logger.Info("simulate crash completed")
		return
	}

	go func() {
		if err := collector.Run(ctx); err != nil {
			logger.Warn("log collector stopped", "error", err.Error())
		}
	}()
	go mon.Run(ctx)
	go func() {
		if err := grpcServer.Run(ctx); err != nil {
			logger.Error("grpc server stopped", "error", err.Error())
			stop()
		}
	}()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case event := <-mon.Events():
				switch event.Type {
				case monitor.EventProcessUp:
					orc.UpdatePID(event.PID)
				case monitor.EventProcessExit:
					report := crash.Report{
						ProcessName:    cfg.Monitor.ProcessName,
						PID:            event.PID,
						ExitCode:       event.ExitCode,
						CrashTime:      event.Time,
						TailLogs:       collector.SnapshotLines(cfg.Log.TailLinesOnCrash),
						ErrLogTail:     collector.TailBySuffix("gateway.err.log", 50),
						StderrSnapshot: collector.TailBySuffix("gateway.err.log", 20),
					}
					if err := orc.HandleCrash(ctx, report); err != nil {
						logger.Warn("handle crash failed", "error", err.Error())
					}
				case monitor.EventPortDown:
					orc.PortDown(event.Detail)
				}
			}
		}
	}()

	<-ctx.Done()
	logger.Info("keepd stopped")
}

func defaultSocketPath() string {
	tmpDir := os.TempDir()
	return filepath.Join(tmpDir, "claw-keep.sock")
}
