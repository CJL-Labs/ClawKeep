package crash

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Report struct {
	ProcessName    string    `json:"process_name"`
	PID            int       `json:"pid"`
	ExitCode       int       `json:"exit_code"`
	CrashTime      time.Time `json:"crash_time"`
	TailLogs       []string  `json:"tail_logs"`
	ErrLogTail     string    `json:"err_log_tail"`
	StderrSnapshot string    `json:"stderr_snapshot"`
}

type Store struct {
	directory     string
	maxArchiveDay int
}

func NewStore(directory string, maxArchiveDay int) *Store {
	return &Store{directory: directory, maxArchiveDay: maxArchiveDay}
}

func (s *Store) Save(report Report) (string, error) {
	if err := os.MkdirAll(s.directory, 0o755); err != nil {
		return "", err
	}
	fileName := fmt.Sprintf("crash-%s.json", report.CrashTime.Format("20060102-150405"))
	filePath := filepath.Join(s.directory, fileName)
	content, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filePath, append(content, '\n'), 0o644); err != nil {
		return "", err
	}
	return filePath, s.Prune(time.Now())
}

func (s *Store) Prune(now time.Time) error {
	if s.maxArchiveDay <= 0 {
		return nil
	}
	entries, err := os.ReadDir(s.directory)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	cutoff := now.AddDate(0, 0, -s.maxArchiveDay)
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.ModTime().Before(cutoff) {
			if err := os.Remove(filepath.Join(s.directory, entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}
