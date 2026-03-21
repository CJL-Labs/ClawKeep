package config

import (
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

func TestBarkConfigLoadsLegacyServerAndDeviceKey(t *testing.T) {
	t.Parallel()

	var cfg struct {
		Notify NotifyConfig `toml:"notify"`
	}
	input := `
[notify.bark]
enabled = true
server_url = "https://api.day.app/"
device_key = "demo-key"
`
	if _, err := toml.Decode(input, &cfg); err != nil {
		t.Fatalf("decode config: %v", err)
	}

	if !cfg.Notify.Bark.Enabled {
		t.Fatal("expected bark to be enabled")
	}
	if got, want := cfg.Notify.Bark.PushURL, "https://api.day.app/demo-key"; got != want {
		t.Fatalf("unexpected push url: got %q want %q", got, want)
	}
}

func TestBarkConfigPrefersPushURLWhenProvided(t *testing.T) {
	t.Parallel()

	var bark BarkConfig
	input := `
enabled = true
push_url = "https://api.day.app/direct-key"
server_url = "https://api.day.app"
device_key = "legacy-key"
`
	if _, err := toml.Decode(input, &bark); err != nil {
		t.Fatalf("decode bark config: %v", err)
	}

	if got, want := bark.PushURL, "https://api.day.app/direct-key"; got != want {
		t.Fatalf("unexpected push url: got %q want %q", got, want)
	}
	if strings.Contains(bark.PushURL, "legacy-key") {
		t.Fatalf("push_url should override legacy fields: %q", bark.PushURL)
	}
}

func TestValidateDoesNotRequireRestartCommand(t *testing.T) {
	t.Parallel()

	cfg := &Config{
		Monitor: MonitorConfig{
			ProcessName:        "openclaw-gateway",
			Port:               18789,
			ExitGracePeriodSec: 20,
		},
		Agent: AgentConfig{
			DefaultAgent: "codex",
			Agents: []AgentEntry{
				{
					Name:       "codex",
					CLIPath:    "/usr/bin/true",
					WorkingDir: "/tmp",
					TimeoutSec: 300,
				},
			},
		},
		Repair: RepairConfig{
			AutoRepair:        true,
			MaxRepairAttempts: 1,
			PromptTemplate:    "repair",
		},
	}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("validate config: %v", err)
	}
}

func TestNormalizeSetsDefaultExitGracePeriod(t *testing.T) {
	t.Parallel()

	cfg := &Config{
		Monitor: MonitorConfig{
			ProcessName: "openclaw-gateway",
			Port:        18789,
		},
	}

	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize config: %v", err)
	}
	if got, want := cfg.Monitor.ExitGracePeriodSec, 20; got != want {
		t.Fatalf("unexpected default exit grace period: got %d want %d", got, want)
	}
}
