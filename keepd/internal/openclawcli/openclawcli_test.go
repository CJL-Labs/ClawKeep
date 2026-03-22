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
