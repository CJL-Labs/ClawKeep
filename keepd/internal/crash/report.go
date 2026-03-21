package crash

import "time"

type Report struct {
	ProcessName    string    `json:"process_name"`
	PID            int       `json:"pid"`
	ExitCode       int       `json:"exit_code"`
	CrashTime      time.Time `json:"crash_time"`
	WatchPaths     []string  `json:"watch_paths,omitempty"`
}
