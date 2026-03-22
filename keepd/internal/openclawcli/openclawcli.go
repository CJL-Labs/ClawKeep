package openclawcli

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type Runtime struct {
	OpenClawPath string
	NodePath     string
}

const gatewayLaunchdLabel = "ai.openclaw.gateway"

var openClawFallbacks = []string{
	"~/.nvm/versions/node/*/bin/openclaw",
	"~/.local/bin/openclaw",
	"/opt/homebrew/bin/openclaw",
	"/usr/local/bin/openclaw",
}

var nodeFallbacks = []string{
	"~/.nvm/versions/node/*/bin/node",
	"/opt/homebrew/bin/node",
	"/usr/local/bin/node",
}

func Discover() (Runtime, error) {
	if runtime, ok := discoverLaunchdRuntime(); ok {
		return runtime, nil
	}

	openClawPath := resolveCommand("openclaw", openClawFallbacks)
	if openClawPath == "" {
		return Runtime{}, fmt.Errorf("no openclaw command found")
	}

	nodePath := siblingNodePath(openClawPath)
	if nodePath == "" {
		nodePath = resolveCommand("node", nodeFallbacks)
	}
	if nodePath == "" {
		return Runtime{}, fmt.Errorf("no node runtime found for openclaw")
	}

	return Runtime{
		OpenClawPath: openClawPath,
		NodePath:     nodePath,
	}, nil
}

func discoverLaunchdRuntime() (Runtime, bool) {
	output, err := exec.Command(
		"launchctl",
		"print",
		fmt.Sprintf("gui/%d/%s", os.Getuid(), gatewayLaunchdLabel),
	).CombinedOutput()
	if err != nil {
		return Runtime{}, false
	}

	nodePath := parseLaunchctlProgramPath(string(output))
	if !isExecutable(nodePath) {
		return Runtime{}, false
	}

	openClawPath := siblingOpenClawPath(nodePath)
	if openClawPath == "" {
		return Runtime{}, false
	}

	return Runtime{
		OpenClawPath: openClawPath,
		NodePath:     nodePath,
	}, true
}

func RunGatewayRestart(ctx context.Context) error {
	_, err := runGatewayCommand(ctx, "restart")
	return err
}

func RunGatewayHealth(ctx context.Context) (string, error) {
	return runGatewayCommand(ctx, "health --json")
}

func runGatewayCommand(ctx context.Context, action string) (string, error) {
	runtime, err := Discover()
	if err != nil {
		return "", err
	}

	command := exec.CommandContext(ctx, "/bin/zsh", "-lc", shellQuoted(runtime.OpenClawPath)+" gateway "+action)
	command.Env = appendRuntimeEnv(os.Environ(), runtime)
	output, err := command.CombinedOutput()
	if err != nil {
		trimmed := strings.TrimSpace(string(output))
		if trimmed == "" {
			return "", err
		}
		return "", fmt.Errorf("%w: %s", err, trimmed)
	}
	return string(output), nil
}

func appendRuntimeEnv(base []string, runtime Runtime) []string {
	env := append([]string(nil), base...)
	pathValue := ""
	pathIndex := -1
	for index, entry := range env {
		if strings.HasPrefix(entry, "PATH=") {
			pathIndex = index
			pathValue = strings.TrimPrefix(entry, "PATH=")
			break
		}
	}

	parts := []string{filepath.Dir(runtime.NodePath), filepath.Dir(runtime.OpenClawPath)}
	if pathValue != "" {
		parts = append(parts, pathValue)
	}
	joined := dedupePathEntries(parts)
	if pathIndex >= 0 {
		env[pathIndex] = "PATH=" + joined
	} else {
		env = append(env, "PATH="+joined)
	}
	return env
}

func dedupePathEntries(parts []string) string {
	seen := make(map[string]struct{})
	filtered := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if _, ok := seen[part]; ok {
			continue
		}
		seen[part] = struct{}{}
		filtered = append(filtered, part)
	}
	return strings.Join(filtered, ":")
}

func parseLaunchctlProgramPath(output string) string {
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "program = ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "program = "))
		}
	}
	return ""
}

func siblingNodePath(openClawPath string) string {
	candidates := []string{
		filepath.Join(filepath.Dir(openClawPath), "node"),
	}
	if resolved, err := filepath.EvalSymlinks(openClawPath); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(resolved), "node"))
	}
	for _, candidate := range candidates {
		if isExecutable(candidate) {
			return candidate
		}
	}
	return ""
}

func siblingOpenClawPath(nodePath string) string {
	candidates := []string{
		filepath.Join(filepath.Dir(nodePath), "openclaw"),
	}
	if resolved, err := filepath.EvalSymlinks(nodePath); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(resolved), "openclaw"))
	}
	for _, candidate := range candidates {
		if isExecutable(candidate) {
			return candidate
		}
	}
	return ""
}

func resolveCommand(command string, fallbacks []string) string {
	if path, err := exec.LookPath(command); err == nil && path != "" {
		return path
	}
	for _, fallback := range fallbacks {
		expanded, err := expandPath(fallback)
		if err != nil {
			continue
		}
		if strings.ContainsAny(expanded, "*?[") {
			if match := firstExecutableGlob(expanded); match != "" {
				return match
			}
			continue
		}
		if isExecutable(expanded) {
			return expanded
		}
	}
	return ""
}

func firstExecutableGlob(pattern string) string {
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return ""
	}
	sort.Strings(matches)
	for _, match := range matches {
		if isExecutable(match) {
			return match
		}
	}
	return ""
}

func expandPath(path string) (string, error) {
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		path = filepath.Join(home, path[2:])
	}
	return filepath.Clean(path), nil
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func shellQuoted(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}
