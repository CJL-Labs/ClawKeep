package pbconv

import (
	"time"

	sentinelv1 "claw-keep/sentineld/gen/proto/sentinel/v1"
	"claw-keep/sentineld/internal/config"
	"claw-keep/sentineld/internal/logcollector"
	"claw-keep/sentineld/internal/orchestrator"

	"google.golang.org/protobuf/types/known/timestamppb"
)

func ConfigToProto(cfg *config.Config) *sentinelv1.AppConfig {
	agents := make([]*sentinelv1.AgentEntry, 0, len(cfg.Agent.Agents))
	for _, agent := range cfg.Agent.Agents {
		agents = append(agents, &sentinelv1.AgentEntry{
			Name:       agent.Name,
			CliPath:    agent.CLIPath,
			CliArgs:    append([]string{}, agent.CLIArgs...),
			WorkingDir: agent.WorkingDir,
			TimeoutSec: int32(agent.TimeoutSec),
			Env:        agent.Env,
		})
	}
	return &sentinelv1.AppConfig{
		Monitor: &sentinelv1.MonitorConfig{
			ProcessName:        cfg.Monitor.ProcessName,
			PidFile:            cfg.Monitor.PIDFile,
			Host:               cfg.Monitor.Host,
			Port:               int32(cfg.Monitor.Port),
			EnableKqueue:       cfg.Monitor.EnableKqueue,
			EnableTcpProbe:     cfg.Monitor.EnableTCPProbe,
			TcpProbeTimeoutMs:  int32(cfg.Monitor.TCPProbeTimeoutMS),
			HealthCommand:      cfg.Monitor.HealthCommand,
			RestartCooldownSec: int32(cfg.Monitor.RestartCooldownSec),
			MaxRestartAttempts: int32(cfg.Monitor.MaxRestartAttempts),
		},
		Log: &sentinelv1.LogConfig{
			WatchPaths:       append([]string{}, cfg.Log.WatchPaths...),
			CrashArchiveDir:  cfg.Log.CrashArchiveDir,
			TailLinesOnCrash: int32(cfg.Log.TailLinesOnCrash),
			MaxArchiveDays:   int32(cfg.Log.MaxArchiveDays),
		},
		Agent: &sentinelv1.AgentConfig{
			DefaultAgent: cfg.Agent.DefaultAgent,
			Agents:       agents,
		},
		Repair: &sentinelv1.RepairConfig{
			AutoRepair:        cfg.Repair.AutoRepair,
			AutoRestart:       cfg.Repair.AutoRestart,
			RestartCommand:    cfg.Repair.RestartCommand,
			RestartArgs:       append([]string{}, cfg.Repair.RestartArgs...),
			MaxRepairAttempts: int32(cfg.Repair.MaxRepairAttempts),
			PromptTemplate:    cfg.Repair.PromptTemplate,
		},
		Notify: &sentinelv1.NotifyConfig{
			NotifyOn: append([]string{}, cfg.Notify.NotifyOn...),
			Feishu: &sentinelv1.FeishuConfig{
				Enabled:    cfg.Notify.Feishu.Enabled,
				WebhookUrl: cfg.Notify.Feishu.WebhookURL,
				Secret:     cfg.Notify.Feishu.Secret,
			},
			Bark: &sentinelv1.BarkConfig{
				Enabled:   cfg.Notify.Bark.Enabled,
				ServerUrl: cfg.Notify.Bark.ServerURL,
				DeviceKey: cfg.Notify.Bark.DeviceKey,
			},
			Smtp: &sentinelv1.SMTPConfig{
				Enabled:  cfg.Notify.SMTP.Enabled,
				Host:     cfg.Notify.SMTP.Host,
				Port:     int32(cfg.Notify.SMTP.Port),
				Username: cfg.Notify.SMTP.Username,
				Password: cfg.Notify.SMTP.Password,
				From:     cfg.Notify.SMTP.From,
				To:       append([]string{}, cfg.Notify.SMTP.To...),
				UseTls:   cfg.Notify.SMTP.UseTLS,
			},
		},
		Daemon: &sentinelv1.DaemonConfig{
			LogLevel:      cfg.Daemon.LogLevel,
			LogDir:        cfg.Daemon.LogDir,
			LogRetainDays: int32(cfg.Daemon.LogRetainDays),
		},
	}
}

