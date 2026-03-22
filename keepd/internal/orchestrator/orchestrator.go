package orchestrator

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"claw-keep/keepd/internal/agent"
	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/crash"
	"claw-keep/keepd/internal/logging"
	"claw-keep/keepd/internal/notifier"
	"claw-keep/keepd/internal/openclawcli"
)

type State string

const (
	StateWatching      State = "watching"
	StateMaintenance   State = "maintenance"
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

type recoveryWindow struct {
	id     uint64
	report crash.Report
}

type Orchestrator struct {
	cfg        *config.Config
	logger     *logging.Logger
	dispatcher *agent.Dispatcher
	notifier   *notifier.Manager

	mu     sync.Mutex
	status Status

	maintenanceUntil time.Time
	maintenanceSeq   uint64
	pendingRecovery  *recoveryWindow
	recoverySeq      uint64
	stabilitySeq     uint64

	subscribers map[int]chan StatusEvent
	nextSubID   int
}

func New(cfg *config.Config, logger *logging.Logger, dispatcher *agent.Dispatcher, notifier *notifier.Manager) *Orchestrator {
	return &Orchestrator{
		cfg:        cfg,
		logger:     logger,
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
	o.mu.Lock()
	o.pendingRecovery = nil
	o.maintenanceUntil = time.Time{}
	o.maintenanceSeq++
	o.stabilitySeq++
	o.mu.Unlock()

	o.transition(StateCrashDetected, fmt.Sprintf("进程退出，退出码 %d。", report.ExitCode))
	o.setCrash(report.CrashTime)
	if freshPID, err := discoverPID(o.cfg.Monitor.ProcessName); err == nil && freshPID > 0 {
		o.setPID(freshPID)
		report.PID = freshPID
	} else {
		o.setPID(report.PID)
	}
	o.setExitCode(report.ExitCode)

	if err := o.notifier.Notify(ctx, notifier.EventCrash, notifier.Message{
		Title: "ClawKeep 检测到 OpenClaw 异常",
		Body:  fmt.Sprintf("%s 已退出，退出码：%d", report.ProcessName, report.ExitCode),
	}); err != nil {
		return err
	}

	if !o.cfg.Repair.AutoRepair {
		o.transition(StateCrashDetected, "已关闭自动修复，等待手动处理。")
		return nil
	}

	for attempt := 1; attempt <= o.cfg.Repair.MaxRepairAttempts; attempt++ {
		if freshPID, err := discoverPID(o.cfg.Monitor.ProcessName); err == nil && freshPID > 0 {
			report.PID = freshPID
			o.setPID(freshPID)
		}
		o.setRepairAttempts(attempt)
		o.transition(StateRepairing, fmt.Sprintf("正在进行第 %d 次修复尝试。", attempt))

		_ = o.notifier.Notify(ctx, notifier.EventRepairStart, notifier.Message{
			Title: "ClawKeep 开始自动修复",
			Body:  fmt.Sprintf("正在第 %d 次尝试修复 %s", attempt, report.ProcessName),
		})

		result, timeoutWarnings, repairErr := o.dispatcher.Dispatch(ctx, report)
		for _, warning := range timeoutWarnings {
			_ = o.notifier.Notify(ctx, notifier.EventAgentTimeout, notifier.Message{
				Title: "ClawKeep 修复超时",
				Body:  warning + "，ClawKeep 将继续尝试其他可用修复工具。",
			})
		}
		if repairErr == nil {
			healthErr := o.verifyRecovery(ctx)
			if healthErr != nil {
				repairErr = healthErr
			}
		}
		if repairErr == nil {
			o.logger.Info("repair succeeded", "agent", result.AgentName, "duration", result.Duration.String())
			_ = o.notifier.Notify(ctx, notifier.EventRepairSuccess, notifier.Message{
				Title: "ClawKeep 修复成功",
				Body:  fmt.Sprintf("%s 已恢复，修复工具：%s，健康检查：通过", report.ProcessName, result.AgentName),
			})
			o.transition(StateWatching, "修复完成，健康检查通过。")
			return nil
		}

		o.logger.Warn("repair failed", "attempt", attempt, "error", repairErr.Error())
		_ = o.notifier.Notify(ctx, notifier.EventRepairFail, notifier.Message{
			Title: "ClawKeep 修复失败",
			Body:  o.repairFailureMessage(attempt),
		})
	}

	o.transition(StateExhausted, "自动修复次数已用尽。")
	_ = o.notifier.Notify(ctx, notifier.EventRepairFail, notifier.Message{
		Title: "ClawKeep 需要人工处理",
		Body:  fmt.Sprintf("%s 多次修复失败，请手动检查。", report.ProcessName),
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
	pid := o.status.PID
	if freshPID, err := discoverPID(o.cfg.Monitor.ProcessName); err == nil && freshPID > 0 {
		pid = freshPID
	}
	report := crash.Report{
		ProcessName: o.cfg.Monitor.ProcessName,
		PID:         pid,
		ExitCode:    o.status.ExitCode,
		CrashTime:   time.Now(),
		WatchPaths:  append([]string(nil), o.cfg.Log.WatchPaths...),
	}
	return o.HandleCrash(ctx, report)
}

func (o *Orchestrator) HandleProcessExit(ctx context.Context, report crash.Report) error {
	state, grace, planned, started, ignored := o.beginRecoveryWindow(report)
	if ignored {
		return nil
	}
	if state == StateRepairing || state == StateCollecting {
		return nil
	}
	if !started || grace <= 0 {
		return o.HandleCrash(ctx, report)
	}

	detail := fmt.Sprintf("检测到 %s 退出，正在等待最多 %s 看它是否自行恢复。", report.ProcessName, formatDuration(grace))
	if planned {
		detail = fmt.Sprintf("维护窗口内检测到 %s 退出，正在等待最多 %s 看它是否恢复。", report.ProcessName, formatDuration(grace))
	}
	o.transition(StateMaintenance, detail)
	return nil
}

func (o *Orchestrator) Reset() {
	o.mu.Lock()
	o.status.RepairAttempts = 0
	o.status.ExitCode = 0
	o.status.Detail = "监控状态已重置。"
	o.pendingRecovery = nil
	o.maintenanceUntil = time.Time{}
	o.maintenanceSeq++
	o.stabilitySeq++
	o.mu.Unlock()
	o.transition(StateWatching, "已手动重置监控状态。")
}

func (o *Orchestrator) UpdatePID(pid int) {
	o.mu.Lock()
	o.status.PID = pid
	o.status.UpdatedAt = time.Now()
	state := o.status.State
	o.mu.Unlock()

	if state == StateRepairing || state == StateCollecting || state == StateMaintenance {
		return
	}
	o.transition(StateWatching, "进程正在运行。")
}

func (o *Orchestrator) ConfirmHealthy(pid int) {
	o.mu.Lock()
	if pid > 0 {
		o.status.PID = pid
	}
	o.status.UpdatedAt = time.Now()
	state := o.status.State
	pending := o.pendingRecovery != nil
	if pending {
		o.stabilitySeq++
		seq := o.stabilitySeq
		o.mu.Unlock()
		o.transition(StateMaintenance, "OpenClaw 已恢复响应，正在确认稳定性。")
		go o.waitForRecoveryStability(seq)
		return
	}
	if state == StateMaintenance {
		o.maintenanceUntil = time.Time{}
		o.maintenanceSeq++
	}
	o.mu.Unlock()

	if state == StateRepairing || state == StateCollecting {
		return
	}
	if pending || state == StateMaintenance {
		o.transition(StateWatching, "服务已在宽限期内恢复。")
		return
	}
	o.transition(StateWatching, "进程正在运行。")
}

func (o *Orchestrator) EnterMaintenance(duration time.Duration, reason string) {
	if duration <= 0 {
		return
	}
	until := time.Now().Add(duration)

	o.mu.Lock()
	o.maintenanceUntil = until
	o.maintenanceSeq++
	o.stabilitySeq++
	seq := o.maintenanceSeq
	state := o.status.State
	o.mu.Unlock()

	if state == StateWatching || state == StateMaintenance {
		o.transition(StateMaintenance, fmt.Sprintf("%s，宽限期 %s。", reason, formatDuration(duration)))
	}

	go o.waitForMaintenanceExpiry(seq, until)
}

func (o *Orchestrator) ExitMaintenance() {
	o.mu.Lock()
	o.maintenanceUntil = time.Time{}
	o.maintenanceSeq++
	o.stabilitySeq++
	o.pendingRecovery = nil
	state := o.status.State
	o.mu.Unlock()

	if state == StateMaintenance {
		o.transition(StateWatching, "维护窗口已结束。")
	}
}

func (o *Orchestrator) PortDown(detail string) {
	o.mu.Lock()
	state := o.status.State
	maintenanceActive := state == StateMaintenance || o.maintenanceUntil.After(time.Now()) || o.pendingRecovery != nil
	o.mu.Unlock()

	if state == StateRepairing || state == StateCollecting {
		return
	}
	if maintenanceActive {
		o.transition(StateMaintenance, "检测到服务暂时不可达，仍在维护/恢复宽限期内。")
		return
	}
	o.transition(StateCrashDetected, detail)
}

func (o *Orchestrator) ShouldIgnoreEvent(at time.Time) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if at.IsZero() || o.status.UpdatedAt.IsZero() {
		return false
	}
	return at.Before(o.status.UpdatedAt)
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

func truncate(value string) string {
	if len(value) <= 160 {
		return value
	}
	return value[:160] + "..."
}

func formatDuration(duration time.Duration) string {
	seconds := int(duration.Round(time.Second) / time.Second)
	if seconds <= 0 {
		seconds = 1
	}
	return fmt.Sprintf("%d 秒", seconds)
}

func (o *Orchestrator) beginRecoveryWindow(report crash.Report) (State, time.Duration, bool, bool, bool) {
	now := time.Now()

	o.mu.Lock()
	defer o.mu.Unlock()

	state := o.status.State
	if state == StateRepairing || state == StateCollecting {
		return state, 0, false, false, true
	}
	if o.pendingRecovery != nil {
		return state, 0, false, false, true
	}

	grace := time.Duration(o.cfg.Monitor.ExitGracePeriodSec) * time.Second
	planned := false
	if o.maintenanceUntil.After(now) {
		planned = true
		if remaining := time.Until(o.maintenanceUntil); remaining > grace {
			grace = remaining
		}
	}
	if grace <= 0 {
		return state, 0, planned, false, false
	}

	o.recoverySeq++
	recoveryID := o.recoverySeq
	o.stabilitySeq++
	o.pendingRecovery = &recoveryWindow{id: recoveryID, report: report}

	go o.waitForRecoveryDeadline(recoveryID, report, grace)
	return state, grace, planned, true, false
}

func (o *Orchestrator) waitForRecoveryDeadline(recoveryID uint64, report crash.Report, grace time.Duration) {
	timer := time.NewTimer(grace)
	defer timer.Stop()
	<-timer.C

	if pid, ok := o.checkRecoveryHealth(); ok {
		o.ConfirmHealthy(pid)
		return
	}

	o.mu.Lock()
	if o.pendingRecovery == nil || o.pendingRecovery.id != recoveryID {
		o.mu.Unlock()
		return
	}
	o.pendingRecovery = nil
	if !o.maintenanceUntil.After(time.Now()) {
		o.maintenanceUntil = time.Time{}
	}
	o.mu.Unlock()

	_ = o.HandleCrash(context.Background(), report)
}

func (o *Orchestrator) waitForRecoveryStability(seq uint64) {
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	<-timer.C

	pid, ok := o.checkRecoveryHealth()
	if !ok {
		return
	}

	o.mu.Lock()
	if o.stabilitySeq != seq || o.pendingRecovery == nil {
		o.mu.Unlock()
		return
	}
	o.pendingRecovery = nil
	o.maintenanceUntil = time.Time{}
	o.maintenanceSeq++
	o.stabilitySeq++
	o.mu.Unlock()

	o.ConfirmHealthy(pid)
}

func (o *Orchestrator) waitForMaintenanceExpiry(seq uint64, until time.Time) {
	timer := time.NewTimer(time.Until(until))
	defer timer.Stop()
	<-timer.C

	o.mu.Lock()
	if o.maintenanceSeq != seq || o.maintenanceUntil.After(time.Now()) {
		o.mu.Unlock()
		return
	}
	o.maintenanceUntil = time.Time{}
	pending := o.pendingRecovery != nil
	state := o.status.State
	o.mu.Unlock()

	if !pending && state == StateMaintenance {
		o.transition(StateWatching, "维护窗口已结束。")
	}
}

func (o *Orchestrator) repairFailureMessage(attempt int) string {
	if attempt < o.cfg.Repair.MaxRepairAttempts {
		return fmt.Sprintf("第 %d 次修复未通过健康检查或执行失败，ClawKeep 将继续重试。", attempt)
	}
	return fmt.Sprintf("第 %d 次修复仍未成功，ClawKeep 即将停止自动修复并等待人工处理。", attempt)
}

func (o *Orchestrator) healthCommand() string {
	if strings.TrimSpace(o.cfg.Monitor.HealthCommand) != "" {
		return o.cfg.Monitor.HealthCommand
	}
	return ""
}

func (o *Orchestrator) verifyRecovery(ctx context.Context) error {
	healthCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	pid, err := o.runHealthCheck(healthCtx)
	if err != nil {
		return err
	}
	if pid > 0 {
		o.setPID(pid)
	}
	return nil
}

func (o *Orchestrator) checkRecoveryHealth() (int, bool) {
	healthCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pid, err := o.runHealthCheck(healthCtx)
	if err != nil {
		return 0, false
	}
	return pid, true
}

func (o *Orchestrator) runHealthCheck(ctx context.Context) (int, error) {
	var (
		output []byte
		err    error
	)
	if commandText := o.healthCommand(); commandText != "" {
		command := exec.CommandContext(ctx, "/bin/zsh", "-lc", commandText)
		output, err = command.CombinedOutput()
	} else {
		var rendered string
		rendered, err = openclawcli.RunGatewayHealth(ctx)
		output = []byte(rendered)
	}
	if err != nil {
		return 0, fmt.Errorf("post-repair health check failed: %w", err)
	}
	if strings.TrimSpace(o.cfg.Monitor.HealthCommand) == "" {
		if err := verifyDefaultHealthOutput(string(output)); err != nil {
			return 0, err
		}
	}
	pid, err := discoverPID(o.cfg.Monitor.ProcessName)
	if err != nil {
		return 0, nil
	}
	return pid, nil
}

func verifyDefaultHealthOutput(output string) error {
	trimmed := strings.TrimSpace(output)
	if strings.Contains(trimmed, "Config invalid") {
		return fmt.Errorf("post-repair health check reported invalid config")
	}
	jsonPayload := extractJSONPayload(trimmed)
	if jsonPayload == "" {
		return fmt.Errorf("post-repair health check did not return JSON output")
	}
	var result struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal([]byte(jsonPayload), &result); err != nil {
		return fmt.Errorf("post-repair health check returned invalid JSON: %w", err)
	}
	if !result.OK {
		return fmt.Errorf("post-repair health check reported ok=false")
	}
	return nil
}

func extractJSONPayload(output string) string {
	lines := strings.Split(output, "\n")
	for index, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "{") {
			return strings.Join(lines[index:], "\n")
		}
	}
	return ""
}

func discoverPID(processName string) (int, error) {
	output, err := exec.Command("pgrep", "-x", processName).Output()
	if err != nil {
		return 0, err
	}
	fields := strings.Fields(string(output))
	if len(fields) == 0 {
		return 0, fmt.Errorf("process %s not found", processName)
	}
	return strconv.Atoi(fields[0])
}
