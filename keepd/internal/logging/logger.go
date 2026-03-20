package logging

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Logger struct {
	level string
	out   io.Writer
	mu    sync.Mutex
}

func New(logDir string, level string) (*Logger, error) {
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return nil, err
	}
	filePath := filepath.Join(logDir, "keepd.log")
	file, err := os.OpenFile(filePath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	return &Logger{
		level: strings.ToLower(level),
		out:   io.MultiWriter(os.Stdout, file),
	}, nil
}

func (l *Logger) Debug(message string, keyvals ...any) {
	l.log("debug", message, keyvals...)
}

func (l *Logger) Info(message string, keyvals ...any) {
	l.log("info", message, keyvals...)
}

func (l *Logger) Warn(message string, keyvals ...any) {
	l.log("warn", message, keyvals...)
}

func (l *Logger) Error(message string, keyvals ...any) {
	l.log("error", message, keyvals...)
}

func (l *Logger) log(level string, message string, keyvals ...any) {
	if !l.enabled(level) {
		return
	}
	entry := map[string]any{
		"time":    time.Now().Format(time.RFC3339),
		"level":   level,
		"message": message,
	}
	for index := 0; index+1 < len(keyvals); index += 2 {
		key, ok := keyvals[index].(string)
		if !ok {
			continue
		}
		entry[key] = keyvals[index+1]
	}
	payload, _ := json.Marshal(entry)
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.out.Write(append(payload, '\n'))
}

func (l *Logger) enabled(level string) bool {
	rank := map[string]int{
		"debug": 0,
		"info":  1,
		"warn":  2,
		"error": 3,
	}
	current, ok := rank[l.level]
	if !ok {
		current = rank["info"]
	}
	target, ok := rank[level]
	if !ok {
		target = rank["info"]
	}
	return target >= current
}
