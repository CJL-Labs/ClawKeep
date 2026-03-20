package monitor

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/logging"
)

type EventType string

const (
	EventProcessUp   EventType = "process_up"
	EventProcessExit EventType = "process_exit"
	EventPortUp      EventType = "port_up"
	EventPortDown    EventType = "port_down"
)

type Event struct {
	Type     EventType
	PID      int
	ExitCode int
	Time     time.Time
	Detail   string
}

type Monitor struct {
	cfg    config.MonitorConfig
	logger *logging.Logger
	events chan Event

	mu          sync.Mutex
	lastPID     int
	lastPortUp  bool
	lastDownMsg string
}

func New(cfg config.MonitorConfig, logger *logging.Logger) *Monitor {
	return &Monitor{
		cfg:    cfg,
		logger: logger,
		events: make(chan Event, 32),
	}
}

func (m *Monitor) Events() <-chan Event {
	return m.events
}

func (m *Monitor) ApplyConfig(cfg config.MonitorConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cfg = cfg
}

func (m *Monitor) Run(ctx context.Context) {
	go m.processLoop(ctx)
	go m.tcpLoop(ctx)
	<-ctx.Done()
}

func (m *Monitor) processLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		cfg := m.currentConfig()
		pid, err := m.discoverPID(cfg)
		if err != nil {
			if !sleepContext(ctx, 2*time.Second) {
				return
			}
			continue
		}
		if m.swapPID(pid) {
			m.publish(Event{Type: EventProcessUp, PID: pid, Time: time.Now(), Detail: "process discovered"})
		}

		exitCode, err := waitForExit(ctx, pid, cfg.EnableKqueue)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return
			}
			m.logger.Warn("wait for exit failed", "pid", pid, "error", err.Error())
			if !sleepContext(ctx, 2*time.Second) {
				return
			}
			continue
		}

		m.clearPID(pid)
		m.publish(Event{
			Type:     EventProcessExit,
			PID:      pid,
			ExitCode: exitCode,
			Time:     time.Now(),
			Detail:   "kqueue exit event received",
		})
	}
}

func (m *Monitor) tcpLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		cfg := m.currentConfig()
		if !cfg.EnableTCPProbe {
			m.setPortState(false, "tcp probe disabled")
			if !sleepContext(ctx, 2*time.Second) {
				return
			}
			continue
		}

		address := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)
		conn, err := net.DialTimeout("tcp", address, time.Duration(cfg.TCPProbeTimeoutMS)*time.Millisecond)
		if err != nil {
			m.setPortState(false, err.Error())
			if !sleepContext(ctx, 2*time.Second) {
				return
			}
			continue
		}
		if cfg.HealthCommand != "" {
			if err := runHealthCommand(ctx, cfg.HealthCommand); err != nil {
				_ = conn.Close()
				m.setPortState(false, err.Error())
				if !sleepContext(ctx, 2*time.Second) {
					return
				}
				continue
			}
		}

		m.setPortState(true, "tcp connected")
		done := make(chan error, 1)
		go func() {
			defer conn.Close()
			var buffer [1]byte
			_, readErr := conn.Read(buffer[:])
			done <- readErr
		}()

		select {
		case <-ctx.Done():
			_ = conn.Close()
			return
		case readErr := <-done:
			if readErr != nil {
				m.setPortState(false, readErr.Error())
			} else {
				m.setPortState(false, "connection closed")
			}
		}
		if !sleepContext(ctx, 2*time.Second) {
			return
		}
	}
}

func (m *Monitor) discoverPID(cfg config.MonitorConfig) (int, error) {
	if cfg.PIDFile != "" {
		content, err := os.ReadFile(cfg.PIDFile)
		if err == nil {
			pid, convErr := strconv.Atoi(strings.TrimSpace(string(content)))
			if convErr == nil && pid > 0 && processExists(pid) {
				return pid, nil
			}
		}
	}

	output, err := exec.Command("pgrep", "-x", cfg.ProcessName).Output()
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(output))
	if len(fields) == 0 {
		return 0, errors.New("process not found")
	}
	return strconv.Atoi(fields[0])
}

func waitForExit(ctx context.Context, pid int, enableKqueue bool) (int, error) {
	if !enableKqueue {
		for {
			select {
			case <-ctx.Done():
				return 0, context.Canceled
			default:
			}
			if !processExists(pid) {
				return 1, nil
			}
			if !sleepContext(ctx, time.Second) {
				return 0, context.Canceled
			}
		}
	}
	kq, err := unix.Kqueue()
	if err != nil {
		return 0, err
	}
	defer unix.Close(kq)

	changes := []unix.Kevent_t{{
		Ident:  uint64(pid),
		Filter: unix.EVFILT_PROC,
		Flags:  unix.EV_ADD | unix.EV_ENABLE | unix.EV_ONESHOT,
		Fflags: unix.NOTE_EXIT,
	}}
	if _, err := unix.Kevent(kq, changes, nil, nil); err != nil {
		return 0, err
	}

	events := make([]unix.Kevent_t, 1)
	for {
		select {
		case <-ctx.Done():
			return 0, context.Canceled
		default:
		}
		timeout := unix.NsecToTimespec((500 * time.Millisecond).Nanoseconds())
		n, err := unix.Kevent(kq, nil, events, &timeout)
		if err != nil {
			if errors.Is(err, unix.EINTR) {
				continue
			}
			return 0, err
		}
		if n == 0 {
			continue
		}
		return int(events[0].Data), nil
	}
}

func processExists(pid int) bool {
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return process.Signal(syscallSignal0()) == nil
}

func syscallSignal0() os.Signal {
	return unix.Signal(0)
}

func (m *Monitor) publish(event Event) {
	select {
	case m.events <- event:
	default:
	}
}

func (m *Monitor) swapPID(pid int) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lastPID == pid {
		return false
	}
	m.lastPID = pid
	return true
}

func (m *Monitor) clearPID(pid int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lastPID == pid {
		m.lastPID = 0
	}
}

func (m *Monitor) setPortState(up bool, detail string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.lastPortUp == up && m.lastDownMsg == detail {
		return
	}
	m.lastPortUp = up
	m.lastDownMsg = detail
	eventType := EventPortDown
	if up {
		eventType = EventPortUp
	}
	m.publish(Event{Type: eventType, PID: m.lastPID, Time: time.Now(), Detail: detail})
}

func (m *Monitor) currentConfig() config.MonitorConfig {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.cfg
}

func sleepContext(ctx context.Context, wait time.Duration) bool {
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func runHealthCommand(ctx context.Context, command string) error {
	cmd := exec.CommandContext(ctx, "/bin/zsh", "-lc", command)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("health command failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}
