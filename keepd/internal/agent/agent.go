package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
	defaultAgent   string
	promptTemplate *template.Template
	registry       *Registry
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

func (d *Dispatcher) Dispatch(ctx context.Context, report crash.Report) (*Result, error) {
	runner, ok := d.registry.Get(d.defaultAgent)
	if !ok {
		return nil, fmt.Errorf("agent %q not found", d.defaultAgent)
	}
	if !runner.Available() {
		return nil, fmt.Errorf("agent %q is not available", d.defaultAgent)
	}
	prompt, err := d.renderPrompt(report)
	if err != nil {
		return nil, err
	}
	return runner.Repair(ctx, report, prompt)
}

func (d *Dispatcher) renderPrompt(report crash.Report) (string, error) {
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
		return nil, fmt.Errorf("agent %q timed out after %s", a.name, a.timeout)
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
