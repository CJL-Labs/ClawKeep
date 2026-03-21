package config

import (
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Monitor MonitorConfig `toml:"monitor" json:"monitor"`
	Log     LogConfig     `toml:"log" json:"log"`
	Agent   AgentConfig   `toml:"agent" json:"agent"`
	Repair  RepairConfig  `toml:"repair" json:"repair"`
	Notify  NotifyConfig  `toml:"notify" json:"notify"`
	Daemon  DaemonConfig  `toml:"daemon" json:"daemon"`
}

type MonitorConfig struct {
	ProcessName        string `toml:"process_name" json:"process_name"`
	PIDFile            string `toml:"pid_file" json:"pid_file"`
	Host               string `toml:"host" json:"host"`
	Port               int    `toml:"port" json:"port"`
	EnableKqueue       bool   `toml:"enable_kqueue" json:"enable_kqueue"`
	EnableTCPProbe     bool   `toml:"enable_tcp_probe" json:"enable_tcp_probe"`
	TCPProbeTimeoutMS  int    `toml:"tcp_probe_timeout_ms" json:"tcp_probe_timeout_ms"`
	HealthCommand      string `toml:"health_command" json:"health_command"`
	ExitGracePeriodSec int    `toml:"exit_grace_period_sec" json:"exit_grace_period_sec"`
	RestartCooldownSec int    `toml:"restart_cooldown_sec" json:"restart_cooldown_sec"`
	MaxRestartAttempts int    `toml:"max_restart_attempts" json:"max_restart_attempts"`
}

type LogConfig struct {
	WatchPaths []string `toml:"watch_paths" json:"watch_paths"`
}

type AgentConfig struct {
	DefaultAgent string       `toml:"default_agent" json:"default_agent"`
	Agents       []AgentEntry `toml:"agents" json:"agents"`
}

type AgentEntry struct {
	Name       string            `toml:"name" json:"name"`
	CLIPath    string            `toml:"cli_path" json:"cli_path"`
	CLIArgs    []string          `toml:"cli_args" json:"cli_args"`
	WorkingDir string            `toml:"working_dir" json:"working_dir"`
	TimeoutSec int               `toml:"timeout_sec" json:"timeout_sec"`
	Env        map[string]string `toml:"env" json:"env"`
}

type RepairConfig struct {
	AutoRepair        bool   `toml:"auto_repair" json:"auto_repair"`
	MaxRepairAttempts int    `toml:"max_repair_attempts" json:"max_repair_attempts"`
	PromptTemplate    string `toml:"prompt_template" json:"prompt_template"`
}

type NotifyConfig struct {
	NotifyOn []string     `toml:"notify_on" json:"notify_on"`
	Feishu   FeishuConfig `toml:"feishu" json:"feishu"`
	Bark     BarkConfig   `toml:"bark" json:"bark"`
	SMTP     SMTPConfig   `toml:"smtp" json:"smtp"`
}

type FeishuConfig struct {
	Enabled    bool   `toml:"enabled" json:"enabled"`
	WebhookURL string `toml:"webhook_url" json:"webhook_url"`
	Secret     string `toml:"secret" json:"secret"`
}

type BarkConfig struct {
	Enabled bool   `toml:"enabled" json:"enabled"`
	PushURL string `toml:"push_url" json:"push_url"`
}

type SMTPConfig struct {
	Enabled  bool     `toml:"enabled" json:"enabled"`
	Host     string   `toml:"host" json:"host"`
	Port     int      `toml:"port" json:"port"`
	Username string   `toml:"username" json:"username"`
	Password string   `toml:"password" json:"password"`
	From     string   `toml:"from" json:"from"`
	To       []string `toml:"to" json:"to"`
	UseTLS   bool     `toml:"use_tls" json:"use_tls"`
}

type DaemonConfig struct {
	LogLevel      string `toml:"log_level" json:"log_level"`
	LogDir        string `toml:"log_dir" json:"log_dir"`
	LogRetainDays int    `toml:"log_retain_days" json:"log_retain_days"`
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
	if c.Monitor.ExitGracePeriodSec <= 0 {
		c.Monitor.ExitGracePeriodSec = 20
	}
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
	return nil
}

func (c *Config) Validate() error {
	if c.Monitor.ProcessName == "" {
		return errors.New("monitor.process_name is required")
	}
	if c.Monitor.Port <= 0 {
		return errors.New("monitor.port must be greater than 0")
	}
	if c.Monitor.ExitGracePeriodSec <= 0 {
		return errors.New("monitor.exit_grace_period_sec must be greater than 0")
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

func (b *BarkConfig) UnmarshalTOML(value any) error {
	values, ok := value.(map[string]any)
	if !ok {
		return fmt.Errorf("invalid bark config")
	}

	if enabled, ok := values["enabled"].(bool); ok {
		b.Enabled = enabled
	}
	if pushURL, ok := values["push_url"].(string); ok {
		b.PushURL = pushURL
	}
	if b.PushURL != "" {
		return nil
	}

	serverURL, _ := values["server_url"].(string)
	deviceKey, _ := values["device_key"].(string)
	serverURL = strings.TrimRight(serverURL, "/")
	deviceKey = strings.Trim(deviceKey, "/")
	if serverURL != "" && deviceKey != "" {
		b.PushURL = serverURL + "/" + deviceKey
	}
	return nil
}

func Clone(src *Config) *Config {
	if src == nil {
		return &Config{}
	}

	dst := *src
	dst.Log.WatchPaths = slices.Clone(src.Log.WatchPaths)
	dst.Notify.NotifyOn = slices.Clone(src.Notify.NotifyOn)
	dst.Notify.SMTP.To = slices.Clone(src.Notify.SMTP.To)
	dst.Agent.Agents = make([]AgentEntry, len(src.Agent.Agents))
	for index, agent := range src.Agent.Agents {
		dst.Agent.Agents[index] = agent
		dst.Agent.Agents[index].CLIArgs = slices.Clone(agent.CLIArgs)
		dst.Agent.Agents[index].Env = maps.Clone(agent.Env)
	}
	return &dst
}
