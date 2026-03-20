package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Monitor MonitorConfig `toml:"monitor"`
	Log     LogConfig     `toml:"log"`
	Agent   AgentConfig   `toml:"agent"`
	Repair  RepairConfig  `toml:"repair"`
	Notify  NotifyConfig  `toml:"notify"`
	Daemon  DaemonConfig  `toml:"daemon"`
}

type MonitorConfig struct {
	ProcessName        string `toml:"process_name"`
	PIDFile            string `toml:"pid_file"`
	Host               string `toml:"host"`
	Port               int    `toml:"port"`
	EnableKqueue       bool   `toml:"enable_kqueue"`
	EnableTCPProbe     bool   `toml:"enable_tcp_probe"`
	TCPProbeTimeoutMS  int    `toml:"tcp_probe_timeout_ms"`
	HealthCommand      string `toml:"health_command"`
	RestartCooldownSec int    `toml:"restart_cooldown_sec"`
	MaxRestartAttempts int    `toml:"max_restart_attempts"`
}

type LogConfig struct {
	WatchPaths       []string `toml:"watch_paths"`
	CrashArchiveDir  string   `toml:"crash_archive_dir"`
	TailLinesOnCrash int      `toml:"tail_lines_on_crash"`
	MaxArchiveDays   int      `toml:"max_archive_days"`
}

type AgentConfig struct {
	DefaultAgent string        `toml:"default_agent"`
	Agents       []AgentEntry  `toml:"agents"`
}

type AgentEntry struct {
	Name       string            `toml:"name"`
	CLIPath    string            `toml:"cli_path"`
	CLIArgs    []string          `toml:"cli_args"`
	WorkingDir string            `toml:"working_dir"`
	TimeoutSec int               `toml:"timeout_sec"`
	Env        map[string]string `toml:"env"`
}

type RepairConfig struct {
	AutoRepair        bool     `toml:"auto_repair"`
	AutoRestart       bool     `toml:"auto_restart"`
	RestartCommand    string   `toml:"restart_command"`
	RestartArgs       []string `toml:"restart_args"`
	MaxRepairAttempts int      `toml:"max_repair_attempts"`
	PromptTemplate    string   `toml:"prompt_template"`
}

type NotifyConfig struct {
	NotifyOn []string     `toml:"notify_on"`
	Feishu   FeishuConfig `toml:"feishu"`
	Bark     BarkConfig   `toml:"bark"`
	SMTP     SMTPConfig   `toml:"smtp"`
}

type FeishuConfig struct {
	Enabled    bool   `toml:"enabled"`
	WebhookURL string `toml:"webhook_url"`
	Secret     string `toml:"secret"`
}

type BarkConfig struct {
	Enabled   bool   `toml:"enabled"`
	ServerURL string `toml:"server_url"`
	DeviceKey string `toml:"device_key"`
}

type SMTPConfig struct {
	Enabled  bool     `toml:"enabled"`
	Host     string   `toml:"host"`
	Port     int      `toml:"port"`
	Username string   `toml:"username"`
	Password string   `toml:"password"`
	From     string   `toml:"from"`
	To       []string `toml:"to"`
	UseTLS   bool     `toml:"use_tls"`
}

type DaemonConfig struct {
	LogLevel      string `toml:"log_level"`
	LogDir        string `toml:"log_dir"`
	LogRetainDays int    `toml:"log_retain_days"`
}

func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "~/.claw-keep/config.toml"
	}
	return filepath.Join(home, ".claw-keep", "config.toml")
}

func Load(path string) (*Config, error) {
	var cfg Config
	expandedPath, err := ExpandPath(path)
	if err != nil {
		return nil, err
	}
	if _, err := toml.DecodeFile(expandedPath, &cfg); err != nil {
		return nil, err
	}
	if err := cfg.normalize(); err != nil {
		return nil, err
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) normalize() error {
	var err error
	c.Monitor.PIDFile, err = ExpandPath(c.Monitor.PIDFile)
	if err != nil {
		return err
	}
	for index, path := range c.Log.WatchPaths {
		c.Log.WatchPaths[index], err = ExpandPath(path)
		if err != nil {
			return err
		}
	}
	c.Log.CrashArchiveDir, err = ExpandPath(c.Log.CrashArchiveDir)
	if err != nil {
		return err
	}
	c.Daemon.LogDir, err = ExpandPath(c.Daemon.LogDir)
	if err != nil {
		return err
	}
	for index := range c.Agent.Agents {
		c.Agent.Agents[index].CLIPath, err = ExpandPath(c.Agent.Agents[index].CLIPath)
		if err != nil {
			return err
		}
		c.Agent.Agents[index].WorkingDir, err = ExpandPath(c.Agent.Agents[index].WorkingDir)
		if err != nil {
			return err
		}
	}
	c.Repair.RestartCommand, err = ExpandPath(c.Repair.RestartCommand)
	if err != nil {
		return err
	}
	return nil
}

func (c *Config) Validate() error {
	if c.Monitor.ProcessName == "" {
		return errors.New("monitor.process_name is required")
	}
	if c.Monitor.Port <= 0 {
		return errors.New("monitor.port must be greater than 0")
	}
	if c.Log.CrashArchiveDir == "" {
		return errors.New("log.crash_archive_dir is required")
	}
	if c.Agent.DefaultAgent == "" {
		return errors.New("agent.default_agent is required")
	}
	if len(c.Agent.Agents) == 0 {
		return errors.New("agent.agents must contain at least one agent")
	}
	foundDefault := false
	for _, entry := range c.Agent.Agents {
		if entry.Name == "" {
			return errors.New("agent.agents.name is required")
		}
		if entry.CLIPath == "" {
			return fmt.Errorf("agent %q cli_path is required", entry.Name)
		}
		if entry.TimeoutSec <= 0 {
			return fmt.Errorf("agent %q timeout_sec must be greater than 0", entry.Name)
		}
		if entry.Name == c.Agent.DefaultAgent {
			foundDefault = true
		}
	}
	if !foundDefault {
		return fmt.Errorf("agent.default_agent %q is not defined", c.Agent.DefaultAgent)
	}
	if c.Repair.MaxRepairAttempts <= 0 {
		return errors.New("repair.max_repair_attempts must be greater than 0")
	}
	if c.Repair.AutoRestart && c.Repair.RestartCommand == "" {
		return errors.New("repair.restart_command is required when auto_restart=true")
	}
	return nil
}

func ExpandPath(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = filepath.Join(home, path[2:])
	}
	return filepath.Clean(path), nil
}
