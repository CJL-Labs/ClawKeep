package runtime

import (
	"claw-keep/keepd/internal/agent"
	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/monitor"
	"claw-keep/keepd/internal/notifier"
	"claw-keep/keepd/internal/orchestrator"
)

type Applier struct {
	dispatcher   *agent.Dispatcher
	monitor      *monitor.Monitor
	notifier     *notifier.Manager
	orchestrator *orchestrator.Orchestrator
	logger       *logging.Logger
}

func NewApplier(dispatcher *agent.Dispatcher, monitor *monitor.Monitor, notifier *notifier.Manager, orchestrator *orchestrator.Orchestrator, logger *logging.Logger) *Applier {
	return &Applier{
		dispatcher:   dispatcher,
		monitor:      monitor,
		notifier:     notifier,
		orchestrator: orchestrator,
		logger:       logger,
	}
}

func (a *Applier) Apply(cfg *config.Config) error {
	if err := a.dispatcher.ApplyConfig(cfg.Agent, cfg.Repair); err != nil {
		return err
	}
	a.monitor.ApplyConfig(cfg.Monitor)
	a.notifier.ApplyConfig(cfg.Notify)
	a.orchestrator.ApplyConfig(cfg)
	return a.logger.ApplyConfig(cfg.Daemon.LogDir, cfg.Daemon.LogLevel, cfg.Daemon.LogRetainDays)
}
