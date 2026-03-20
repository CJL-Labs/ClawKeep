package orchestrator

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"

	"claw-keep/keepd/internal/agent"
	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/crash"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/notifier"
)

type State string

const (
	StateWatching      State = "watching"
	StateCrashDetected State = "crash_detected"
	StateCollecting    State = "collecting"
	StateRepairing     State = "repairing"
	StateRestarting    State = "restarting"
	StateExhausted     State = "exhausted"
)

type Status struct {
	ProcessName    string    `json:"process_name"`
	PID            int       `json:"pid"`
	ExitCode       int       `json:"exit_code"`
	State          State     `json:"state"`
	LastCrashTime  time.Time `json:"last_crash_time"`
	CrashCount     int       `json:"crash_count"`
	RepairAttempts int       `json:"repair_attempts"`
	LastArchive    string    `json:"last_archive"`
	Detail         string    `json:"detail"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type StatusEvent struct {
	Status Status
	Reason string
}

type Orchestrator struct {
	cfg        *config.Config
	logger     *logging.Logger
	store      *crash.Store
	dispatcher *agent.Dispatcher
	notifier   *notifier.Manager

	mu     sync.Mutex
	status Status

	subscribers map[int]chan StatusEvent
	nextSubID   int
	restarts    int
	lastRestart time.Time
}

func New(cfg *config.Config, logger *logging.Logger, store *crash.Store, dispatcher *agent.Dispatcher, notifier *notifier.Manager) *Orchestrator {
	return &Orchestrator{
		cfg:        cfg,
		logger:     logger,
		store:      store,
		dispatcher: dispatcher,
		notifier:   notifier,
		status: Status{
			ProcessName: cfg.Monitor.ProcessName,
			State:       StateWatching,
			UpdatedAt:   time.Now(),
		},
		subscribers: make(map[int]chan StatusEvent),
	}
}

func (o *Orchestrator) HandleCrash(ctx context.Context, report crash.Report) error {
	o.transition(StateCrashDetected, fmt.Sprintf("process exited with code %d", report.ExitCode))
	o.setCrash(report.CrashTime)
	o.setPID(report.PID)
	o.setExitCode(report.ExitCode)

	if err := o.notifier.Notify(ctx, notifier.EventCrash, notifier.Message{
		Title: "ClawKeep: crash detected",
		Body:  fmt.Sprintf("%s exited with code %d", report.ProcessName, report.ExitCode),
	}); err != nil {
		return err
	}

	o.transition(StateCollecting, "collecting crash artifacts")
	archivePath, err := o.store.Save(report)
	if err != nil {
		return err
	}
	o.setArchive(archivePath)

	if !o.cfg.Repair.AutoRepair {
		o.transition(StateCrashDetected, "auto repair disabled; awaiting manual action")
		return nil
	}

	for attempt := 1; attempt <= o.cfg.Repair.MaxRepairAttempts; attempt++ {
		o.setRepairAttempts(attempt)
		o.transition(StateRepairing, fmt.Sprintf("repair attempt %d", attempt))

		_ = o.notifier.Notify(ctx, notifier.EventRepairStart, notifier.Message{
			Title: "ClawKeep: repair started",
			Body:  fmt.Sprintf("attempt %d for %s", attempt, report.ProcessName),
		})

		result, timeoutWarnings, repairErr := o.dispatcher.Dispatch(ctx, report)
		for _, warning := range timeoutWarnings {
			_ = o.notifier.Notify(ctx, notifier.EventAgentTimeout, notifier.Message{
				Title: "ClawKeep: agent timeout",
				Body:  warning,
			})
		}
		if repairErr == nil {
			o.logger.Info("repair succeeded", "agent", result.AgentName, "duration", result.Duration.String())
			_ = o.notifier.Notify(ctx, notifier.EventRepairSuccess, notifier.Message{
				Title: "ClawKeep: repair succeeded",
				Body:  fmt.Sprintf("agent=%s output=%s", result.AgentName, truncate(result.Output)),
			})
			if o.cfg.Repair.AutoRestart {
				if err := o.restart(ctx); err != nil {
					o.logger.Warn("restart failed", "error", err.Error())
				}
			}
			o.transition(StateWatching, "repair succeeded")
			return nil
		}

		o.logger.Warn("repair failed", "attempt", attempt, "error", repairErr.Error())
		_ = o.notifier.Notify(ctx, notifier.EventRepairFail, notifier.Message{
			Title: "ClawKeep: repair failed",
			Body:  fmt.Sprintf("attempt=%d error=%s", attempt, repairErr.Error()),
		})
	}

	o.transition(StateExhausted, "repair attempts exhausted")
	_ = o.notifier.Notify(ctx, notifier.EventRepairFail, notifier.Message{
		Title: "ClawKeep: repair exhausted",
		Body:  fmt.Sprintf("%s requires manual intervention", report.ProcessName),
	})
	return nil
}

func (o *Orchestrator) Status() Status {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.status
}

func (o *Orchestrator) SubscribeStatus() (<-chan StatusEvent, func()) {
	o.mu.Lock()
	defer o.mu.Unlock()

	channel := make(chan StatusEvent, 16)
	id := o.nextSubID
	o.nextSubID++
	o.subscribers[id] = channel
	channel <- StatusEvent{Status: o.status, Reason: "initial"}

	cancel := func() {
		o.mu.Lock()
		defer o.mu.Unlock()
		if subscriber, ok := o.subscribers[id]; ok {
			delete(o.subscribers, id)
			close(subscriber)
		}
	}
	return channel, cancel
}

func (o *Orchestrator) TriggerRepair(ctx context.Context) error {
	report := crash.Report{
		ProcessName:    o.cfg.Monitor.ProcessName,
		PID:            o.status.PID,
		ExitCode:       o.status.ExitCode,
		CrashTime:      time.Now(),
		TailLogs:       []string{"manual repair requested"},
		ErrLogTail:     o.status.Detail,
		StderrSnapshot: o.status.Detail,
	}
	return o.HandleCrash(ctx, report)
}

func (o *Orchestrator) Restart(ctx context.Context) error {
	return o.restart(ctx)
}

func (o *Orchestrator) Reset() {
	o.mu.Lock()
	o.status.RepairAttempts = 0
	o.status.ExitCode = 0
	o.status.Detail = "monitor reset"
	o.restarts = 0
	o.lastRestart = time.Time{}
	o.mu.Unlock()
	o.transition(StateWatching, "manual reset")
}

func (o *Orchestrator) UpdatePID(pid int) {
	o.setPID(pid)
	o.transition(StateWatching, "process running")
}

func (o *Orchestrator) PortDown(detail string) {
	o.transition(StateCrashDetected, detail)
}

func (o *Orchestrator) ApplyConfig(cfg *config.Config) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.cfg = config.Clone(cfg)
	o.status.ProcessName = cfg.Monitor.ProcessName
	o.status.UpdatedAt = time.Now()
}

func (o *Orchestrator) transition(state State, reason string) {
	o.mu.Lock()
	o.status.State = state
	o.status.Detail = reason
	o.status.UpdatedAt = time.Now()
	status := o.status
	subs := make([]chan StatusEvent, 0, len(o.subscribers))
	for _, subscriber := range o.subscribers {
		subs = append(subs, subscriber)
	}
	o.mu.Unlock()

	o.logger.Info("state changed", "state", string(state))
	event := StatusEvent{Status: status, Reason: reason}
	for _, subscriber := range subs {
		select {
		case subscriber <- event:
		default:
		}
	}
}

func (o *Orchestrator) setCrash(at time.Time) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.status.LastCrashTime = at
	o.status.CrashCount++
	o.status.UpdatedAt = time.Now()
}

func (o *Orchestrator) setRepairAttempts(attempt int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.status.RepairAttempts = attempt
	o.status.UpdatedAt = time.Now()
}

func (o *Orchestrator) setArchive(path string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.status.LastArchive = path
	o.status.UpdatedAt = time.Now()
}

func (o *Orchestrator) setPID(pid int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.status.PID = pid
	o.status.UpdatedAt = time.Now()
}

func (o *Orchestrator) setExitCode(code int) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.status.ExitCode = code
	o.status.UpdatedAt = time.Now()
}

func (o *Orchestrator) restart(ctx context.Context) error {
	o.mu.Lock()
	if cooldown := time.Duration(o.cfg.Monitor.RestartCooldownSec) * time.Second; cooldown > 0 && !o.lastRestart.IsZero() && time.Since(o.lastRestart) < cooldown {
		o.mu.Unlock()
		return fmt.Errorf("restart cooldown active")
	}
	if o.cfg.Monitor.MaxRestartAttempts > 0 && o.restarts >= o.cfg.Monitor.MaxRestartAttempts {
		o.mu.Unlock()
		o.transition(StateExhausted, "restart attempts exhausted")
		return fmt.Errorf("restart attempts exhausted")
	}
	o.mu.Unlock()

	o.transition(StateRestarting, "running restart command")
	command := exec.CommandContext(ctx, o.cfg.Repair.RestartCommand, o.cfg.Repair.RestartArgs...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("restart command failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	o.mu.Lock()
	o.restarts++
	o.lastRestart = time.Now()
	o.mu.Unlock()
	_ = o.notifier.Notify(ctx, notifier.EventRestart, notifier.Message{
		Title: "ClawKeep: restart completed",
		Body:  fmt.Sprintf("command=%s", o.cfg.Repair.RestartCommand),
	})
	o.transition(StateWatching, "restart completed")
	return nil
}

func truncate(value string) string {
	if len(value) <= 160 {
		return value
	}
	return value[:160] + "..."
}
