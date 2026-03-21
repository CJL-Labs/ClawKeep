package ipcserver

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"testing"

	"claw-keep/keepd/internal/config"
)

type stubConfigStore struct {
	cfg *config.Config
}

func (s *stubConfigStore) Config() *config.Config {
	return config.Clone(s.cfg)
}

func (s *stubConfigStore) Replace(cfg *config.Config) error {
	s.cfg = config.Clone(cfg)
	return nil
}

type stubApplier struct {
	applied *config.Config
}

func (s *stubApplier) Apply(cfg *config.Config) error {
	s.applied = config.Clone(cfg)
	return nil
}

func TestUpdateConfigAppliesRuntimeBeforeResponding(t *testing.T) {
	t.Parallel()

	initial := validConfig()
	store := &stubConfigStore{cfg: initial}
	applier := &stubApplier{}
	server := New("", store, nil, nil, nil, applier)

	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()

	done := make(chan error, 1)
	go func() {
		done <- server.handleConn(context.Background(), serverConn)
	}()

	updated := validConfig()
	updated.Notify.Feishu.Enabled = true
	updated.Notify.Feishu.WebhookURL = "https://open.feishu.cn/open-apis/bot/v2/hook/demo"

	request := map[string]any{
		"action": "update_config",
		"config": updated,
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	if _, err := clientConn.Write(append(payload, '\n')); err != nil {
		t.Fatalf("write request: %v", err)
	}

	responseLine, err := bufio.NewReader(clientConn).ReadBytes('\n')
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	var response struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal(responseLine, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !response.OK {
		t.Fatalf("unexpected response: %s", string(responseLine))
	}
	if applier.applied == nil {
		t.Fatal("expected config applier to run before response")
	}
	if got := applier.applied.Notify.Feishu.WebhookURL; got != updated.Notify.Feishu.WebhookURL {
		t.Fatalf("unexpected applied webhook: %q", got)
	}
	if err := <-done; err != nil {
		t.Fatalf("handleConn failed: %v", err)
	}
}

func validConfig() *config.Config {
	return &config.Config{
		Monitor: config.MonitorConfig{
			ProcessName: "openclaw-gateway",
			Port:        18789,
		},
		Agent: config.AgentConfig{
			DefaultAgent: "codex",
			Agents: []config.AgentEntry{
				{
					Name:       "codex",
					CLIPath:    "/usr/bin/true",
					WorkingDir: "/tmp",
					TimeoutSec: 300,
				},
			},
		},
		Repair: config.RepairConfig{
			MaxRepairAttempts: 1,
		},
	}
}
