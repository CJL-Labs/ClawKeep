package openclawcli

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestAppendRuntimeEnvPrependsNodeAndOpenClawDirs(t *testing.T) {
	t.Parallel()

	runtime := Runtime{
		OpenClawPath: "/tmp/openclaw/bin/openclaw",
		NodePath:     "/tmp/openclaw/bin/node",
	}

	env := appendRuntimeEnv([]string{"FOO=bar", "PATH=/usr/bin:/bin"}, runtime)
	var pathValue string
	for _, entry := range env {
		if strings.HasPrefix(entry, "PATH=") {
			pathValue = strings.TrimPrefix(entry, "PATH=")
			break
		}
	}

	expectedPrefix := filepath.Dir(runtime.NodePath)
	if !strings.HasPrefix(pathValue, expectedPrefix) {
		t.Fatalf("expected PATH to start with %q, got %q", expectedPrefix, pathValue)
	}
	if !strings.Contains(pathValue, "/usr/bin:/bin") {
		t.Fatalf("expected original PATH entries to be preserved, got %q", pathValue)
	}
}

func TestParseLaunchctlProgramPath(t *testing.T) {
	t.Parallel()

	output := `
gui/501/ai.openclaw.gateway = {
	program = /Users/test/.nvm/versions/node/v25.8.1/bin/node
	arguments = {
		/Users/test/.nvm/versions/node/v25.8.1/bin/node
		/Users/test/.nvm/versions/node/v25.8.1/lib/node_modules/openclaw/dist/index.js
		gateway
	}
}`

	got := parseLaunchctlProgramPath(output)
	want := "/Users/test/.nvm/versions/node/v25.8.1/bin/node"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}
