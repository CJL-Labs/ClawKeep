package orchestrator

import (
	"context"
	"testing"
	"time"

	"claw-keep/keepd/internal/agent"
	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/crash"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/notifier"
)

func TestHandleCrashReturnsToWatchingAfterSuccessfulRepair(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName:   "openclaw-gateway",
			Port:          18789,
			HealthCommand: "true",
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{
				{
					Name:       "codex",
					CLIPath:    "/usr/bin/true",
					WorkingDir: t.TempDir(),
					TimeoutSec: 5,
				},
			},
		},
		Repair: config.RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair {{.ExitCode}} {{.WatchPaths}}",
		},
	}

	logger, err := logging.NewWithRetention(t.TempDir(), "debug", 1)
	if err != nil {
		t.Fatalf("new logger: %v", err)
	}
	registry, err := agent.NewRegistry(cfg.Agent.Agents)
	if err != nil {
		t.Fatalf("new registry: %v", err)
	}
	dispatcher, err := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, registry)
	if err != nil {
		t.Fatalf("new dispatcher: %v", err)
	}

	orc := New(cfg, logger, dispatcher, notifier.NewManager(config.NotifyConfig{}, logger))
	report := crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         12345,
		ExitCode:    1,
		CrashTime:   time.Now(),
		WatchPaths:  []string{"/Users/test/.openclaw/logs/gateway.err.log"},
	}

	if err := orc.HandleCrash(context.Background(), report); err != nil {
		t.Fatalf("handle crash: %v", err)
	}

	status := orc.Status()
	if status.State != StateWatching {
		t.Fatalf("unexpected state: %s", status.State)
	}
	if status.RepairAttempts != 1 {
		t.Fatalf("unexpected repair attempts: %d", status.RepairAttempts)
	}
	if status.CrashCount != 1 {
		t.Fatalf("unexpected crash count: %d", status.CrashCount)
	}
}

func TestHandleCrashFailsWhenPostRepairHealthCheckFails(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName:   "openclaw-gateway",
			Port:          18789,
			HealthCommand: "false",
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{
				{
					Name:       "codex",
					CLIPath:    "/usr/bin/true",
					WorkingDir: t.TempDir(),
					TimeoutSec: 5,
				},
			},
		},
		Repair: config.RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair",
		},
	}

	logger, err := logging.NewWithRetention(t.TempDir(), "debug", 1)
	if err != nil {
		t.Fatalf("new logger: %v", err)
	}
	registry, err := agent.NewRegistry(cfg.Agent.Agents)
	if err != nil {
		t.Fatalf("new registry: %v", err)
	}
	dispatcher, err := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, registry)
	if err != nil {
		t.Fatalf("new dispatcher: %v", err)
	}

	orc := New(cfg, logger, dispatcher, notifier.NewManager(config.NotifyConfig{}, logger))
	report := crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         12345,
		ExitCode:    1,
		CrashTime:   time.Now(),
	}

	if err := orc.HandleCrash(context.Background(), report); err != nil {
		t.Fatalf("handle crash: %v", err)
	}

	status := orc.Status()
	if status.State != StateExhausted {
		t.Fatalf("unexpected state: %s", status.State)
	}
}

func TestHandleProcessExitStartsMaintenanceWindowBeforeCrash(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName:        "openclaw-gateway",
			Port:               18789,
			ExitGracePeriodSec: 20,
			HealthCommand:      "true",
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{{
				Name:       "codex",
				CLIPath:    "/usr/bin/true",
				WorkingDir: t.TempDir(),
				TimeoutSec: 5,
			}},
		},
		Repair: config.RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair",
		},
	}

	logger, _ := logging.NewWithRetention(t.TempDir(), "debug", 1)
	registry, _ := agent.NewRegistry(cfg.Agent.Agents)
	dispatcher, _ := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, registry)
	orc := New(cfg, logger, dispatcher, notifier.NewManager(config.NotifyConfig{}, logger))

	err := orc.HandleProcessExit(context.Background(), crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         123,
		ExitCode:    0,
		CrashTime:   time.Now(),
	})
	if err != nil {
		t.Fatalf("handle process exit: %v", err)
	}

	status := orc.Status()
	if status.State != StateMaintenance {
		t.Fatalf("unexpected state: %s", status.State)
	}
	if status.CrashCount != 0 {
		t.Fatalf("unexpected crash count: %d", status.CrashCount)
	}
}

