package ipcserver

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"sync"

	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/notifier"
	"claw-keep/keepd/internal/orchestrator"
)

type ConfigStore interface {
	Config() *config.Config
	Replace(*config.Config) error
}

type request struct {
	Action     string         `json:"action"`
	Channel    string         `json:"channel,omitempty"`
	MaxBacklog int            `json:"max_backlog,omitempty"`
	Config     *config.Config `json:"config,omitempty"`
}

type response struct {
	OK     bool   `json:"ok"`
	Error  string `json:"error,omitempty"`
	Result any    `json:"result,omitempty"`
}

type Server struct {
	socketPath   string
	configStore  ConfigStore
	logger       *logging.Logger
	orchestrator *orchestrator.Orchestrator
	notifier     *notifier.Manager

	listener net.Listener
	once     sync.Once
}

func New(socketPath string, configStore ConfigStore, logger *logging.Logger, orchestrator *orchestrator.Orchestrator, notifier *notifier.Manager) *Server {
	return &Server{
		socketPath:   socketPath,
		configStore:  configStore,
		logger:       logger,
		orchestrator: orchestrator,
		notifier:     notifier,
	}
}

func (s *Server) Run(ctx context.Context) error {
	_ = os.Remove(s.socketPath)
	listener, err := net.Listen("unix", s.socketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(s.socketPath, 0o600); err != nil {
		_ = listener.Close()
		return err
	}

	s.listener = listener

	go func() {
		<-ctx.Done()
		s.Stop()
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}

		go func() {
			defer conn.Close()
			if err := s.handleConn(ctx, conn); err != nil && !errors.Is(err, context.Canceled) {
				s.logger.Warn("ipc connection failed", "error", err.Error())
			}
		}()
	}
}

func (s *Server) Stop() {
	s.once.Do(func() {
		if s.listener != nil {
			_ = s.listener.Close()
		}
		_ = os.Remove(s.socketPath)
	})
}

func (s *Server) handleConn(ctx context.Context, conn net.Conn) error {
	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return err
	}

	var req request
	if err := json.Unmarshal(line, &req); err != nil {
		return s.writeResponse(conn, response{OK: false, Error: "invalid request"})
	}

	switch req.Action {
	case "get_status":
		return s.writeResponse(conn, response{OK: true, Result: s.orchestrator.Status()})
	case "get_config":
		return s.writeResponse(conn, response{OK: true, Result: s.configStore.Config()})
	case "update_config":
		if req.Config == nil {
			return s.writeResponse(conn, response{OK: false, Error: "config is required"})
		}
		cfg := config.Clone(req.Config)
		if err := s.configStore.Replace(cfg); err != nil {
			return s.writeResponse(conn, response{OK: false, Error: err.Error()})
		}
		return s.writeResponse(conn, response{OK: true, Result: s.configStore.Config()})
	case "trigger_repair":
		if err := s.orchestrator.TriggerRepair(ctx); err != nil {
			return s.writeResponse(conn, response{OK: false, Error: err.Error()})
		}
		return s.writeResponse(conn, response{OK: true, Result: true})
	case "restart":
		if err := s.orchestrator.Restart(ctx); err != nil {
			return s.writeResponse(conn, response{OK: false, Error: err.Error()})
		}
		return s.writeResponse(conn, response{OK: true, Result: true})
	case "reset_monitoring":
		s.orchestrator.Reset()
		return s.writeResponse(conn, response{OK: true, Result: true})
	case "test_notify":
		if req.Channel == "" {
			return s.writeResponse(conn, response{OK: false, Error: "channel is required"})
		}
		message := notifier.Message{
			Title: "ClawKeep test notification",
			Body:  "This is a test notification for channel " + req.Channel,
		}
		if err := s.notifier.TestChannel(ctx, req.Channel, message); err != nil {
			return s.writeResponse(conn, response{OK: false, Error: err.Error()})
		}
		return s.writeResponse(conn, response{OK: true, Result: true})
	case "subscribe_status":
		return s.streamStatus(ctx, conn)
	default:
		return s.writeResponse(conn, response{OK: false, Error: "unknown action"})
	}
}

func (s *Server) streamStatus(ctx context.Context, conn net.Conn) error {
	events, cancel := s.orchestrator.SubscribeStatus()
	defer cancel()

	encoder := json.NewEncoder(conn)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event, ok := <-events:
			if !ok {
				return nil
			}
			if err := encoder.Encode(event.Status); err != nil {
				return err
			}
		}
	}
}

func (s *Server) writeResponse(conn net.Conn, resp response) error {
	return json.NewEncoder(conn).Encode(resp)
}
