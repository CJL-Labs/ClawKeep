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
	level      string
	logDir     string
	retainDays int
	file       *os.File
	fileDate   string
	mu         sync.Mutex
}

func New(logDir string, level string) (*Logger, error) {
	return NewWithRetention(logDir, level, 7)
}

func NewWithRetention(logDir string, level string, retainDays int) (*Logger, error) {
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return nil, err
	}
	logger := &Logger{
		level:      strings.ToLower(level),
		logDir:     logDir,
		retainDays: retainDays,
	}
	if err := logger.rotateIfNeededLocked(time.Now()); err != nil {
		return nil, err
	}
	return logger, nil
}

func (l *Logger) ApplyConfig(logDir string, level string, retainDays int) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	l.level = strings.ToLower(level)
	l.logDir = logDir
	l.retainDays = retainDays
	return l.rotateIfNeededLocked(time.Now())
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
	if err := l.rotateIfNeededLocked(time.Now()); err != nil {
		return
	}
	writer := io.MultiWriter(os.Stdout, l.file)
	_, _ = writer.Write(append(payload, '\n'))
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

func (l *Logger) rotateIfNeededLocked(now time.Time) error {
	if err := os.MkdirAll(l.logDir, 0o755); err != nil {
		return err
	}
	date := now.Format("2006-01-02")
	if l.file != nil && l.fileDate == date {
		return l.pruneLocked(now)
	}
	if l.file != nil {
		_ = l.file.Close()
		l.file = nil
	}
	filePath := filepath.Join(l.logDir, "keepd-"+date+".log")
	file, err := os.OpenFile(filePath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	l.file = file
	l.fileDate = date
	return l.pruneLocked(now)
}

func (l *Logger) pruneLocked(now time.Time) error {
	if l.retainDays <= 0 {
		return nil
	}
	entries, err := os.ReadDir(l.logDir)
	if err != nil {
		return err
	}
	cutoff := now.AddDate(0, 0, -l.retainDays)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "keepd-") || !strings.HasSuffix(entry.Name(), ".log") {
			continue
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			return infoErr
		}
		if info.ModTime().Before(cutoff) {
			if err := os.Remove(filepath.Join(l.logDir, entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}