func TestConfirmHealthyWithinGraceReturnsToWatching(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName:        "openclaw-gateway",
			Port:               18789,
			ExitGracePeriodSec: 20,
			HealthCommand:      "true",
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{{
				Name:       "codex",
				CLIPath:    "/usr/bin/true",
				WorkingDir: t.TempDir(),
				TimeoutSec: 5,
			}},
		},
		Repair: config.RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair",
		},
	}

	logger, _ := logging.NewWithRetention(t.TempDir(), "debug", 1)
	registry, _ := agent.NewRegistry(cfg.Agent.Agents)
	dispatcher, _ := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, registry)
	orc := New(cfg, logger, dispatcher, notifier.NewManager(config.NotifyConfig{}, logger))

	_ = orc.HandleProcessExit(context.Background(), crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         123,
		ExitCode:    0,
		CrashTime:   time.Now(),
	})
	orc.ConfirmHealthy(456)

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		status := orc.Status()
		if status.State == StateWatching {
			if status.PID <= 0 {
				t.Fatalf("unexpected pid: %d", status.PID)
			}
			if status.CrashCount != 0 {
				t.Fatalf("unexpected crash count: %d", status.CrashCount)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}

	t.Fatalf("status did not return to watching in time: %s", orc.Status().State)
}

func TestPortDownDuringMaintenanceStaysInMaintenance(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName:        "openclaw-gateway",
			Port:               18789,
			ExitGracePeriodSec: 20,
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{{
				Name:       "codex",
				CLIPath:    "/usr/bin/true",
				WorkingDir: t.TempDir(),
				TimeoutSec: 5,
			}},
		},
		Repair: config.RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair",
		},
	}

	logger, _ := logging.NewWithRetention(t.TempDir(), "debug", 1)
	registry, _ := agent.NewRegistry(cfg.Agent.Agents)
	dispatcher, _ := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, registry)
	orc := New(cfg, logger, dispatcher, notifier.NewManager(config.NotifyConfig{}, logger))

	_ = orc.HandleProcessExit(context.Background(), crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         123,
		ExitCode:    0,
		CrashTime:   time.Now(),
	})
	orc.PortDown("connection refused")

	status := orc.Status()
	if status.State != StateMaintenance {
		t.Fatalf("unexpected state: %s", status.State)
	}
}

func TestSecondProcessExitWithinGraceDoesNotTriggerRepair(t *testing.T) {
	t.Parallel()

	cfg := &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName:        "openclaw-gateway",
			Port:               18789,
			ExitGracePeriodSec: 20,
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{{
				Name:       "codex",
				CLIPath:    "/usr/bin/true",
				WorkingDir: t.TempDir(),
				TimeoutSec: 5,
			}},
		},
		Repair: config.RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair",
		},
	}

	logger, _ := logging.NewWithRetention(t.TempDir(), "debug", 1)
	registry, _ := agent.NewRegistry(cfg.Agent.Agents)
	dispatcher, _ := agent.NewDispatcher(cfg.Agent.DefaultAgent, cfg.Repair.PromptTemplate, registry)
	orc := New(cfg, logger, dispatcher, notifier.NewManager(config.NotifyConfig{}, logger))

	_ = orc.HandleProcessExit(context.Background(), crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         123,
		ExitCode:    0,
		CrashTime:   time.Now(),
	})
	_ = orc.HandleProcessExit(context.Background(), crash.Report{
		ProcessName: cfg.Monitor.ProcessName,
		PID:         456,
		ExitCode:    0,
		CrashTime:   time.Now(),
	})

	status := orc.Status()
	if status.State != StateMaintenance {
		t.Fatalf("unexpected state: %s", status.State)
	}
	if status.CrashCount != 0 {
		t.Fatalf("unexpected crash count: %d", status.CrashCount)
	}
}

func TestVerifyDefaultHealthOutputRejectsInvalidConfig(t *testing.T) {
	t.Parallel()

	err := verifyDefaultHealthOutput(`Config invalid
File: ~/.openclaw/openclaw.json
Problem:
  - <root>: JSON5 parse failed
{
  "ok": true
}`)
	if err == nil {
		t.Fatal("expected invalid config output to fail verification")
	}
}

func TestVerifyDefaultHealthOutputAcceptsHealthyJSON(t *testing.T) {
	t.Parallel()

	err := verifyDefaultHealthOutput(`{
  "ok": true
}`)
	if err != nil {
		t.Fatalf("expected healthy output to pass verification, got: %v", err)
	}
}

func TestExtractJSONPayloadSkipsLeadingDiagnostics(t *testing.T) {
	t.Parallel()

	payload := extractJSONPayload("Config invalid\nProblem:\n{\n  \"ok\": true\n}")
	if payload != "{\n  \"ok\": true\n}" {
		t.Fatalf("unexpected payload: %q", payload)
	}
}

func TestDiscoverPIDReturnsErrorForMissingProcess(t *testing.T) {
	t.Parallel()

	_, err := discoverPID("definitely-not-a-real-process-name")
	if err == nil {
		t.Fatal("expected missing process to return error")
	}
	if err.Error() == "" {
		t.Fatalf("unexpected empty error")
	}
}
