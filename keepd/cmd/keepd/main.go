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
	"claw-keep/keepd/internal/ipcserver"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/monitor"
	"claw-keep/keepd/internal/notifier"
	"claw-keep/keepd/internal/orchestrator"
	"claw-keep/keepd/internal/runtime"
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

	logger, err := logging.NewWithRetention(cfg.Daemon.LogDir, cfg.Daemon.LogLevel, cfg.Daemon.LogRetainDays)
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
	configStore := config.NewStore(*configPath, cfg)
	orc := orchestrator.New(cfg, logger, dispatcher, notifyManager)
	mon := monitor.New(cfg.Monitor, logger)
	configApplier := runtime.NewApplier(dispatcher, mon, notifyManager, orc, logger)
	ipcServer := ipcserver.New(*socketPath, configStore, logger, orc, notifyManager, configApplier)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	logger.Info("keepd started", "config", *configPath, "default_agent", cfg.Agent.DefaultAgent)

	go func() {
		if err := configStore.Run(ctx); err != nil {
			logger.Warn("config watcher stopped", "error", err.Error())
		}
	}()
	go func() {
		updates, cancel := configStore.Subscribe()
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case updated, ok := <-updates:
				if !ok {
					return
				}
				if err := dispatcher.ApplyConfig(updated.Agent, updated.Repair); err != nil {
					logger.Warn("apply agent config failed", "error", err.Error())
					continue
				}
				mon.ApplyConfig(updated.Monitor)
				notifyManager.ApplyConfig(updated.Notify)
				orc.ApplyConfig(updated)
				if err := logger.ApplyConfig(updated.Daemon.LogDir, updated.Daemon.LogLevel, updated.Daemon.LogRetainDays); err != nil {
					fmt.Fprintf(os.Stderr, "apply logger config: %v\n", err)
				}
			}
		}
	}()

	if *simulateCrash {
		report := crash.Report{
			ProcessName: cfg.Monitor.ProcessName,
			PID:         4242,
			ExitCode:    1,
			CrashTime:   time.Now(),
			WatchPaths:  append([]string(nil), cfg.Log.WatchPaths...),
		}

		if err := orc.HandleCrash(ctx, report); err != nil {
			logger.Error("simulate crash failed", "error", err.Error())
			os.Exit(1)
		}
		logger.Info("simulate crash completed")
		return
	}

	go mon.Run(ctx)
	go func() {
		if err := ipcServer.Run(ctx); err != nil {
			logger.Error("ipc server stopped", "error", err.Error())
			stop()
		}
	}()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case event := <-mon.Events():
				logger.Debug("monitor event", "type", string(event.Type), "pid", event.PID, "exit_code", event.ExitCode, "detail", event.Detail)
				if orc.ShouldIgnoreEvent(event.Time) {
					continue
				}
				switch event.Type {
				case monitor.EventProcessUp:
					orc.UpdatePID(event.PID)
					if !cfg.Monitor.EnableTCPProbe {
						orc.ConfirmHealthy(event.PID)
					}
				case monitor.EventProcessExit:
					report := crash.Report{
						ProcessName: cfg.Monitor.ProcessName,
						PID:         event.PID,
						ExitCode:    event.ExitCode,
						CrashTime:   event.Time,
						WatchPaths:  append([]string(nil), cfg.Log.WatchPaths...),
					}
					if err := orc.HandleProcessExit(ctx, report); err != nil {
						logger.Warn("handle crash failed", "error", err.Error())
					}
				case monitor.EventPortUp:
					orc.ConfirmHealthy(event.PID)
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
