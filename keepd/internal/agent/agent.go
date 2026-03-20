package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"text/template"
	"time"

	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/crash"
)

type Result struct {
	AgentName string
	Output    string
	Duration  time.Duration
}

type Runner interface {
	Name() string
	Available() bool
	Repair(ctx context.Context, report crash.Report, prompt string) (*Result, error)
}

type Registry struct {
	agents map[string]Runner
}

type Dispatcher struct {
	mu             sync.RWMutex
	defaultAgent   string
	promptTemplate *template.Template
	registry       *Registry
}

type TimeoutError struct {
	Agent   string
	Timeout time.Duration
}

type cliAgent struct {
	name       string
	path       string
	args       []string
	workingDir string
	timeout    time.Duration
	env        map[string]string
}

func NewRegistry(entries []config.AgentEntry) (*Registry, error) {
	agents := make(map[string]Runner, len(entries))
	for _, entry := range entries {
		agent := &cliAgent{
			name:       entry.Name,
			path:       entry.CLIPath,
			args:       append([]string{}, entry.CLIArgs...),
			workingDir: entry.WorkingDir,
			timeout:    time.Duration(entry.TimeoutSec) * time.Second,
			env:        entry.Env,
		}
		agents[entry.Name] = agent
	}
	return &Registry{agents: agents}, nil
}

func NewDispatcher(defaultAgent string, promptTemplate string, registry *Registry) (*Dispatcher, error) {
	tpl, err := template.New("repair").Parse(promptTemplate)
	if err != nil {
		return nil, err
	}
	return &Dispatcher{
		defaultAgent:   defaultAgent,
		promptTemplate: tpl,
		registry:       registry,
	}, nil
}

func (r *Registry) Get(name string) (Runner, bool) {
	agent, ok := r.agents[name]
	return agent, ok
}

func (d *Dispatcher) ApplyConfig(agentCfg config.AgentConfig, repairCfg config.RepairConfig) error {
	registry, err := NewRegistry(agentCfg.Agents)
	if err != nil {
		return err
	}
	tpl, err := template.New("repair").Parse(repairCfg.PromptTemplate)
	if err != nil {
		return err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.defaultAgent = agentCfg.DefaultAgent
	d.promptTemplate = tpl
	d.registry = registry
	return nil
}

func (d *Dispatcher) Dispatch(ctx context.Context, report crash.Report) (*Result, []string, error) {
	d.mu.RLock()
	defaultAgent := d.defaultAgent
	registry := d.registry
	prompt, err := d.renderPromptLocked(report)
	d.mu.RUnlock()
	if err != nil {
		return nil, nil, err
	}

	order := candidateOrder(registry, defaultAgent)
	if len(order) == 0 {
		return nil, nil, errors.New("no agents configured")
	}

	var failures []string
	var timeoutWarnings []string
	for _, name := range order {
		runner, ok := registry.Get(name)
		if !ok {
			failures = append(failures, fmt.Sprintf("%s: not found", name))
			continue
		}
		if !runner.Available() {
			failures = append(failures, fmt.Sprintf("%s: unavailable", name))
			continue
		}

		result, repairErr := runner.Repair(ctx, report, prompt)
		if repairErr == nil {
			return result, timeoutWarnings, nil
		}

		var timeoutErr *TimeoutError
		if errors.As(repairErr, &timeoutErr) {
			timeoutWarnings = append(timeoutWarnings, timeoutErr.Error())
		}
		failures = append(failures, repairErr.Error())
	}
	return nil, timeoutWarnings, errors.New(strings.Join(failures, "; "))
}

func (d *Dispatcher) renderPromptLocked(report crash.Report) (string, error) {
	var buffer bytes.Buffer
	data := struct {
		ExitCode       int
		CrashTime      string
		TailLogs       string
		StderrSnapshot string
		ErrLogTail     string
	}{
		ExitCode:       report.ExitCode,
		CrashTime:      report.CrashTime.Format(time.RFC3339),
		TailLogs:       joinLines(report.TailLogs),
		StderrSnapshot: report.StderrSnapshot,
		ErrLogTail:     report.ErrLogTail,
	}
	if err := d.promptTemplate.Execute(&buffer, data); err != nil {
		return "", err
	}
	return buffer.String(), nil
}

func (a *cliAgent) Name() string {
	return a.name
}

func (e *TimeoutError) Error() string {
	return fmt.Sprintf("agent %q timed out after %s", e.Agent, e.Timeout)
}

func (a *cliAgent) Available() bool {
	if filepath.IsAbs(a.path) {
		_, err := os.Stat(a.path)
		return err == nil
	}
	_, err := exec.LookPath(a.path)
	return err == nil
}

func (a *cliAgent) Repair(ctx context.Context, _ crash.Report, prompt string) (*Result, error) {
	commandCtx, cancel := context.WithTimeout(ctx, a.timeout)
	defer cancel()

	args := append(append([]string{}, a.args...), prompt)
	command := exec.CommandContext(commandCtx, a.path, args...)
	command.Dir = a.workingDir
	command.Env = os.Environ()
	for key, value := range a.env {
		command.Env = append(command.Env, key+"="+value)
	}

	startedAt := time.Now()
	output, err := command.CombinedOutput()
	duration := time.Since(startedAt)
	if errors.Is(commandCtx.Err(), context.DeadlineExceeded) {
		return nil, &TimeoutError{Agent: a.name, Timeout: a.timeout}
	}
	if err != nil {
		return nil, fmt.Errorf("agent %q failed: %w: %s", a.name, err, string(output))
	}
	return &Result{
		AgentName: a.name,
		Output:    string(output),
		Duration:  duration,
	}, nil
}

func joinLines(lines []string) string {
	var buffer bytes.Buffer
	for index, line := range lines {
		if index > 0 {
			buffer.WriteByte('\n')
		}
		buffer.WriteString(line)
	}
	return buffer.String()
}

func candidateOrder(registry *Registry, defaultAgent string) []string {
	order := make([]string, 0, len(registry.agents))
	seen := make(map[string]struct{}, len(registry.agents))
	if defaultAgent != "" {
		order = append(order, defaultAgent)
		seen[defaultAgent] = struct{}{}
	}
	for name := range registry.agents {
		if _, ok := seen[name]; ok {
			continue
		}
		order = append(order, name)
	}
	return order
}
