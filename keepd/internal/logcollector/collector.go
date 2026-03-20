package logcollector

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"claw-keep/keepd/internal/config"
	"claw-keep/keepd/internal/logging"
)

type Entry struct {
	Time    time.Time
	Level   string
	Source  string
	Message string
	RawLine string
}

type Collector struct {
	cfg      config.LogConfig
	logger   *logging.Logger
	watcher  *fsnotify.Watcher
	offsets  map[string]int64
	ring     []Entry
	ringSize int

	mu          sync.Mutex
	subscribers map[int]chan Entry
	nextID      int
}

func New(cfg config.LogConfig, logger *logging.Logger) (*Collector, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	size := cfg.TailLinesOnCrash
	if size <= 0 {
		size = 200
	}
	return &Collector{
		cfg:         cfg,
		logger:      logger,
		watcher:     watcher,
		offsets:     make(map[string]int64),
		ringSize:    size,
		subscribers: make(map[int]chan Entry),
	}, nil
}

func (c *Collector) Run(ctx context.Context) error {
	for _, path := range c.cfg.WatchPaths {
		if err := c.watchPath(path); err != nil {
			c.logger.Warn("watch path failed", "path", path, "error", err.Error())
		}
	}

	for {
		select {
		case <-ctx.Done():
			_ = c.watcher.Close()
			return nil
		case event, ok := <-c.watcher.Events:
			if !ok {
				return nil
			}
			if event.Op&(fsnotify.Create|fsnotify.Write) == 0 {
				continue
			}
			if info, err := os.Stat(event.Name); err == nil && info.IsDir() && event.Op&fsnotify.Create != 0 {
				_ = c.watcher.Add(event.Name)
				continue
			}
			c.readAppended(event.Name)
		case err, ok := <-c.watcher.Errors:
			if !ok {
				return nil
			}
			c.logger.Warn("log watcher error", "error", err.Error())
		}
	}
}

func (c *Collector) Subscribe(maxBacklog int) (<-chan Entry, func()) {
	c.mu.Lock()
	defer c.mu.Unlock()

	channel := make(chan Entry, max(maxBacklog, 64))
	id := c.nextID
	c.nextID++
	c.subscribers[id] = channel

	backlog := c.snapshotLocked(maxBacklog)
	for _, entry := range backlog {
		channel <- entry
	}

	cancel := func() {
		c.mu.Lock()
		defer c.mu.Unlock()
		if subscriber, ok := c.subscribers[id]; ok {
			delete(c.subscribers, id)
			close(subscriber)
		}
	}
	return channel, cancel
}

func (c *Collector) SnapshotLines(lines int) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	entries := c.snapshotLocked(lines)
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry.RawLine)
	}
	return result
}

func (c *Collector) TailBySuffix(suffix string, lines int) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	entries := c.snapshotLocked(c.ringSize)
	matched := make([]string, 0, lines)
	for index := len(entries) - 1; index >= 0; index-- {
		if strings.HasSuffix(entries[index].Source, suffix) {
			matched = append(matched, entries[index].RawLine)
			if len(matched) == lines {
				break
			}
		}
	}
	for left, right := 0, len(matched)-1; left < right; left, right = left+1, right-1 {
		matched[left], matched[right] = matched[right], matched[left]
	}
	return strings.Join(matched, "\n")
}

func (c *Collector) watchPath(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.IsDir() {
		if err := c.watcher.Add(path); err != nil {
			return err
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			c.readAppended(filepath.Join(path, entry.Name()))
		}
		return nil
	}
	if err := c.watcher.Add(filepath.Dir(path)); err != nil {
		return err
	}
	c.readAppended(path)
	return nil
}

func (c *Collector) readAppended(path string) {
	file, err := os.Open(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			c.logger.Warn("open log failed", "path", path, "error", err.Error())
		}
		return
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return
	}

	c.mu.Lock()
	offset := c.offsets[path]
	if info.Size() < offset {
		offset = 0
	}
	c.mu.Unlock()

	if _, err := file.Seek(offset, 0); err != nil {
		return
	}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		entry := parseLine(path, line)
		c.append(entry)
	}

	position, err := file.Seek(0, 1)
	if err == nil {
		c.mu.Lock()
		c.offsets[path] = position
		c.mu.Unlock()
	}
}

func (c *Collector) append(entry Entry) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.ring = append(c.ring, entry)
	if len(c.ring) > c.ringSize {
		c.ring = c.ring[len(c.ring)-c.ringSize:]
	}
	for _, subscriber := range c.subscribers {
		select {
		case subscriber <- entry:
		default:
		}
	}
}

func (c *Collector) snapshotLocked(lines int) []Entry {
	if lines <= 0 || lines > len(c.ring) {
		lines = len(c.ring)
	}
	start := len(c.ring) - lines
	snapshot := make([]Entry, lines)
	copy(snapshot, c.ring[start:])
	return snapshot
}

func parseLine(path string, line string) Entry {
	entry := Entry{
		Time:    time.Now(),
		Level:   "info",
		Source:  path,
		Message: line,
		RawLine: line,
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(line), &decoded); err == nil {
		if value, ok := decoded["level"].(string); ok && value != "" {
			entry.Level = value
		}
		if value, ok := decoded["msg"].(string); ok && value != "" {
			entry.Message = value
		} else if value, ok := decoded["message"].(string); ok && value != "" {
			entry.Message = value
		}
	}
	return entry
}

func max(left int, right int) int {
	if left > right {
		return left
	}
	return right
}
