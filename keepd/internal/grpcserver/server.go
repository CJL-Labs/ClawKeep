package grpcserver

import (
	"context"
	"errors"
	"net"
	"os"
	"sync"

	keepv1 "claw-keep/keepd/gen/proto/keep/v1"
	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/logcollector"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/notifier"
	"claw-keep/keepd/internal/orchestrator"
	"claw-keep/keepd/internal/pbconv"

	"google.golang.org/grpc"
)

type ConfigStore interface {
	Config() *config.Config
	Replace(*config.Config) error
}

type Server struct {
	keepv1.UnimplementedKeepServiceServer

	socketPath   string
	configStore  ConfigStore
	logger       *logging.Logger
	orchestrator *orchestrator.Orchestrator
	collector    *logcollector.Collector
	notifier     *notifier.Manager

	server *grpc.Server
	once   sync.Once
}

func New(socketPath string, configStore ConfigStore, logger *logging.Logger, orchestrator *orchestrator.Orchestrator, collector *logcollector.Collector, notifier *notifier.Manager) *Server {
	return &Server{
		socketPath:   socketPath,
		configStore:  configStore,
		logger:       logger,
		orchestrator: orchestrator,
		collector:    collector,
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
		return err
	}

	s.server = grpc.NewServer()
	keepv1.RegisterKeepServiceServer(s.server, s)

	go func() {
		<-ctx.Done()
		s.Stop()
	}()

	return s.server.Serve(listener)
}

func (s *Server) Stop() {
	s.once.Do(func() {
		if s.server != nil {
			s.server.GracefulStop()
		}
		_ = os.Remove(s.socketPath)
	})
}

func (s *Server) GetStatus(context.Context, *keepv1.GetStatusRequest) (*keepv1.GetStatusResponse, error) {
	return &keepv1.GetStatusResponse{
		Status: pbconv.StatusToProto(s.orchestrator.Status()),
	}, nil
}

func (s *Server) SubscribeStatus(_ *keepv1.SubscribeStatusRequest, stream grpc.ServerStreamingServer[keepv1.StatusEvent]) error {
	events, cancel := s.orchestrator.SubscribeStatus()
	defer cancel()

	for {
		select {
		case <-stream.Context().Done():
			return nil
		case event, ok := <-events:
			if !ok {
				return nil
			}
			if err := stream.Send(&keepv1.StatusEvent{
				Status: pbconv.StatusToProto(event.Status),
				Reason: event.Reason,
			}); err != nil {
				return err
			}
		}
	}
}

func (s *Server) SubscribeLogs(request *keepv1.SubscribeLogsRequest, stream grpc.ServerStreamingServer[keepv1.LogEntry]) error {
	entries, cancel := s.collector.Subscribe(int(request.MaxBacklog))
	defer cancel()
	for {
		select {
		case <-stream.Context().Done():
			return nil
		case entry, ok := <-entries:
			if !ok {
				return nil
			}
			if err := stream.Send(pbconv.LogEntryToProto(entry)); err != nil {
				return err
			}
		}
	}
}

func (s *Server) GetConfig(context.Context, *keepv1.GetConfigRequest) (*keepv1.GetConfigResponse, error) {
	return &keepv1.GetConfigResponse{
		Config: pbconv.ConfigToProto(s.configStore.Config()),
	}, nil
}

func (s *Server) UpdateConfig(_ context.Context, request *keepv1.UpdateConfigRequest) (*keepv1.UpdateConfigResponse, error) {
	cfg := pbconv.ProtoToConfig(request.Config)
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if err := s.configStore.Replace(cfg); err != nil {
		return nil, err
	}
	return &keepv1.UpdateConfigResponse{
		Config: pbconv.ConfigToProto(cfg),
	}, nil
}

func (s *Server) TriggerRepair(ctx context.Context, _ *keepv1.TriggerRepairRequest) (*keepv1.TriggerRepairResponse, error) {
	if err := s.orchestrator.TriggerRepair(ctx); err != nil {
		return nil, err
	}
	return &keepv1.TriggerRepairResponse{Accepted: true}, nil
}

func (s *Server) Restart(ctx context.Context, _ *keepv1.RestartRequest) (*keepv1.RestartResponse, error) {
	if err := s.orchestrator.Restart(ctx); err != nil {
		return nil, err
	}
	return &keepv1.RestartResponse{Accepted: true}, nil
}

func (s *Server) ResetMonitoring(context.Context, *keepv1.ResetMonitoringRequest) (*keepv1.ResetMonitoringResponse, error) {
	s.orchestrator.Reset()
	return &keepv1.ResetMonitoringResponse{Accepted: true}, nil
}

func (s *Server) TestNotify(ctx context.Context, request *keepv1.TestNotifyRequest) (*keepv1.TestNotifyResponse, error) {
	channel := request.Channel
	if channel == "" {
		return nil, errors.New("channel is required")
	}
	message := notifier.Message{
		Title: "ClawKeep test notification",
		Body:  "This is a test notification for channel " + channel,
	}
	if err := s.notifier.Notify(ctx, notifier.EventCrash, message); err != nil {
		return nil, err
	}
	return &keepv1.TestNotifyResponse{Accepted: true}, nil
}