func ProtoToConfig(pb *sentinelv1.AppConfig) *config.Config {
	cfg := &config.Config{}
	if pb == nil {
		return cfg
	}
	if pb.Monitor != nil {
		cfg.Monitor = config.MonitorConfig{
			ProcessName:        pb.Monitor.ProcessName,
			PIDFile:            pb.Monitor.PidFile,
			Host:               pb.Monitor.Host,
			Port:               int(pb.Monitor.Port),
			EnableKqueue:       pb.Monitor.EnableKqueue,
			EnableTCPProbe:     pb.Monitor.EnableTcpProbe,
			TCPProbeTimeoutMS:  int(pb.Monitor.TcpProbeTimeoutMs),
			HealthCommand:      pb.Monitor.HealthCommand,
			RestartCooldownSec: int(pb.Monitor.RestartCooldownSec),
			MaxRestartAttempts: int(pb.Monitor.MaxRestartAttempts),
		}
	}
	if pb.Log != nil {
		cfg.Log = config.LogConfig{
			WatchPaths:       append([]string{}, pb.Log.WatchPaths...),
			CrashArchiveDir:  pb.Log.CrashArchiveDir,
			TailLinesOnCrash: int(pb.Log.TailLinesOnCrash),
			MaxArchiveDays:   int(pb.Log.MaxArchiveDays),
		}
	}
	if pb.Agent != nil {
		agents := make([]config.AgentEntry, 0, len(pb.Agent.Agents))
		for _, entry := range pb.Agent.Agents {
			agents = append(agents, config.AgentEntry{
				Name:       entry.Name,
				CLIPath:    entry.CliPath,
				CLIArgs:    append([]string{}, entry.CliArgs...),
				WorkingDir: entry.WorkingDir,
				TimeoutSec: int(entry.TimeoutSec),
				Env:        entry.Env,
			})
		}
		cfg.Agent = config.AgentConfig{
			DefaultAgent: pb.Agent.DefaultAgent,
			Agents:       agents,
		}
	}
	if pb.Repair != nil {
		cfg.Repair = config.RepairConfig{
			AutoRepair:        pb.Repair.AutoRepair,
			AutoRestart:       pb.Repair.AutoRestart,
			RestartCommand:    pb.Repair.RestartCommand,
			RestartArgs:       append([]string{}, pb.Repair.RestartArgs...),
			MaxRepairAttempts: int(pb.Repair.MaxRepairAttempts),
			PromptTemplate:    pb.Repair.PromptTemplate,
		}
	}
	if pb.Notify != nil {
		cfg.Notify = config.NotifyConfig{
			NotifyOn: append([]string{}, pb.Notify.NotifyOn...),
		}
		if pb.Notify.Feishu != nil {
			cfg.Notify.Feishu = config.FeishuConfig{
				Enabled:    pb.Notify.Feishu.Enabled,
				WebhookURL: pb.Notify.Feishu.WebhookUrl,
				Secret:     pb.Notify.Feishu.Secret,
			}
		}
		if pb.Notify.Bark != nil {
			cfg.Notify.Bark = config.BarkConfig{
				Enabled:   pb.Notify.Bark.Enabled,
				ServerURL: pb.Notify.Bark.ServerUrl,
				DeviceKey: pb.Notify.Bark.DeviceKey,
			}
		}
		if pb.Notify.Smtp != nil {
			cfg.Notify.SMTP = config.SMTPConfig{
				Enabled:  pb.Notify.Smtp.Enabled,
				Host:     pb.Notify.Smtp.Host,
				Port:     int(pb.Notify.Smtp.Port),
				Username: pb.Notify.Smtp.Username,
				Password: pb.Notify.Smtp.Password,
				From:     pb.Notify.Smtp.From,
				To:       append([]string{}, pb.Notify.Smtp.To...),
				UseTLS:   pb.Notify.Smtp.UseTls,
			}
		}
	}
	if pb.Daemon != nil {
		cfg.Daemon = config.DaemonConfig{
			LogLevel:      pb.Daemon.LogLevel,
			LogDir:        pb.Daemon.LogDir,
			LogRetainDays: int(pb.Daemon.LogRetainDays),
		}
	}
	return cfg
}

func StatusToProto(status orchestrator.Status) *sentinelv1.SentinelStatus {
	return &sentinelv1.SentinelStatus{
		State:          mapState(status.State),
		ProcessName:    status.ProcessName,
		Pid:            int32(status.PID),
		ExitCode:       int32(status.ExitCode),
		CrashCount:     int32(status.CrashCount),
		RepairAttempts: int32(status.RepairAttempts),
		LastArchive:    status.LastArchive,
		Detail:         status.Detail,
		LastCrashTime:  timestamppb.New(status.LastCrashTime),
		UpdatedAt:      timestamppb.New(status.UpdatedAt),
	}
}

func LogEntryToProto(entry logcollector.Entry) *sentinelv1.LogEntry {
	return &sentinelv1.LogEntry{
		Time:    timestamppb.New(entry.Time),
		Level:   entry.Level,
		Source:  entry.Source,
		Message: entry.Message,
	}
}

func mapState(state orchestrator.State) sentinelv1.State {
	switch state {
	case orchestrator.StateWatching:
		return sentinelv1.State_STATE_WATCHING
	case orchestrator.StateCrashDetected:
		return sentinelv1.State_STATE_CRASH_DETECTED
	case orchestrator.StateCollecting:
		return sentinelv1.State_STATE_COLLECTING
	case orchestrator.StateRepairing:
		return sentinelv1.State_STATE_REPAIRING
	case orchestrator.StateRestarting:
		return sentinelv1.State_STATE_RESTARTING
	case orchestrator.StateExhausted:
		return sentinelv1.State_STATE_EXHAUSTED
	default:
		return sentinelv1.State_STATE_UNSPECIFIED
	}
}

func SafeTimestamp(value time.Time) *timestamppb.Timestamp {
	if value.IsZero() {
		return nil
	}
	return timestamppb.New(value)
}
